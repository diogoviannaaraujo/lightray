#![allow(clippy::collapsible_if)]
//! Encrypted, replay-protected connection and reliable control transport, without I/O.
use crate::crypto::{
    ProtectedHeader, ReplayWindow, TrafficKey, open_packet, reconstruct_packet_number, seal_packet,
    wrapping_difference,
};
use crate::handshake::{Direction, StreamClass, StreamEntry, StreamTable};
use crate::memory::MemoryBudget;
use crate::reliable::{ReliableOutcome, ReliableReceiver, ReliableSender};
use crate::wire::{Chunk, CloseCode, Feedback, MediaFragment, Nack, RefreshRequest, ReliableAck};
use std::collections::{BTreeMap, VecDeque};
use std::net::SocketAddr;

const PACKET_OVERHEAD: usize = 32;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Host,
    Client,
}
#[derive(Clone, Debug)]
pub struct RttEstimator {
    pub smoothed: u64,
    pub variation: u64,
    pub latest: u64,
    pub minimum: u64,
    pub has_sample: bool,
}
impl Default for RttEstimator {
    fn default() -> Self {
        Self {
            smoothed: 30_000,
            variation: 15_000,
            latest: 0,
            minimum: u64::MAX,
            has_sample: false,
        }
    }
}
impl RttEstimator {
    pub fn add(&mut self, sample: u64) {
        self.latest = sample;
        self.minimum = self.minimum.min(sample);
        if !self.has_sample {
            self.smoothed = sample;
            self.variation = sample / 2;
            self.has_sample = true;
        } else {
            self.variation = (3 * self.variation + self.smoothed.abs_diff(sample)) / 4;
            self.smoothed = (7 * self.smoothed + sample) / 8;
        }
    }
}
#[derive(Default, Clone, Debug)]
pub struct ConnectionStats {
    pub packets_sent: u64,
    pub bytes_sent: u64,
    pub packets_received: u64,
    pub bytes_received: u64,
    pub authentication_failures: u64,
    pub replays: u64,
    pub stale_rebinds: u64,
    pub rebinds: u64,
    pub malformed_chunks: u64,
    pub stream_violations: u64,
    pub blocked_by_validation: u64,
    pub oversized_outgoing: u64,
    pub reported_received: u64,
    pub reported_lost: u64,
    pub queue_overflows: u64,
}
#[derive(Clone, Debug)]
pub enum Inbound {
    Fragment(MediaFragment),
    Message { stream: u8, payload: Vec<u8> },
    Datagram { stream: u8, payload: Vec<u8> },
    Nack(Nack),
    Refresh(RefreshRequest),
    Close(CloseCode),
}
struct Validation {
    received: usize,
    sent: usize,
    first_packet: u64,
}
pub struct Connection {
    pub role: Role,
    pub session_id: u32,
    pub streams: StreamTable,
    pub memory_budget: MemoryBudget,
    pub max_datagram_size: usize,
    pub peer: SocketAddr,
    pub rtt: RttEstimator,
    pub stats: ConnectionStats,
    pub last_received: u64,
    pub last_sent: u64,
    send_key: TrafficKey,
    receive_key: TrafficKey,
    next_packet: u64,
    replay: ReplayWindow,
    sent_log: Vec<(u64, u64)>,
    arrivals: VecDeque<(u64, u64)>,
    reported_below: u64,
    last_feedback: u64,
    elicited: bool,
    pending_acks: Vec<ReliableAck>,
    ack_due: Option<u64>,
    senders: BTreeMap<u8, ReliableSender>,
    receivers: BTreeMap<u8, ReliableReceiver>,
    control: VecDeque<Vec<u8>>,
    pongs: VecDeque<(u32, u64)>,
    pings: BTreeMap<u32, u64>,
    next_ping: u32,
    ping_wanted: bool,
    validation: Option<Validation>,
}
impl Connection {
    pub const KEEPALIVE_INTERVAL: u64 = 250_000;
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        role: Role,
        session_id: u32,
        send_key: [u8; 32],
        receive_key: [u8; 32],
        streams: StreamTable,
        max_datagram_size: usize,
        peer: SocketAddr,
        now: u64,
    ) -> Self {
        let memory_budget = MemoryBudget::new(256 << 20);
        let mut c = Self {
            role,
            session_id,
            streams,
            memory_budget,
            max_datagram_size,
            peer,
            rtt: Default::default(),
            stats: Default::default(),
            last_received: now,
            last_sent: now,
            send_key: TrafficKey::new(send_key),
            receive_key: TrafficKey::new(receive_key),
            next_packet: 0,
            replay: Default::default(),
            sent_log: vec![(u64::MAX, 0); 8192],
            arrivals: VecDeque::new(),
            reported_below: 0,
            last_feedback: 0,
            elicited: false,
            pending_acks: Vec::new(),
            ack_due: None,
            senders: BTreeMap::new(),
            receivers: BTreeMap::new(),
            control: VecDeque::new(),
            pongs: VecDeque::new(),
            pings: BTreeMap::new(),
            next_ping: 0,
            ping_wanted: false,
            validation: None,
        };
        let mut entries = c.streams.entries.clone();
        entries.push(StreamEntry::CONTROL);
        for e in entries {
            if e.stream_class != StreamClass::Reliable {
                continue;
            }
            if c.sends(&e) {
                c.senders.insert(
                    e.id,
                    ReliableSender::with_budget(
                        e.id,
                        MemoryBudget::new(4 << 20),
                        Some(c.memory_budget.clone()),
                    ),
                );
            }
            if c.receives(&e) {
                c.receivers.insert(
                    e.id,
                    ReliableReceiver::with_budget(
                        e.id,
                        MemoryBudget::new(4 << 20),
                        Some(c.memory_budget.clone()),
                    ),
                );
            }
        }
        c
    }
    pub fn sends(&self, e: &StreamEntry) -> bool {
        e.direction == Direction::Bidirectional
            || e.direction
                == if self.role == Role::Host {
                    Direction::HostToClient
                } else {
                    Direction::ClientToHost
                }
    }
    pub fn receives(&self, e: &StreamEntry) -> bool {
        e.direction == Direction::Bidirectional
            || e.direction
                == if self.role == Role::Host {
                    Direction::ClientToHost
                } else {
                    Direction::HostToClient
                }
    }
    fn entry(&self, id: u8) -> Option<StreamEntry> {
        if id == 0 {
            Some(StreamEntry::CONTROL)
        } else {
            self.streams.entries.iter().find(|e| e.id == id).cloned()
        }
    }
    fn check_data(&mut self, id: u8, class: StreamClass) -> bool {
        if self
            .entry(id)
            .is_some_and(|e| e.stream_class == class && self.receives(&e))
        {
            true
        } else {
            self.stats.stream_violations += 1;
            false
        }
    }
    fn check_feedback(&mut self, id: u8) -> bool {
        if self.entry(id).is_some_and(|e| self.sends(&e)) {
            true
        } else {
            self.stats.stream_violations += 1;
            false
        }
    }
    pub fn receive(&mut self, datagram: &[u8], from: SocketAddr, now: u64) -> Option<Vec<Inbound>> {
        if datagram.len() > self.max_datagram_size {
            return None;
        }
        let header = ProtectedHeader::parse(datagram)?;
        if header.session_id != self.session_id {
            return None;
        }
        let pn = reconstruct_packet_number(self.replay.expected(), header.transport_seq);
        if !self.replay.accepts(pn) {
            self.stats.replays += 1;
            return None;
        }
        let Some(body) = open_packet(datagram, &self.receive_key, pn) else {
            self.stats.authentication_failures += 1;
            return None;
        };
        if from != self.peer {
            if self.replay.highest().is_some_and(|h| pn <= h) {
                self.stats.stale_rebinds += 1;
                return None;
            }
            if from.ip() != self.peer.ip() {
                self.validation = Some(Validation {
                    received: 0,
                    sent: 0,
                    first_packet: self.next_packet,
                });
                self.ping_wanted = true;
            }
            self.peer = from;
            self.stats.rebinds += 1;
        }
        self.replay.record(pn);
        if let Some(v) = &mut self.validation {
            v.received = v.received.saturating_add(datagram.len());
        }
        self.last_received = now;
        self.stats.packets_received += 1;
        self.stats.bytes_received += datagram.len() as u64;
        let parsed = Chunk::parse(&body);
        self.stats.malformed_chunks += parsed.malformed as u64;
        if pn >= self.reported_below {
            if self.arrivals.len() == 8192 {
                if let Some((old, _)) = self.arrivals.pop_front() {
                    self.reported_below = self.reported_below.max(old.saturating_add(1));
                }
            }
            self.arrivals.push_back((pn, now));
            if parsed
                .chunks
                .iter()
                .any(|c| !matches!(c, Chunk::Feedback(_) | Chunk::Pong { .. } | Chunk::Padding))
            {
                self.elicited = true;
            }
        }
        let mut inbound = Vec::new();
        for chunk in parsed.chunks {
            match chunk {
                Chunk::Padding | Chunk::Unknown { .. } | Chunk::FrameAck(_) => {}
                Chunk::Feedback(f) => self.handle_feedback(f, header.send_time_micros, now),
                Chunk::Ping { id } => {
                    if self.pongs.len() < 64 {
                        self.pongs.push_back((id, now));
                    }
                }
                Chunk::Pong { id, hold_micros } => {
                    if let Some(sent) = self.pings.remove(&id) {
                        if now > sent.saturating_add(hold_micros as u64) {
                            self.rtt.add(now - sent - hold_micros as u64);
                        }
                    }
                }
                Chunk::Close(c) => inbound.push(Inbound::Close(c)),
                Chunk::Reliable(s) => {
                    if !self.check_data(s.stream, StreamClass::Reliable) {
                        continue;
                    }
                    if let Some(receiver) = self.receivers.get_mut(&s.stream) {
                        if let ReliableOutcome::Accepted { ack, deliver } = receiver.receive(&s) {
                            if ack {
                                let ack = ReliableAck {
                                    stream: s.stream,
                                    msg_seq: s.msg_seq,
                                };
                                if !self.pending_acks.contains(&ack)
                                    && self.pending_acks.len() < 8192
                                {
                                    self.pending_acks.push(ack);
                                }
                                self.ack_due.get_or_insert(now.saturating_add(2_000));
                            }
                            inbound.extend(deliver.into_iter().map(|payload| Inbound::Message {
                                stream: s.stream,
                                payload,
                            }));
                        }
                    }
                }
                Chunk::Datagram { stream, payload } => {
                    if self.check_data(stream, StreamClass::Unreliable) {
                        inbound.push(Inbound::Datagram { stream, payload });
                    }
                }
                Chunk::MediaFragment(f) => {
                    if self.check_data(f.stream, StreamClass::Media) {
                        inbound.push(Inbound::Fragment(f));
                    }
                }
                Chunk::Nack(n) => {
                    if self.check_feedback(n.stream) {
                        inbound.push(Inbound::Nack(n));
                    }
                }
                Chunk::RefreshRequest(r) => {
                    if self.check_feedback(r.stream) {
                        inbound.push(Inbound::Refresh(r));
                    }
                }
            }
        }
        Some(inbound)
    }
    fn handle_feedback(&mut self, f: Feedback, reporter: u32, now: u64) {
        for ack in &f.acks {
            if let Some(s) = self.senders.get_mut(&ack.stream) {
                s.acknowledge(ack.msg_seq);
            }
        }
        let arrivals = f.arrivals();
        self.stats.reported_received += arrivals.len() as u64;
        self.stats.reported_lost += (f.received.len() - arrivals.len()) as u64;
        let Some(&(seq, time)) = arrivals.last() else {
            return;
        };
        let pn = reconstruct_packet_number(self.next_packet, seq);
        if self
            .validation
            .as_ref()
            .is_some_and(|v| pn >= v.first_packet && pn < self.next_packet)
        {
            self.validation = None;
        }
        let entry = self.sent_log[(pn % 8192) as usize];
        if entry.0 != pn {
            return;
        }
        let hold = wrapping_difference(reporter, time).max(0) as u64;
        let elapsed = now.saturating_sub(entry.1);
        if elapsed > hold {
            self.rtt.add(elapsed - hold);
        }
    }
    pub fn send(&mut self, payload: &[u8], stream: u8) -> bool {
        let max_segment = self
            .max_datagram_size
            .saturating_sub(PACKET_OVERHEAD + 3 + 9);
        self.senders
            .get_mut(&stream)
            .is_some_and(|s| s.enqueue(payload, max_segment))
    }
    pub fn queue(&mut self, chunk: Chunk) -> bool {
        let limit = self.max_datagram_size.saturating_sub(PACKET_OVERHEAD);
        if let Chunk::Nack(n) = chunk {
            if !n.entries.is_empty() {
                let capacity = limit.saturating_sub(4) / 8;
                if capacity == 0 {
                    self.stats.oversized_outgoing += 1;
                    return false;
                }
                for range in n.entries.chunks(capacity) {
                    if self.control.len() >= 1024 {
                        self.stats.queue_overflows += 1;
                        return false;
                    }
                    self.control.push_back(
                        Chunk::Nack(Nack {
                            stream: n.stream,
                            entries: range.to_vec(),
                        })
                        .encoded(),
                    );
                }
                return true;
            }
            return self.queue_encoded(Chunk::Nack(n).encoded(), limit);
        }
        self.queue_encoded(chunk.encoded(), limit)
    }
    fn queue_encoded(&mut self, encoded: Vec<u8>, limit: usize) -> bool {
        if encoded.len() > limit {
            self.stats.oversized_outgoing += 1;
            return false;
        }
        if self.control.len() >= 1024 {
            self.stats.queue_overflows += 1;
            return false;
        }
        self.control.push_back(encoded);
        true
    }
    pub fn seal(&mut self, chunks: &[u8], now: u64) -> Option<Vec<u8>> {
        let size = chunks.len() + PACKET_OVERHEAD;
        if size > self.max_datagram_size {
            self.stats.oversized_outgoing += 1;
            return None;
        }
        if let Some(v) = &mut self.validation {
            if v.sent.saturating_add(size) > 3 * v.received {
                self.stats.blocked_by_validation += 1;
                return None;
            }
            v.sent += size;
        }
        if self.next_packet == u64::MAX {
            return None;
        }
        let pn = self.next_packet;
        let header = ProtectedHeader {
            flags: 0,
            session_id: self.session_id,
            transport_seq: pn as u32,
            send_time_micros: now as u32,
        };
        let packet = seal_packet(header, &self.send_key, pn, chunks).ok()?;
        self.next_packet += 1;
        self.sent_log[(pn % 8192) as usize] = (pn, now);
        self.last_sent = now;
        self.stats.packets_sent += 1;
        self.stats.bytes_sent += size as u64;
        Some(packet)
    }
    pub fn request_ping(&mut self) {
        self.ping_wanted = true;
    }
    pub fn is_validating_address(&self) -> bool {
        self.validation.is_some()
    }
    pub fn latency_budget(&self) -> u64 {
        (2 * self.rtt.smoothed + 20_000).clamp(50_000, 150_000)
    }
    fn retransmit_timeout(&self) -> u64 {
        (self.rtt.smoothed * 3 / 2).max(20_000)
    }
    pub fn flush(&mut self, now: u64) -> Vec<Vec<u8>> {
        let mut chunks = Vec::new();
        while let Some((id, arrival)) = self.pongs.pop_front() {
            chunks.push(
                Chunk::Pong {
                    id,
                    hold_micros: now.saturating_sub(arrival).min(u32::MAX as u64) as u32,
                }
                .encoded(),
            );
        }
        if self.feedback_due().is_some_and(|d| now >= d) {
            chunks.extend(self.build_feedback());
            self.last_feedback = now;
        }
        let timeout = self.retransmit_timeout();
        for sender in self.senders.values_mut() {
            chunks.extend(
                sender
                    .due(now, timeout)
                    .into_iter()
                    .map(|s| Chunk::Reliable(s).encoded()),
            );
        }
        chunks.extend(self.control.drain(..));
        if self.ping_wanted
            || (chunks.is_empty() && now >= self.last_sent.saturating_add(Self::KEEPALIVE_INTERVAL))
        {
            self.ping_wanted = false;
            if self.pings.len() >= 16 {
                if let Some((&id, _)) = self.pings.iter().min_by_key(|(_, t)| *t) {
                    self.pings.remove(&id);
                }
            }
            self.pings.insert(self.next_ping, now);
            chunks.push(Chunk::Ping { id: self.next_ping }.encoded());
            self.next_ping = self.next_ping.wrapping_add(1);
        }
        let limit = self.max_datagram_size.saturating_sub(PACKET_OVERHEAD);
        let mut out = Vec::new();
        let mut current = Vec::new();
        for chunk in chunks {
            if chunk.len() > limit {
                self.stats.oversized_outgoing += 1;
                continue;
            }
            if !current.is_empty() && current.len() + chunk.len() > limit {
                if let Some(d) = self.seal(&current, now) {
                    out.push(d);
                }
                current.clear();
            }
            current.extend(chunk);
        }
        if !current.is_empty() {
            if let Some(d) = self.seal(&current, now) {
                out.push(d);
            }
        }
        out
    }
    fn build_feedback(&mut self) -> Vec<Vec<u8>> {
        let mut arrivals: Vec<_> = self.arrivals.drain(..).collect();
        arrivals.sort_unstable_by_key(|(pn, _)| *pn);
        arrivals.dedup_by_key(|(pn, _)| *pn);
        let mut remaining = VecDeque::from(arrivals);
        let mut acks = VecDeque::from(std::mem::take(&mut self.pending_acks));
        self.ack_due = None;
        let mut chunks = Vec::new();
        let room = self.max_datagram_size.saturating_sub(PACKET_OVERHEAD);
        loop {
            let n = acks.len().min(32);
            let max_count = room.saturating_sub(15 + 5 * n) * 8 / 17;
            let base = remaining.front().map_or(0, |a| a.0);
            let mut covered = Vec::new();
            let mut count = 0;
            while remaining
                .front()
                .is_some_and(|a| a.0 - base < max_count as u64)
            {
                let (pn, time) = remaining.pop_front().unwrap();
                covered.push(((pn - base) as usize, time as u32));
                count = (pn - base) as usize + 1;
            }
            let entries: Vec<_> = acks.drain(..n).collect();
            chunks.push(
                Chunk::Feedback(Feedback::from_arrivals(
                    base as u32,
                    count,
                    &covered,
                    entries,
                ))
                .encoded(),
            );
            if count > 0 {
                self.reported_below = base + count as u64;
            }
            if remaining.is_empty() && acks.is_empty() {
                break;
            }
            if max_count == 0 {
                break;
            }
        }
        self.elicited = false;
        chunks
    }
    fn feedback_due(&self) -> Option<u64> {
        let arrival = (!self.arrivals.is_empty()).then_some(
            self.last_feedback
                .saturating_add(if self.elicited { 20_000 } else { 200_000 }),
        );
        match (arrival, self.ack_due) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }
    pub fn next_deadline(&self) -> u64 {
        let mut d = self.last_sent.saturating_add(Self::KEEPALIVE_INTERVAL);
        if let Some(f) = self.feedback_due() {
            d = d.min(f);
        }
        let timeout = self.retransmit_timeout();
        for s in self.senders.values() {
            if let Some(t) = s.next_deadline(timeout) {
                d = d.min(t);
            }
            if !s.is_idle() { /* next_deadline also covers never-sent messages */ }
        }
        if !self.control.is_empty() || !self.pongs.is_empty() || self.ping_wanted {
            d = 0;
        }
        d
    }
}

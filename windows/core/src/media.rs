#![allow(clippy::collapsible_if)]
//! Apple-compatible HEVC framing, paced fragmentation and bounded FEC recovery.
use crate::bytes::{ByteReader, ByteWriter};
use crate::crypto::serial_newer;
use crate::fec::{FecLayout, ReedSolomon};
use crate::memory::{MemoryBudget, MemoryReservation};
use crate::wire::{
    Chunk, FecParameters, MediaFragment, Nack, NackEntry, RefreshPreferred, RefreshReason,
    RefreshRequest,
};
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::Arc;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodecConfig {
    pub vps: Vec<u8>,
    pub sps: Vec<u8>,
    pub pps: Vec<u8>,
}
impl CodecConfig {
    pub fn encoded(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        for nal in [&self.vps, &self.sps, &self.pps] {
            w.u32(nal.len() as u32);
            w.append(nal);
        }
        w.bytes
    }
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        let mut r = ByteReader::new(bytes);
        let mut nal = || {
            let n = r.u32().ok()? as usize;
            if n == 0 {
                return None;
            }
            Some(r.take(n).ok()?.to_vec())
        };
        Some(Self {
            vps: nal()?,
            sps: nal()?,
            pps: nal()?,
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostFrameTimings {
    pub capture_micros: u32,
    pub encode_micros: u32,
    pub sample_id: u64,
}
impl HostFrameTimings {
    fn encoded(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        w.u8(1);
        w.u32(self.capture_micros);
        w.u32(self.encode_micros);
        w.u64(self.sample_id);
        w.bytes
    }
    fn parse(b: &[u8]) -> Option<Self> {
        let mut r = ByteReader::new(b);
        if b.len() != 17 || r.u8().ok()? != 1 {
            return None;
        }
        let s = Self {
            capture_micros: r.u32().ok()?,
            encode_micros: r.u32().ok()?,
            sample_id: r.u64().ok()?,
        };
        (s.capture_micros <= 1_000_000 && s.encode_micros <= 1_000_000).then_some(s)
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum FrameType {
    Idr = 0,
    Predicted = 1,
    Audio = 2,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum RefKind {
    None = 0,
    Previous = 1,
    Ltr = 2,
    LtrAny = 3,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrameHeader {
    pub frame_type: FrameType,
    pub ref_kind: RefKind,
    pub flags: u8,
    pub config_generation: u32,
    pub capture_time_micros: u32,
    pub ref_frame_id: Option<u32>,
    pub codec_config: Option<CodecConfig>,
    pub host_timings: Option<HostFrameTimings>,
}
impl FrameHeader {
    pub fn encoded(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        w.u8(self.frame_type as u8);
        w.u8(self.ref_kind as u8);
        w.u8(self.flags);
        w.u32(self.config_generation);
        w.u32(self.capture_time_micros);
        if self.ref_kind == RefKind::Ltr {
            w.u32(self.ref_frame_id.unwrap_or(0));
        }
        let mut ext = ByteWriter::new();
        if let Some(c) = &self.codec_config {
            ext.tlv(1, &c.encoded());
        }
        if let Some(t) = &self.host_timings {
            if ext.bytes.len() + 20 <= u16::MAX as usize {
                ext.tlv(0xf0, &t.encoded());
            }
        }
        w.u16(ext.bytes.len() as u16);
        w.append(&ext.bytes);
        w.bytes
    }
    pub fn parse(b: &[u8]) -> Option<(Self, usize)> {
        let mut r = ByteReader::new(b);
        let frame_type = match r.u8().ok()? {
            0 => FrameType::Idr,
            1 => FrameType::Predicted,
            2 => FrameType::Audio,
            _ => return None,
        };
        let ref_kind = match r.u8().ok()? {
            0 => RefKind::None,
            1 => RefKind::Previous,
            2 => RefKind::Ltr,
            3 => RefKind::LtrAny,
            _ => return None,
        };
        let flags = r.u8().ok()?;
        let config_generation = r.u32().ok()?;
        let capture_time_micros = r.u32().ok()?;
        let ref_frame_id = if ref_kind == RefKind::Ltr {
            Some(r.u32().ok()?)
        } else {
            None
        };
        let n = r.u16().ok()? as usize;
        let ext = r.take(n).ok()?;
        let offset = r.offset();
        let mut e = ByteReader::new(ext);
        let mut codec_config = None;
        let mut host_timings = None;
        let mut timings = 0;
        while e.remaining() != 0 {
            let t = e.u8().ok()?;
            let n = e.u16().ok()? as usize;
            let value = e.take(n).ok()?;
            if t == 1 {
                codec_config = Some(CodecConfig::parse(value)?);
            } else if t == 0xf0 {
                timings += 1;
                host_timings = if timings == 1 {
                    HostFrameTimings::parse(value)
                } else {
                    None
                };
            }
        }
        if frame_type == FrameType::Idr && codec_config.is_none() {
            return None;
        }
        Some((
            Self {
                frame_type,
                ref_kind,
                flags,
                config_generation,
                capture_time_micros,
                ref_frame_id,
                codec_config,
                host_timings,
            },
            offset,
        ))
    }
}
#[derive(Clone, Debug)]
pub struct EncodedFrame {
    pub is_keyframe: bool,
    pub payload: Vec<u8>,
    pub codec_config: Option<CodecConfig>,
    pub capture_time_micros: u64,
    pub host_timings: Option<HostFrameTimings>,
}
#[derive(Clone, Debug)]
pub struct DeliveredFrame {
    pub frame_id: u32,
    pub header: FrameHeader,
    pub bytes: Arc<[u8]>,
    pub payload_offset: usize,
    pub completed_at: u64,
    reservations: Vec<MemoryReservation>,
}
impl DeliveredFrame {
    pub fn payload(&self) -> &[u8] {
        &self.bytes[self.payload_offset..]
    }
    pub fn reserved_bytes(&self) -> usize {
        self.reservations.iter().map(MemoryReservation::bytes).sum()
    }
}
#[derive(Default, Clone, Debug)]
pub struct VideoSenderStats {
    pub frames: u64,
    pub keyframes: u64,
    pub fragments: u64,
    pub retransmissions: u64,
    pub expired: u64,
    pub refresh_requests: u64,
    pub parity_fragments: u64,
}
#[derive(Clone, Debug)]
struct Pacer {
    bitrate: usize,
    interval: u64,
    tokens: f64,
    last: Option<u64>,
    drain_by: u64,
}
impl Pacer {
    fn rate(&self, backlog: usize, now: u64) -> f64 {
        (1.25 * self.bitrate as f64 / 8.)
            .max(backlog as f64 * 1_000_000. / self.drain_by.saturating_sub(now).max(2_000) as f64)
    }
    fn refill(&mut self, now: u64, backlog: usize, mtu: usize) {
        let burst = (32 * mtu) as f64;
        self.tokens = match self.last {
            None => burst,
            Some(last) => (self.tokens
                + self.rate(backlog, now) * now.saturating_sub(last) as f64 / 1_000_000.)
                .min(burst),
        };
        self.last = Some(now);
    }
    fn wait(&self, bytes: usize, backlog: usize, now: u64) -> u64 {
        let missing = bytes as f64 - self.tokens;
        if missing <= 0. {
            0
        } else {
            (missing / self.rate(backlog, now) * 1_000_000.) as u64 + 1
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct Item {
    frame_id: u32,
    index: usize,
    parity: bool,
}
struct StoredFrame {
    bytes: Vec<u8>,
    stride: usize,
    count: usize,
    keyframe: bool,
    submitted: u64,
    deadline: u64,
    extended: u64,
    fec: Option<FecParameters>,
    parity: Vec<u8>,
    sent: Vec<Option<u64>>,
}
impl StoredFrame {
    fn payload(&self, i: Item) -> &[u8] {
        if i.parity {
            &self.parity[i.index * self.stride..(i.index + 1) * self.stride]
        } else {
            &self.bytes[i.index * self.stride..((i.index + 1) * self.stride).min(self.bytes.len())]
        }
    }
}
pub struct VideoSender {
    pub stream: u8,
    pub stats: VideoSenderStats,
    pub fec_percent: usize,
    pub fec_min_parity: usize,
    pacer: Pacer,
    codec: ReedSolomon,
    next_frame: u32,
    frames: HashMap<u32, StoredFrame>,
    order: VecDeque<u32>,
    stored: usize,
    fresh: VecDeque<Item>,
    retransmit: VecDeque<Item>,
    queued: HashSet<Item>,
    refresh_seen: VecDeque<(u32, u64)>,
}
impl VideoSender {
    pub const STALL_CREDIT: u64 = 400_000;
    pub fn new(stream: u8, bitrate: usize, frame_rate: usize) -> Self {
        Self {
            stream,
            stats: Default::default(),
            fec_percent: 0,
            fec_min_parity: 1,
            pacer: Pacer {
                bitrate,
                interval: 1_000_000 / frame_rate.max(1) as u64,
                tokens: 0.,
                last: None,
                drain_by: 0,
            },
            codec: Default::default(),
            next_frame: 1,
            frames: HashMap::new(),
            order: VecDeque::new(),
            stored: 0,
            fresh: VecDeque::new(),
            retransmit: VecDeque::new(),
            queued: HashSet::new(),
            refresh_seen: VecDeque::new(),
        }
    }
    pub fn submit(&mut self, frame: EncodedFrame, now: u64, mtu: usize, budget: u64) {
        let header = FrameHeader {
            frame_type: if frame.is_keyframe {
                FrameType::Idr
            } else {
                FrameType::Predicted
            },
            ref_kind: if frame.is_keyframe {
                RefKind::None
            } else {
                RefKind::Previous
            },
            flags: 0,
            config_generation: 0,
            capture_time_micros: frame.capture_time_micros as u32,
            ref_frame_id: None,
            codec_config: if frame.is_keyframe {
                frame.codec_config
            } else {
                None
            },
            host_timings: frame.host_timings,
        };
        let mut bytes = header.encoded();
        bytes.extend(frame.payload);
        let protected = self.fec_percent > 0;
        let stride = mtu.saturating_sub(MediaFragment::datagram_overhead(protected));
        if stride == 0 || stride > u16::MAX as usize || bytes.len() > 16 << 20 {
            return;
        }
        let count = bytes.len().div_ceil(stride);
        if count == 0 || count > u16::MAX as usize {
            return;
        }
        let id = self.next_frame;
        self.next_frame = next_id(id);
        let layout =
            protected.then(|| FecLayout::for_frame(count, self.fec_percent, self.fec_min_parity));
        let fec = layout.as_ref().map(|l| FecParameters {
            max_block_length: l.max_block_length as u8,
            parity_per_block: l.parity_per_block as u8,
            last_length: (bytes.len() - (count - 1) * stride) as u16,
        });
        let mut parity = Vec::new();
        if let Some(l) = &layout {
            if l.parity_count()
                .checked_mul(stride)
                .and_then(|size| size.checked_add(bytes.len()))
                .is_none_or(|size| size > 16 << 20)
            {
                return;
            }
            for block in 0..l.block_count {
                let range = l.range_of_block(block);
                let mut padded = vec![0; range.len() * stride];
                let start = range.start * stride;
                let end = (range.end * stride).min(bytes.len());
                padded[..end - start].copy_from_slice(&bytes[start..end]);
                let Ok(p) = self
                    .codec
                    .encode(&padded, range.len(), l.parity_per_block, stride)
                else {
                    return;
                };
                parity.extend(p);
            }
        }
        self.stored += bytes.len() + parity.len();
        self.frames.insert(
            id,
            StoredFrame {
                bytes,
                stride,
                count,
                keyframe: frame.is_keyframe,
                submitted: now,
                deadline: now.saturating_add(budget),
                extended: 0,
                fec,
                parity,
                sent: vec![None; count],
            },
        );
        self.order.push_back(id);
        self.evict(now);
        if self.frames.contains_key(&id) {
            if let Some(l) = layout {
                for b in 0..l.block_count {
                    for i in l.range_of_block(b) {
                        self.fresh.push_back(Item {
                            frame_id: id,
                            index: i,
                            parity: false,
                        });
                    }
                    for j in 0..l.parity_per_block {
                        self.fresh.push_back(Item {
                            frame_id: id,
                            index: b * l.parity_per_block + j,
                            parity: true,
                        });
                    }
                }
            } else {
                for index in 0..count {
                    self.fresh.push_back(Item {
                        frame_id: id,
                        index,
                        parity: false,
                    });
                }
            }
        }
        self.pacer.drain_by = now.saturating_add(self.pacer.interval);
        self.stats.frames += 1;
        if frame.is_keyframe {
            self.stats.keyframes += 1;
        }
    }
    fn evict(&mut self, now: u64) {
        while let Some(id) = self.order.front().copied() {
            let f = &self.frames[&id];
            if now <= f.submitted.saturating_add(500_000) && self.stored <= 16 << 20 {
                break;
            }
            self.order.pop_front();
            let f = self.frames.remove(&id).unwrap();
            self.stored -= f.bytes.len() + f.parity.len();
        }
        self.fresh.retain(|i| self.frames.contains_key(&i.frame_id));
        self.retransmit
            .retain(|i| self.frames.contains_key(&i.frame_id));
        self.queued
            .retain(|i| self.frames.contains_key(&i.frame_id));
    }
    pub fn extend_deadlines(&mut self, gap: u64) {
        for f in self.frames.values_mut() {
            let extra = gap.min(Self::STALL_CREDIT - f.extended);
            f.deadline = f.deadline.saturating_add(extra);
            f.extended += extra;
        }
    }
    pub fn handle_nack(&mut self, n: &Nack, now: u64, srtt: u64) {
        for e in &n.entries {
            let Some(f) = self.frames.get(&e.frame_id) else {
                continue;
            };
            if now >= f.deadline {
                continue;
            }
            let first = if e.count == 0 { 0 } else { e.first as usize };
            let end = if e.count == 0 {
                f.count
            } else {
                f.count.min(e.first as usize + e.count as usize)
            };
            for index in first..end {
                if f.sent[index].is_some_and(|t| now >= t.saturating_add(srtt / 2)) {
                    let i = Item {
                        frame_id: e.frame_id,
                        index,
                        parity: false,
                    };
                    if self.queued.insert(i) {
                        self.retransmit.push_back(i);
                    }
                }
            }
        }
    }
    pub fn handle_refresh(&mut self, r: &RefreshRequest, now: u64) -> bool {
        self.refresh_seen
            .retain(|(_, t)| now <= t.saturating_add(10_000_000));
        if self.refresh_seen.iter().any(|(id, _)| *id == r.req_id) {
            return false;
        }
        if self.refresh_seen.len() >= 256 {
            self.refresh_seen.pop_front();
        }
        self.refresh_seen.push_back((r.req_id, now));
        self.stats.refresh_requests += 1;
        true
    }
    fn size(&self, i: Item) -> usize {
        self.frames.get(&i.frame_id).map_or(0, |f| {
            f.payload(i).len() + MediaFragment::datagram_overhead(f.fec.is_some())
        })
    }
    fn backlog(&self) -> usize {
        self.retransmit
            .iter()
            .chain(&self.fresh)
            .map(|i| self.size(*i))
            .sum()
    }
    pub fn drain<F: FnMut(&[u8]) -> Option<Vec<u8>>>(
        &mut self,
        now: u64,
        mtu: usize,
        mut seal: F,
    ) -> Vec<Vec<u8>> {
        self.evict(now);
        self.pacer.refill(now, self.backlog(), mtu);
        let mut out = Vec::new();
        loop {
            let retry = !self.retransmit.is_empty();
            let Some(i) = self.retransmit.front().or(self.fresh.front()).copied() else {
                break;
            };
            let Some(f) = self.frames.get(&i.frame_id) else {
                self.pop(retry);
                continue;
            };
            if now >= f.deadline {
                self.pop(retry);
                self.stats.expired += 1;
                continue;
            }
            let size = self.size(i);
            if self.pacer.tokens < size as f64 {
                break;
            }
            let fragment = MediaFragment {
                stream: self.stream,
                flags: u8::from(f.keyframe)
                    | if retry { 2 } else { 0 }
                    | if i.parity { 8 } else { 0 },
                frame_id: i.frame_id,
                index: i.index as u16,
                count: f.count as u16,
                stride: f.stride as u16,
                fec: f.fec.clone(),
                payload: f.payload(i).to_vec(),
            };
            let encoded = Chunk::MediaFragment(fragment).encoded();
            let Some(d) = seal(&encoded) else { break };
            self.pacer.tokens -= size as f64;
            self.pop(retry);
            let f = self.frames.get_mut(&i.frame_id).unwrap();
            if i.parity {
                self.stats.parity_fragments += 1;
            } else {
                f.sent[i.index] = Some(now);
            }
            self.stats.fragments += 1;
            if retry {
                self.stats.retransmissions += 1;
            }
            out.push(d);
        }
        out
    }
    fn pop(&mut self, retry: bool) {
        if retry {
            if let Some(i) = self.retransmit.pop_front() {
                self.queued.remove(&i);
            }
        } else {
            self.fresh.pop_front();
        }
    }
    pub fn next_deadline(&self, now: u64) -> Option<u64> {
        let i = self.retransmit.front().or(self.fresh.front())?;
        Some(now.saturating_add(self.pacer.wait(self.size(*i), self.backlog(), now)))
    }
    pub fn reset(&mut self) {
        self.frames.clear();
        self.order.clear();
        self.stored = 0;
        self.fresh.clear();
        self.retransmit.clear();
        self.queued.clear();
    }
    pub fn stored_bytes(&self) -> usize {
        self.stored
    }
}

#[derive(Default, Clone, Debug)]
pub struct VideoReceiverStats {
    pub frames_delivered: u64,
    pub keyframes_delivered: u64,
    pub frames_lost: u64,
    pub frames_undecodable: u64,
    pub duplicate_fragments: u64,
    pub redundant_fragments: u64,
    pub discarded_fragments: u64,
    pub nacked_fragments: u64,
    pub refresh_requests: u64,
    pub fec_repaired: u64,
    pub memory_limit_drops: u64,
}
struct Slot {
    discovered: u64,
    deadline: u64,
    extended: u64,
    count: usize,
    stride: usize,
    fec: Option<FecParameters>,
    layout: Option<FecLayout>,
    buffer: Vec<u8>,
    received: Vec<bool>,
    have: usize,
    parity: Vec<u8>,
    parity_received: Vec<bool>,
    block_have: Vec<usize>,
    got: Vec<bool>,
    highest: Option<usize>,
    hole_since: Vec<u64>,
    later_seen: Option<u64>,
    last_nack: Vec<u64>,
    last_length: usize,
    last_arrival: u64,
    first_arrival: u64,
    whole_nack: u64,
    complete: Option<u64>,
    reservations: Vec<MemoryReservation>,
}
impl Slot {
    fn new(now: u64, budget: u64) -> Self {
        Self {
            discovered: now,
            deadline: now.saturating_add(budget),
            extended: 0,
            count: 0,
            stride: 0,
            fec: None,
            layout: None,
            buffer: Vec::new(),
            received: Vec::new(),
            have: 0,
            parity: Vec::new(),
            parity_received: Vec::new(),
            block_have: Vec::new(),
            got: Vec::new(),
            highest: None,
            hole_since: Vec::new(),
            later_seen: None,
            last_nack: Vec::new(),
            last_length: 0,
            last_arrival: 0,
            first_arrival: 0,
            whole_nack: 0,
            complete: None,
            reservations: Vec::new(),
        }
    }
}
struct Attempt {
    req_id: u32,
    reason: RefreshReason,
    started: u64,
    lifetime: u64,
    last_sent: Option<u64>,
}
pub struct VideoReceiver {
    pub stream: u8,
    pub stats: VideoReceiverStats,
    pub max_frame_bytes: usize,
    pub memory_budget: MemoryBudget,
    pub frame_interval: u64,
    shared: Option<MemoryBudget>,
    codec: ReedSolomon,
    slots: BTreeMap<u32, Slot>,
    completed: HashSet<u32>,
    completed_order: VecDeque<u32>,
    next: u32,
    highest_seen: u32,
    last_delivered: u32,
    last_keyframe: u32,
    chain: bool,
    ready: Vec<DeliveredFrame>,
    needs_refresh: Option<RefreshReason>,
    lost: u32,
    attempt: Option<Attempt>,
    next_req: u32,
}
impl VideoReceiver {
    pub const SILENCE: u64 = 30_000;
    pub fn new(stream: u8, shared: Option<MemoryBudget>) -> Self {
        Self {
            stream,
            stats: Default::default(),
            max_frame_bytes: 32 << 20,
            memory_budget: MemoryBudget::new(64 << 20),
            frame_interval: 16_667,
            shared,
            codec: Default::default(),
            slots: BTreeMap::new(),
            completed: HashSet::new(),
            completed_order: VecDeque::new(),
            next: 1,
            highest_seen: 0,
            last_delivered: 0,
            last_keyframe: 0,
            chain: false,
            ready: Vec::new(),
            needs_refresh: None,
            lost: 0,
            attempt: None,
            next_req: 0,
        }
    }
    pub fn receive(&mut self, f: MediaFragment, now: u64, budget: u64) {
        let parity = f.flags & 8 != 0;
        let count = f.count as usize;
        let stride = f.stride as usize;
        let index = f.index as usize;
        if count == 0 || stride == 0 || f.payload.is_empty() || f.payload.len() > stride {
            self.stats.discarded_fragments += 1;
            return;
        }
        let layout = if let Some(p) = &f.fec {
            if p.last_length == 0 || p.last_length > f.stride {
                self.stats.discarded_fragments += 1;
                return;
            }
            let Some(l) = FecLayout::new(
                count,
                p.max_block_length as usize,
                p.parity_per_block as usize,
            ) else {
                self.stats.discarded_fragments += 1;
                return;
            };
            Some(l)
        } else {
            None
        };
        if parity {
            if layout.as_ref().is_none_or(|l| index >= l.parity_count())
                || f.payload.len() != stride
            {
                self.stats.discarded_fragments += 1;
                return;
            }
        } else if index >= count
            || (index != count - 1 && f.payload.len() != stride)
            || (index == count - 1
                && f.fec
                    .as_ref()
                    .is_some_and(|p| f.payload.len() != p.last_length as usize))
        {
            self.stats.discarded_fragments += 1;
            return;
        }
        let id = f.frame_id;
        if id == 0 || self.completed.contains(&id) || serial_newer(self.next, id) {
            self.stats.redundant_fragments += 1;
            return;
        }
        self.note_frame(id, now, budget);
        let Some(mut s) = self.slots.remove(&id) else {
            self.stats.discarded_fragments += 1;
            return;
        };
        if s.count == 0 {
            let p = layout.as_ref().map_or(0, FecLayout::parity_count);
            let charge = 2 * (count + p) * stride
                + (count + p) * 32
                + layout.as_ref().map_or(0, |l| l.block_count) * 8
                + 512;
            if (count + p) * stride > self.max_frame_bytes {
                self.stats.discarded_fragments += 1;
                self.slots.insert(id, s);
                return;
            }
            let Some(local) = self.memory_budget.reserve(charge) else {
                self.stats.memory_limit_drops += 1;
                self.slots.insert(id, s);
                return;
            };
            let mut reservations = vec![local];
            if let Some(b) = &self.shared {
                let Some(r) = b.reserve(charge) else {
                    self.stats.memory_limit_drops += 1;
                    self.slots.insert(id, s);
                    return;
                };
                reservations.push(r);
            }
            s.reservations = reservations;
            s.count = count;
            s.stride = stride;
            s.fec = f.fec.clone();
            s.layout = layout;
            s.buffer = vec![0; count * stride];
            s.received = vec![false; count];
            s.parity = vec![0; p * stride];
            s.parity_received = vec![false; p];
            s.block_have = vec![0; s.layout.as_ref().map_or(0, |l| l.block_count)];
            s.got = vec![false; count + p];
            s.hole_since = vec![0; count + p];
            s.last_nack = vec![0; count];
            s.first_arrival = now;
        } else if s.count != count || s.stride != stride || s.fec != f.fec {
            self.stats.discarded_fragments += 1;
            self.slots.insert(id, s);
            return;
        }
        let position = if let Some(l) = &s.layout {
            if parity {
                l.position_of_parity(index)
            } else {
                l.position_of_data(index)
            }
        } else {
            index
        };
        let block = s.layout.as_ref().map(|l| {
            if parity {
                index / l.parity_per_block
            } else {
                l.block_of_data(index)
            }
        });
        if parity {
            if s.parity_received[index] {
                self.stats.duplicate_fragments += 1;
                self.slots.insert(id, s);
                return;
            }
            let l = s.layout.as_ref().unwrap();
            if l.range_of_block(block.unwrap()).all(|i| s.received[i]) {
                self.stats.redundant_fragments += 1;
                self.slots.insert(id, s);
                return;
            }
            s.parity[index * stride..(index + 1) * stride].copy_from_slice(&f.payload);
            s.parity_received[index] = true;
            s.block_have[block.unwrap()] += 1;
        } else {
            if s.received[index] {
                self.stats.duplicate_fragments += 1;
                self.slots.insert(id, s);
                return;
            }
            s.buffer[index * stride..index * stride + f.payload.len()].copy_from_slice(&f.payload);
            s.received[index] = true;
            s.have += 1;
            if let Some(b) = block {
                s.block_have[b] += 1;
            }
            if index == count - 1 {
                s.last_length = f.payload.len();
            }
        }
        s.last_arrival = now;
        s.got[position] = true;
        if s.highest.is_none_or(|h| position > h) {
            for i in s.highest.map_or(0, |h| h + 1)..position {
                if !s.got[i] {
                    s.hole_since[i] = now;
                }
            }
            s.highest = Some(position);
        }
        if let Some(b) = block {
            self.rebuild(&mut s, b);
        }
        if s.have == count {
            s.complete = Some(now);
            let length = s
                .fec
                .as_ref()
                .map_or(s.last_length, |p| p.last_length as usize);
            s.buffer.truncate((count - 1) * stride + length);
            s.parity.clear();
            self.remember(id);
        }
        self.slots.insert(id, s);
        self.deliver();
    }
    fn rebuild(&mut self, s: &mut Slot, b: usize) {
        let l = s.layout.as_ref().unwrap();
        let range = l.range_of_block(b);
        let missing: Vec<usize> = range.clone().filter(|i| !s.received[*i]).collect();
        if missing.is_empty() || s.block_have[b] < range.len() {
            return;
        }
        let rows: Vec<(usize, &[u8])> = (0..l.parity_per_block)
            .filter(|j| s.parity_received[b * l.parity_per_block + j])
            .take(missing.len())
            .map(|j| {
                (
                    j,
                    &s.parity[(b * l.parity_per_block + j) * s.stride
                        ..(b * l.parity_per_block + j + 1) * s.stride],
                )
            })
            .collect();
        let local: Vec<usize> = missing.iter().map(|i| i - range.start).collect();
        if self
            .codec
            .recover(
                &mut s.buffer[range.start * s.stride..range.end * s.stride],
                range.len(),
                l.parity_per_block,
                s.stride,
                &local,
                &rows,
            )
            .is_err()
        {
            return;
        }
        for i in &missing {
            s.received[*i] = true;
            s.got[l.position_of_data(*i)] = true;
        }
        s.have += missing.len();
        s.block_have[b] = range.len() + l.parity_per_block;
        self.stats.fec_repaired += missing.len() as u64;
    }
    fn note_frame(&mut self, id: u32, now: u64, budget: u64) {
        if self.slots.contains_key(&id) {
            return;
        }
        let base = if self.highest_seen == 0 {
            previous_id(self.next)
        } else {
            self.highest_seen
        };
        if serial_newer(id, base) {
            if id.wrapping_sub(base) > 64 {
                self.slots.retain(|key, _| !serial_newer(id, *key));
                self.next = id;
                self.break_chain(previous_id(id));
            } else {
                let mut skipped = next_id(base);
                while skipped != id {
                    if self.slots.len() < 128 && !self.completed.contains(&skipped) {
                        self.slots
                            .entry(skipped)
                            .or_insert_with(|| Slot::new(now, budget));
                    }
                    skipped = next_id(skipped);
                }
            }
            self.highest_seen = id;
            for s in self.slots.values_mut() {
                if s.complete.is_none() && s.later_seen.is_none() {
                    s.later_seen = Some(now);
                }
            }
        }
        if self.slots.len() < 128 {
            self.slots
                .entry(id)
                .or_insert_with(|| Slot::new(now, budget));
        }
    }
    fn remember(&mut self, id: u32) {
        if self.completed.insert(id) {
            self.completed_order.push_back(id);
        }
        if self.completed_order.len() > 256 {
            self.completed
                .remove(&self.completed_order.pop_front().unwrap());
        }
    }
    fn deliver(&mut self) {
        loop {
            if !self
                .slots
                .get(&self.next)
                .is_some_and(|s| s.complete.is_some())
            {
                break;
            }
            let id = self.next;
            let s = self.slots.remove(&id).unwrap();
            self.next = next_id(id);
            let Some((header, offset)) = FrameHeader::parse(&s.buffer) else {
                self.break_chain(id);
                continue;
            };
            let deliverable = match header.ref_kind {
                RefKind::None => header.frame_type == FrameType::Idr,
                RefKind::Previous => self.chain && self.last_delivered == previous_id(id),
                _ => false,
            };
            if !deliverable {
                self.stats.frames_undecodable += 1;
                self.break_chain(id);
                continue;
            }
            if self.ready.len() >= 64 {
                self.ready.clear();
                self.break_chain(id);
                if header.frame_type != FrameType::Idr {
                    continue;
                }
            }
            self.chain = true;
            self.last_delivered = id;
            self.stats.frames_delivered += 1;
            if header.frame_type == FrameType::Idr {
                self.last_keyframe = id;
                self.stats.keyframes_delivered += 1;
            }
            self.ready.push(DeliveredFrame {
                frame_id: id,
                header,
                bytes: s.buffer.into(),
                payload_offset: offset,
                completed_at: s.complete.unwrap(),
                reservations: s.reservations,
            });
        }
    }
    fn break_chain(&mut self, id: u32) {
        self.chain = false;
        self.lost = id;
        if self.needs_refresh.is_none() {
            self.needs_refresh = Some(RefreshReason::Loss);
        }
    }
    pub fn take_frames(&mut self) -> Vec<DeliveredFrame> {
        std::mem::take(&mut self.ready)
    }
    pub fn decoded(&mut self, id: u32, keyframe: bool) {
        if keyframe && (self.lost == 0 || serial_newer(id, self.lost)) {
            self.needs_refresh = None;
            self.attempt = None;
        }
    }
    pub fn decoder_failed(&mut self, id: u32) {
        if self.last_keyframe != 0 && serial_newer(self.last_keyframe, id) {
            return;
        }
        self.chain = false;
        if self.lost == 0 || serial_newer(id, self.lost) {
            self.lost = id;
        }
        if self.needs_refresh != Some(RefreshReason::DecoderReset) {
            self.needs_refresh = Some(RefreshReason::DecoderReset);
            self.attempt = None;
        }
    }
    pub fn link_resumed(&mut self, gap: u64) {
        for s in self.slots.values_mut().filter(|s| s.complete.is_none()) {
            let extra = gap.min(400_000 - s.extended);
            s.deadline = s.deadline.saturating_add(extra);
            s.extended += extra;
        }
    }
    pub fn poll(&mut self, now: u64, srtt: u64, budget: u64, last_heard: u64) -> Vec<Chunk> {
        if now <= last_heard.saturating_add(Self::SILENCE) {
            self.expire(now);
        }
        let mut chunks = Vec::new();
        if let Some(n) = self.nack(now, srtt) {
            chunks.push(Chunk::Nack(n));
        }
        if let Some(r) = self.refresh(now, srtt, budget) {
            chunks.push(Chunk::RefreshRequest(r));
        }
        chunks
    }
    fn expire(&mut self, now: u64) {
        loop {
            if let Some(s) = self.slots.get(&self.next) {
                let held = self.slots.values().filter(|s| s.complete.is_some()).count();
                if !(s.complete.is_none() && now >= s.deadline || held > 64) {
                    break;
                }
            } else if self.highest_seen == 0
                || !(self.highest_seen == self.next || serial_newer(self.highest_seen, self.next))
            {
                break;
            }
            let lost = self.next;
            self.slots.remove(&lost);
            self.remember(lost);
            self.next = next_id(lost);
            self.stats.frames_lost += 1;
            self.break_chain(lost);
            self.deliver();
        }
    }
    fn nack(&mut self, now: u64, srtt: u64) -> Option<Nack> {
        let reorder = (srtt / 4).max(1_000);
        let retry = (srtt * 3 / 2).max(2_000);
        let mut entries = Vec::new();
        for (&id, s) in &mut self.slots {
            if entries.len() >= 128 {
                break;
            }
            if s.complete.is_some() || now >= s.deadline {
                continue;
            }
            if s.count == 0 {
                if (s.whole_nack == 0 && now >= s.discovered.saturating_add(reorder))
                    || (s.whole_nack != 0 && now >= s.whole_nack.saturating_add(retry))
                {
                    entries.push(NackEntry {
                        frame_id: id,
                        first: 0,
                        count: 0,
                    });
                    s.whole_nack = now;
                }
                continue;
            }
            let tail = s
                .later_seen
                .is_some_and(|t| now >= t.saturating_add(reorder))
                || (now >= s.first_arrival.saturating_add(2 * self.frame_interval)
                    && now >= s.last_arrival.saturating_add(reorder));
            let known_lost = |position: usize| {
                !s.got[position]
                    && if s.highest.is_some_and(|h| position < h) {
                        now >= s.hole_since[position].saturating_add(reorder)
                    } else {
                        tail
                    }
            };
            let blocks = s.layout.as_ref().map_or(1, |l| l.block_count);
            let mut wanted = Vec::new();
            for b in 0..blocks {
                let data = s
                    .layout
                    .as_ref()
                    .map_or(0..s.count, |l| l.range_of_block(b));
                let parity = s.layout.as_ref().map_or(0..0, |l| {
                    b * l.parity_per_block..(b + 1) * l.parity_per_block
                });
                let mut lost = 0usize;
                let mut outstanding = 0;
                let mut eligible = Vec::new();
                for i in data {
                    if !s.received[i]
                        && known_lost(s.layout.as_ref().map_or(i, |l| l.position_of_data(i)))
                    {
                        lost += 1;
                        if s.last_nack[i] != 0 && now < s.last_nack[i].saturating_add(retry) {
                            outstanding += 1;
                        } else {
                            eligible.push(i);
                        }
                    }
                }
                for j in parity.clone() {
                    if !s.parity_received[j]
                        && known_lost(s.layout.as_ref().unwrap().position_of_parity(j))
                    {
                        lost += 1;
                    }
                }
                let need = lost.saturating_sub(parity.len() + outstanding);
                wanted.extend(eligible.into_iter().take(need));
            }
            for i in wanted {
                if let Some(e) = entries.last_mut() {
                    if e.frame_id == id && e.count != 0 && e.first as usize + e.count as usize == i
                    {
                        e.count += 1;
                        s.last_nack[i] = now;
                        self.stats.nacked_fragments += 1;
                        continue;
                    }
                }
                if entries.len() >= 128 {
                    break;
                }
                entries.push(NackEntry {
                    frame_id: id,
                    first: i as u16,
                    count: 1,
                });
                s.last_nack[i] = now;
                self.stats.nacked_fragments += 1;
            }
        }
        (!entries.is_empty()).then_some(Nack {
            stream: self.stream,
            entries,
        })
    }
    fn refresh(&mut self, now: u64, srtt: u64, budget: u64) -> Option<RefreshRequest> {
        let reason = self.needs_refresh?;
        if self
            .attempt
            .as_ref()
            .is_some_and(|a| now >= a.started.saturating_add(a.lifetime))
        {
            self.attempt = None;
        }
        if self.attempt.is_none() {
            self.attempt = Some(Attempt {
                req_id: self.next_req,
                reason,
                started: now,
                lifetime: (2 * budget).max(3 * srtt),
                last_sent: None,
            });
            self.next_req = self.next_req.wrapping_add(1);
        }
        let a = self.attempt.as_mut().unwrap();
        if a.last_sent
            .is_some_and(|t| now < t.saturating_add(srtt.max(10_000)))
        {
            return None;
        }
        a.last_sent = Some(now);
        self.stats.refresh_requests += 1;
        Some(RefreshRequest {
            stream: self.stream,
            reason: a.reason,
            preferred: RefreshPreferred::Idr,
            last_good_frame: self.last_delivered,
            lost_frame: self.lost,
            req_id: a.req_id,
        })
    }
    pub fn next_deadline(&self, now: u64, srtt: u64, last_heard: u64) -> Option<u64> {
        let silent = now > last_heard.saturating_add(Self::SILENCE);
        let mut deadline = None;
        let mut consider = |t: u64| deadline = Some(deadline.map_or(t, |d: u64| d.min(t)));
        for s in self.slots.values().filter(|s| s.complete.is_none()) {
            if !silent {
                consider(s.deadline);
            }
            consider(now.saturating_add((srtt / 4).max(1_000)));
        }
        if let Some(a) = &self.attempt {
            consider(
                a.started
                    .saturating_add(a.lifetime)
                    .min(a.last_sent.unwrap_or(0).saturating_add(srtt.max(10_000))),
            );
        }
        if self.needs_refresh.is_some() && self.attempt.is_none() {
            consider(now);
        }
        deadline
    }
}
fn next_id(id: u32) -> u32 {
    if id == u32::MAX { 1 } else { id + 1 }
}
fn previous_id(id: u32) -> u32 {
    if id <= 1 { u32::MAX } else { id - 1 }
}

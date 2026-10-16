#![allow(clippy::collapsible_if)]
//! Host and client session state machines. Times are explicit monotonic microseconds.
use crate::connection::{Connection, Inbound, Role};
use crate::control::{ControlMessage, DisplayInfo};
use crate::crypto::ProtectedHeader;
use crate::handshake::{
    self, ClientHandshake, Direction, HandshakeParams, InitCache, OpenedInit, StreamClass,
    StreamEntry, StreamKind, StreamTable,
};
use crate::input::InputMessage;
use crate::media::{DeliveredFrame, EncodedFrame, VideoReceiver, VideoSender};
use crate::wire::{Chunk, CloseCode};
use rand::{RngCore, rngs::OsRng};
use std::collections::{BTreeMap, HashMap};
use std::net::SocketAddr;
use subtle::ConstantTimeEq;
use zeroize::Zeroize;

#[derive(Clone, Debug)]
pub struct OutboundDatagram {
    pub bytes: Vec<u8>,
    pub destination: SocketAddr,
}
#[derive(Clone, Debug)]
pub enum HostEvent {
    SessionStarted {
        session_id: u32,
        peer: SocketAddr,
    },
    SessionEnded {
        session_id: u32,
        reason: String,
    },
    KeyframeNeeded {
        stream: u8,
    },
    DisplayRequested {
        stream: u8,
        display: u32,
        req_id: u32,
    },
    Input(InputMessage),
    Paused,
    Resumed,
}
#[derive(Clone, Debug)]
pub struct HostConfig {
    pub max_datagram_size: usize,
    pub bitrate: usize,
    pub frame_rate: usize,
    pub fec_percent: usize,
    pub fec_min_parity: usize,
    pub pause_after_silence: u64,
    pub expire_after_silence: u64,
}
impl Default for HostConfig {
    fn default() -> Self {
        Self {
            max_datagram_size: 1200,
            bitrate: 20_000_000,
            frame_rate: 60,
            fec_percent: 10,
            fec_min_parity: 1,
            pause_after_silence: 2_000_000,
            expire_after_silence: 60_000_000,
        }
    }
}
#[derive(Default, Clone, Debug)]
pub struct HostStats {
    pub version_mismatches: u64,
    pub inits_discarded: u64,
    pub inits_answered_from_cache: u64,
    pub handshakes_rejected: u64,
    pub unknown_sessions: u64,
    pub session_unknown_sent: u64,
    pub other_discarded: u64,
}
pub struct HostSession {
    pub connection: Connection,
    pub video_streams: Vec<u8>,
    pub videos: BTreeMap<u8, VideoSender>,
    pub paused: bool,
    pub fec: bool,
    drain_offset: usize,
    response_sent: Option<u64>,
}
pub struct HostEndpoint {
    pub config: HostConfig,
    pub session: Option<HostSession>,
    pub stats: HostStats,
    host_secret: [u8; 32],
    pairings: HashMap<u64, [u8; 32]>,
    cache: InitCache,
    tokens: f64,
    last_token: u64,
    outbox: Vec<OutboundDatagram>,
    events: Vec<HostEvent>,
}
impl Drop for HostEndpoint {
    fn drop(&mut self) {
        self.host_secret.zeroize();
        for key in self.pairings.values_mut() {
            key.zeroize();
        }
    }
}
impl HostEndpoint {
    pub fn new(
        config: HostConfig,
        host_secret: [u8; 32],
        pairings: HashMap<u64, [u8; 32]>,
    ) -> Self {
        Self {
            config,
            session: None,
            stats: Default::default(),
            host_secret,
            pairings,
            cache: Default::default(),
            tokens: 20.,
            last_token: 0,
            outbox: Vec::new(),
            events: Vec::new(),
        }
    }
    pub fn take_outbox(&mut self) -> Vec<OutboundDatagram> {
        std::mem::take(&mut self.outbox)
    }
    pub fn take_events(&mut self) -> Vec<HostEvent> {
        std::mem::take(&mut self.events)
    }
    pub fn receive(&mut self, d: &[u8], address: SocketAddr, now: u64, unix: u64) {
        self.bound_queues(now);
        let Some(&first) = d.first() else { return };
        if first & 0x80 == 0 {
            self.receive_protected(d, address, now);
        } else if first == handshake::INITIATION {
            if d.get(1) != Some(&handshake::VERSION) {
                self.stats.version_mismatches += 1;
                return;
            }
            self.receive_init(d, address, now, unix);
        } else {
            self.stats.other_discarded += 1;
        }
        self.bound_queues(now);
    }
    fn bound_queues(&mut self, now: u64) {
        if self.events.len() > 8192 || self.outbox.len() > 8192 {
            // A stalled adapter must not retain input indefinitely. SessionEnded releases
            // any state already injected by the platform, while pending input is discarded.
            self.events.clear();
            self.outbox.clear();
            self.close(now);
        }
    }
    fn receive_protected(&mut self, d: &[u8], address: SocketAddr, now: u64) {
        if d.len() < 32 {
            self.stats.other_discarded += 1;
            return;
        }
        let Some(header) = ProtectedHeader::parse(d) else {
            self.stats.other_discarded += 1;
            return;
        };
        if !self
            .session
            .as_ref()
            .is_some_and(|s| s.connection.session_id == header.session_id)
        {
            self.stats.unknown_sessions += 1;
            self.tokens = (self.tokens
                + now.saturating_sub(self.last_token) as f64 * 20. / 1_000_000.)
                .min(20.);
            self.last_token = now;
            if self.tokens >= 1. {
                self.tokens -= 1.;
                self.stats.session_unknown_sent += 1;
                self.push(
                    handshake::session_unknown(
                        header.session_id,
                        handshake::reset_token(&self.host_secret, header.session_id),
                    ),
                    address,
                );
            }
            return;
        }
        let s = self.session.as_mut().unwrap();
        let gap = now.saturating_sub(s.connection.last_received);
        let Some(items) = s.connection.receive(d, address, now) else {
            return;
        };
        if let Some(sent) = s.response_sent.take() {
            if !s.connection.rtt.has_sample {
                s.connection.rtt.add(now.saturating_sub(sent));
            }
        } else if gap > VideoReceiver::SILENCE {
            for v in s.videos.values_mut() {
                v.extend_deadlines(gap);
            }
        }
        if s.paused {
            s.paused = false;
            self.events.push(HostEvent::Resumed);
            self.events.extend(
                s.video_streams
                    .iter()
                    .map(|stream| HostEvent::KeyframeNeeded { stream: *stream }),
            );
        }
        for item in items {
            match item {
                Inbound::Message { stream: 0, payload } => {
                    if let Some(ControlMessage::SelectDisplay {
                        req_id,
                        stream,
                        display,
                    }) = ControlMessage::parse(&payload)
                    {
                        if s.videos.contains_key(&stream) {
                            self.events.push(HostEvent::DisplayRequested {
                                stream,
                                display,
                                req_id,
                            });
                        }
                    }
                }
                Inbound::Message { payload, .. } => {
                    if let Some(i) = InputMessage::parse(&payload) {
                        self.events.push(HostEvent::Input(i));
                    }
                }
                Inbound::Nack(n) => {
                    if let Some(v) = s.videos.get_mut(&n.stream) {
                        v.handle_nack(&n, now, s.connection.rtt.smoothed);
                    }
                }
                Inbound::Refresh(r) => {
                    if s.videos
                        .get_mut(&r.stream)
                        .is_some_and(|v| v.handle_refresh(&r, now))
                    {
                        self.events
                            .push(HostEvent::KeyframeNeeded { stream: r.stream });
                    }
                }
                Inbound::Close(_) => {
                    self.end("client closed the session");
                    return;
                }
                _ => {}
            }
        }
    }
    fn receive_init(&mut self, d: &[u8], address: SocketAddr, now: u64, unix: u64) {
        let Ok(opened) = OpenedInit::open(d, &|id| self.pairings.get(&id).copied()) else {
            self.stats.inits_discarded += 1;
            return;
        };
        if let Some(response) = self.cache.lookup(d, now) {
            self.stats.inits_answered_from_cache += 1;
            if let Some(s) = &mut self.session {
                s.response_sent = None;
            }
            self.push(response, address);
            return;
        }
        if opened.validate(unix).is_err() {
            self.stats.handshakes_rejected += 1;
            return;
        }
        let Some(proposed) = opened.params.stream_table.as_ref() else {
            return;
        };
        let entries: Vec<_> = proposed
            .entries
            .iter()
            .filter(|e| {
                matches!(
                    (e.kind, e.direction, e.stream_class),
                    (
                        StreamKind::Video,
                        Direction::HostToClient,
                        StreamClass::Media
                    ) | (
                        StreamKind::Input,
                        Direction::ClientToHost,
                        StreamClass::Reliable
                    )
                )
            })
            .copied()
            .collect();
        if entries.is_empty() {
            self.stats.handshakes_rejected += 1;
            return;
        }
        let table = StreamTable { entries };
        let size = (opened.params.max_datagram_size.unwrap_or(1200) as usize)
            .min(self.config.max_datagram_size.clamp(256, 9000));
        let fec = self.config.fec_percent > 0
            && opened.params.capabilities.unwrap_or(0) & handshake::CAPABILITY_FEC != 0;
        let mut id = OsRng.next_u32();
        while id == 0
            || self
                .session
                .as_ref()
                .is_some_and(|s| s.connection.session_id == id)
        {
            id = OsRng.next_u32();
        }
        let params = HandshakeParams {
            capabilities: if fec {
                Some(handshake::CAPABILITY_FEC)
            } else {
                None
            },
            stream_table: Some(table.clone()),
            max_datagram_size: Some(size as u16),
            ..Default::default()
        };
        let Ok(result) = opened.respond(id, handshake::reset_token(&self.host_secret, id), params)
        else {
            self.stats.inits_discarded += 1;
            return;
        };
        self.cache.insert(d, result.response.clone(), now);
        if let Some(s) = &mut self.session {
            s.connection.queue(Chunk::Close(CloseCode::GoingAway));
            let peer = s.connection.peer;
            let packets = s.connection.flush(now);
            for bytes in packets {
                self.outbox.push(OutboundDatagram {
                    bytes,
                    destination: peer,
                });
            }
            self.end("replaced by a new handshake");
        }
        let connection = Connection::new(
            Role::Host,
            id,
            result.send_key,
            result.receive_key,
            table.clone(),
            size,
            address,
            now,
        );
        let video_streams: Vec<_> = table
            .entries
            .iter()
            .filter(|e| e.kind == StreamKind::Video && e.direction == Direction::HostToClient)
            .map(|e| e.id)
            .collect();
        let videos = video_streams
            .iter()
            .map(|id| {
                let mut video = VideoSender::new(*id, self.config.bitrate, self.config.frame_rate);
                if fec {
                    video.fec_percent = self.config.fec_percent;
                    video.fec_min_parity = self.config.fec_min_parity;
                }
                (*id, video)
            })
            .collect();
        self.session = Some(HostSession {
            connection,
            video_streams: video_streams.clone(),
            videos,
            paused: false,
            fec,
            drain_offset: 0,
            response_sent: Some(now),
        });
        self.push(result.response, address);
        self.events.push(HostEvent::SessionStarted {
            session_id: id,
            peer: address,
        });
        self.events.extend(
            video_streams
                .into_iter()
                .map(|stream| HostEvent::KeyframeNeeded { stream }),
        );
    }
    fn push(&mut self, bytes: Vec<u8>, destination: SocketAddr) {
        if self.outbox.len() < 8192 {
            self.outbox.push(OutboundDatagram { bytes, destination });
        }
    }
    pub fn submit(&mut self, frame: EncodedFrame, stream: u8, now: u64) {
        if let Some(s) = self.session.as_mut().filter(|s| !s.paused) {
            if let Some(v) = s.videos.get_mut(&stream) {
                v.submit(
                    frame,
                    now,
                    s.connection.max_datagram_size,
                    s.connection.latency_budget(),
                );
            }
        }
    }
    pub fn send_control(&mut self, message: ControlMessage) -> bool {
        self.session
            .as_mut()
            .is_some_and(|s| s.connection.send(&message.encoded(), 0))
    }
    /// Confirm a display binding only after the platform pipeline has accepted it.
    pub fn bind_display(&mut self, req_id: u32, stream: u8, display: u32) -> bool {
        self.reset_stream(stream);
        self.send_control(ControlMessage::DisplaySelected {
            req_id,
            stream,
            display,
        })
    }
    pub fn reset_stream(&mut self, stream: u8) {
        if let Some(v) = self
            .session
            .as_mut()
            .and_then(|s| s.videos.get_mut(&stream))
        {
            v.reset();
        }
    }
    pub fn is_streaming(&self) -> bool {
        self.session.as_ref().is_some_and(|s| !s.paused)
    }
    pub fn tick(&mut self, now: u64, _unix: u64) {
        self.bound_queues(now);
        let Some(s) = &mut self.session else { return };
        let silence = now.saturating_sub(s.connection.last_received);
        if silence >= self.config.expire_after_silence {
            self.end("client silence timeout");
            return;
        }
        if silence >= self.config.pause_after_silence && !s.paused {
            s.paused = true;
            for v in s.videos.values_mut() {
                v.reset();
            }
            self.events.push(HostEvent::Paused);
        }
        if s.paused {
            return;
        }
        let peer = s.connection.peer;
        for bytes in s.connection.flush(now) {
            if self.outbox.len() < 8192 {
                self.outbox.push(OutboundDatagram {
                    bytes,
                    destination: peer,
                });
            }
        }
        for i in 0..s.video_streams.len() {
            let id = s.video_streams[(i + s.drain_offset) % s.video_streams.len()];
            let mtu = s.connection.max_datagram_size;
            let packets = s
                .videos
                .get_mut(&id)
                .unwrap()
                .drain(now, mtu, |chunk| s.connection.seal(chunk, now));
            for bytes in packets {
                if self.outbox.len() < 8192 {
                    self.outbox.push(OutboundDatagram {
                        bytes,
                        destination: peer,
                    });
                }
            }
        }
        if !s.video_streams.is_empty() {
            s.drain_offset = (s.drain_offset + 1) % s.video_streams.len();
        }
    }
    pub fn next_deadline(&self, now: u64) -> Option<u64> {
        let s = self.session.as_ref()?;
        let c = &s.connection;
        let mut wake = c
            .last_received
            .saturating_add(self.config.expire_after_silence);
        if s.paused {
            return Some(wake);
        }
        wake = wake
            .min(
                c.last_received
                    .saturating_add(self.config.pause_after_silence),
            )
            .min(c.next_deadline());
        for v in s.videos.values() {
            if let Some(d) = v.next_deadline(now) {
                wake = wake.min(if c.is_validating_address() {
                    d.max(now.saturating_add(5_000))
                } else {
                    d
                });
            }
        }
        Some(wake)
    }
    pub fn close(&mut self, now: u64) {
        if let Some(s) = &mut self.session {
            s.connection.queue(Chunk::Close(CloseCode::GoingAway));
            let destination = s.connection.peer;
            self.outbox.extend(
                s.connection
                    .flush(now)
                    .into_iter()
                    .map(|bytes| OutboundDatagram { bytes, destination }),
            );
            self.end("host closed the session");
        }
    }
    fn end(&mut self, reason: &str) {
        if let Some(s) = self.session.take() {
            self.events.push(HostEvent::SessionEnded {
                session_id: s.connection.session_id,
                reason: reason.into(),
            });
        }
    }
}

#[derive(Clone, Debug)]
pub enum ClientEvent {
    Connecting,
    Connected {
        session_id: u32,
        max_datagram_size: usize,
        video_streams: Vec<u8>,
    },
    Frame {
        stream: u8,
        frame: DeliveredFrame,
    },
    Displays(Vec<DisplayInfo>),
    StreamDisplay {
        stream: u8,
        display: u32,
    },
    Disconnected {
        reason: String,
    },
}
#[derive(Clone)]
pub struct ClientConfig {
    pub pairing_id: u64,
    pub psk: [u8; 32],
    pub host: SocketAddr,
    pub max_datagram_size: usize,
    pub offer_fec: bool,
    pub video_stream_count: usize,
    pub silence_timeout: u64,
    pub retry_delay: u64,
}
impl Drop for ClientConfig {
    fn drop(&mut self) {
        self.psk.zeroize();
    }
}
impl ClientConfig {
    pub fn new(pairing_id: u64, psk: [u8; 32], host: SocketAddr) -> Self {
        Self {
            pairing_id,
            psk,
            host,
            max_datagram_size: 1200,
            offer_fec: true,
            video_stream_count: 4,
            silence_timeout: 5_000_000,
            retry_delay: 1_000_000,
        }
    }
    pub fn streams(&self) -> StreamTable {
        let mut entries = vec![
            StreamEntry {
                id: 1,
                kind: StreamKind::Video,
                direction: Direction::HostToClient,
                stream_class: StreamClass::Media,
            },
            StreamEntry {
                id: 4,
                kind: StreamKind::Input,
                direction: Direction::ClientToHost,
                stream_class: StreamClass::Reliable,
            },
            StreamEntry {
                id: 5,
                kind: StreamKind::Input,
                direction: Direction::ClientToHost,
                stream_class: StreamClass::Reliable,
            },
        ];
        for i in 0..self.video_stream_count.clamp(1, 30) - 1 {
            entries.push(StreamEntry {
                id: (16 + i) as u8,
                kind: StreamKind::Video,
                direction: Direction::HostToClient,
                stream_class: StreamClass::Media,
            });
        }
        StreamTable { entries }
    }
}
pub struct ClientSession {
    pub connection: Connection,
    pub video_streams: Vec<u8>,
    pub videos: BTreeMap<u8, VideoReceiver>,
    pub fec: bool,
    reset_token: [u8; 16],
    next_request: u32,
    keyboard: Option<u8>,
    pointer: Option<u8>,
    pending_motion: Option<InputMessage>,
    last_motion: u64,
}
struct Handshaking {
    handshake: ClientHandshake,
    first_sent: u64,
    sends: u32,
    next_send: u64,
    early: Vec<Vec<u8>>,
}
enum State {
    Idle,
    Handshaking(Box<Handshaking>),
    Connected,
    Waiting(u64),
}
pub struct ClientEndpoint {
    pub config: ClientConfig,
    pub session: Option<ClientSession>,
    state: State,
    outbox: Vec<OutboundDatagram>,
    events: Vec<ClientEvent>,
}
impl ClientEndpoint {
    pub fn new(config: ClientConfig) -> Self {
        Self {
            config,
            session: None,
            state: State::Idle,
            outbox: Vec::new(),
            events: Vec::new(),
        }
    }
    pub fn take_outbox(&mut self) -> Vec<OutboundDatagram> {
        std::mem::take(&mut self.outbox)
    }
    pub fn take_events(&mut self) -> Vec<ClientEvent> {
        std::mem::take(&mut self.events)
    }
    pub fn is_connected(&self) -> bool {
        matches!(self.state, State::Connected)
    }
    pub fn start(&mut self, now: u64, unix: u64) {
        if self.events.len() > 8192 || self.outbox.len() > 8192 {
            self.events.clear();
            self.outbox.clear();
        }
        let params = HandshakeParams {
            timestamp: Some(unix),
            capabilities: self.config.offer_fec.then_some(handshake::CAPABILITY_FEC),
            stream_table: Some(self.config.streams()),
            max_datagram_size: Some(self.config.max_datagram_size.clamp(256, 9000) as u16),
            ..Default::default()
        };
        let Ok(handshake) = ClientHandshake::new(self.config.psk, self.config.pairing_id, params)
        else {
            self.restart("invalid handshake configuration", now, false, unix);
            return;
        };
        self.outbox.push(OutboundDatagram {
            bytes: handshake.datagram.clone(),
            destination: self.config.host,
        });
        self.state = State::Handshaking(Box::new(Handshaking {
            handshake,
            first_sent: now,
            sends: 1,
            next_send: now.saturating_add(100_000),
            early: Vec::new(),
        }));
        self.session = None;
        self.events.push(ClientEvent::Connecting);
    }
    fn restart(&mut self, reason: &str, now: u64, immediate: bool, unix: u64) {
        self.session = None;
        self.events.push(ClientEvent::Disconnected {
            reason: reason.into(),
        });
        if immediate {
            self.start(now, unix);
        } else {
            self.state = State::Waiting(now.saturating_add(self.config.retry_delay));
        }
    }
    pub fn receive(&mut self, d: &[u8], address: SocketAddr, now: u64, unix: u64) {
        self.bound_queues(now, unix);
        let Some(&first) = d.first() else { return };
        match first {
            handshake::RESPONSE => self.receive_response(d, address, now, unix),
            handshake::SESSION_UNKNOWN => {
                if d.len() != 22 || d.get(1) != Some(&handshake::VERSION) {
                    return;
                }
                if let Some(s) = &self.session {
                    if d[2..6] == s.connection.session_id.to_be_bytes()
                        && bool::from(d[6..].ct_eq(&s.reset_token))
                    {
                        self.restart("the host no longer holds the session", now, true, unix);
                    }
                }
            }
            0..=0x7f => {
                if let State::Handshaking(h) = &mut self.state {
                    if address == self.config.host
                        && h.early.len() < 64
                        && d.len() <= self.config.max_datagram_size
                    {
                        h.early.push(d.to_vec());
                    }
                    return;
                }
                self.receive_protected(d, address, now, unix);
            }
            _ => {}
        }
        self.bound_queues(now, unix);
    }
    fn bound_queues(&mut self, now: u64, unix: u64) {
        if self.events.len() > 8192 || self.outbox.len() > 8192 {
            self.events.clear();
            self.outbox.clear();
            self.close(now);
            self.restart("application event queue full", now, false, unix);
        }
    }
    fn receive_response(&mut self, d: &[u8], address: SocketAddr, now: u64, unix: u64) {
        if address != self.config.host {
            return;
        }
        let State::Handshaking(h) = &self.state else {
            return;
        };
        let result = match h.handshake.open(d) {
            Ok(Some(result)) => result,
            Ok(None) => return,
            Err(e) => {
                self.restart(&format!("handshake rejected: {e}"), now, false, unix);
                return;
            }
        };
        let mut connection = Connection::new(
            Role::Client,
            result.session_id,
            result.send_key,
            result.receive_key,
            result.params.stream_table.unwrap(),
            result.params.max_datagram_size.unwrap() as usize,
            self.config.host,
            now,
        );
        if h.sends == 1 {
            connection.rtt.add(now.saturating_sub(h.first_sent));
        }
        connection.request_ping();
        let streams: Vec<_> = connection
            .streams
            .entries
            .iter()
            .filter(|e| e.kind == StreamKind::Video && e.direction == Direction::HostToClient)
            .map(|e| e.id)
            .collect();
        let inputs: Vec<_> = connection
            .streams
            .entries
            .iter()
            .filter(|e| e.kind == StreamKind::Input && e.direction == Direction::ClientToHost)
            .map(|e| e.id)
            .collect();
        let early = h.early.clone();
        let videos = streams
            .iter()
            .map(|id| {
                (
                    *id,
                    VideoReceiver::new(*id, Some(connection.memory_budget.clone())),
                )
            })
            .collect();
        let session = ClientSession {
            connection,
            video_streams: streams.clone(),
            videos,
            fec: result.params.capabilities.unwrap_or(0) & handshake::CAPABILITY_FEC != 0,
            reset_token: result.reset_token,
            next_request: 1,
            keyboard: inputs.first().copied(),
            pointer: inputs.get(1).or(inputs.first()).copied(),
            pending_motion: None,
            last_motion: 0,
        };
        self.events.push(ClientEvent::Connected {
            session_id: result.session_id,
            max_datagram_size: session.connection.max_datagram_size,
            video_streams: streams,
        });
        self.session = Some(session);
        self.state = State::Connected;
        for packet in early {
            self.receive_protected(&packet, address, now, unix);
        }
    }
    fn receive_protected(&mut self, d: &[u8], address: SocketAddr, now: u64, unix: u64) {
        let Some(s) = &mut self.session else { return };
        let gap = now.saturating_sub(s.connection.last_received);
        let Some(items) = s.connection.receive(d, address, now) else {
            return;
        };
        if gap > VideoReceiver::SILENCE {
            for v in s.videos.values_mut() {
                v.link_resumed(gap);
            }
        }
        for item in items {
            match item {
                Inbound::Fragment(f) => {
                    if let Some(v) = s.videos.get_mut(&f.stream) {
                        v.receive(f, now, s.connection.latency_budget());
                    }
                }
                Inbound::Message { stream: 0, payload } => match ControlMessage::parse(&payload) {
                    Some(ControlMessage::Displays(list)) => {
                        self.events.push(ClientEvent::Displays(list))
                    }
                    Some(ControlMessage::DisplaySelected {
                        stream, display, ..
                    })
                    | Some(ControlMessage::StreamDisplay { stream, display }) => self
                        .events
                        .push(ClientEvent::StreamDisplay { stream, display }),
                    _ => {}
                },
                Inbound::Close(code) => {
                    self.restart(
                        &format!("the host closed the session ({code:?})"),
                        now,
                        false,
                        unix,
                    );
                    return;
                }
                _ => {}
            }
        }
        self.collect_frames();
    }
    fn collect_frames(&mut self) {
        if let Some(s) = &mut self.session {
            for (&stream, v) in &mut s.videos {
                self.events.extend(
                    v.take_frames()
                        .into_iter()
                        .map(|frame| ClientEvent::Frame { stream, frame }),
                );
            }
        }
    }
    pub fn send_input(&mut self, message: InputMessage, now: u64) -> bool {
        if !self.is_connected() {
            return false;
        }
        let Ok(encoded) = message.encoded() else {
            return false;
        };
        let s = self.session.as_mut().unwrap();
        let accepted = match message {
            InputMessage::Key { .. } | InputMessage::Text(_) => {
                s.keyboard.is_some_and(|id| s.connection.send(&encoded, id))
            }
            InputMessage::Pointer { .. } => {
                if s.pointer.is_none() {
                    return false;
                }
                s.pending_motion = Some(message);
                Self::flush_motion(s, now, false)
            }
            InputMessage::Button { .. } | InputMessage::Scroll { .. } => {
                Self::flush_motion(s, now, true)
                    && s.pointer.is_some_and(|id| s.connection.send(&encoded, id))
            }
        };
        if !accepted {
            self.outbox.clear();
            let destination = s.connection.peer;
            if let Some(bytes) = s
                .connection
                .seal(&Chunk::Close(CloseCode::AppRequest).encoded(), now)
            {
                self.outbox.push(OutboundDatagram { bytes, destination });
            }
            self.restart(
                "reliable input queue full; resetting the session",
                now,
                false,
                0,
            );
        }
        accepted
    }
    fn flush_motion(s: &mut ClientSession, now: u64, force: bool) -> bool {
        let Some(m) = &s.pending_motion else {
            return true;
        };
        let Some(stream) = s.pointer else {
            return false;
        };
        if !force && now < s.last_motion.saturating_add(1_000) {
            return true;
        }
        s.last_motion = now;
        let Ok(encoded) = m.encoded() else {
            return false;
        };
        if !s.connection.send(&encoded, stream) {
            return false;
        }
        s.pending_motion = None;
        true
    }
    pub fn decoded(&mut self, stream: u8, id: u32, keyframe: bool) {
        if let Some(v) = self
            .session
            .as_mut()
            .and_then(|s| s.videos.get_mut(&stream))
        {
            v.decoded(id, keyframe);
        }
    }
    pub fn decoder_failed(&mut self, stream: u8, id: u32) {
        if let Some(v) = self
            .session
            .as_mut()
            .and_then(|s| s.videos.get_mut(&stream))
        {
            v.decoder_failed(id);
        }
    }
    pub fn select_display(&mut self, display: u32, stream: u8) -> bool {
        let Some(s) = &mut self.session else {
            return false;
        };
        if !s.videos.contains_key(&stream) {
            return false;
        }
        let message = ControlMessage::SelectDisplay {
            req_id: s.next_request,
            stream,
            display,
        };
        s.next_request = s.next_request.wrapping_add(1);
        s.connection.send(&message.encoded(), 0)
    }
    pub fn tick(&mut self, now: u64, unix: u64) {
        self.bound_queues(now, unix);
        match &mut self.state {
            State::Idle => {}
            State::Waiting(until) => {
                if now >= *until {
                    self.start(now, unix);
                }
            }
            State::Handshaking(h) => {
                if now >= h.next_send {
                    if h.sends >= 8 {
                        self.restart("no response from the host", now, false, unix);
                    } else {
                        self.outbox.push(OutboundDatagram {
                            bytes: h.handshake.datagram.clone(),
                            destination: self.config.host,
                        });
                        h.sends += 1;
                        h.next_send = now.saturating_add(if h.sends == 8 {
                            2_000_000
                        } else {
                            (100_000u64 << (h.sends - 1)).min(2_000_000)
                        });
                    }
                }
            }
            State::Connected => {
                let s = self.session.as_mut().unwrap();
                if now
                    > s.connection
                        .last_received
                        .saturating_add(self.config.silence_timeout)
                {
                    self.restart("nothing from the host", now, true, unix);
                    return;
                }
                Self::flush_motion(s, now, false);
                for v in s.videos.values_mut() {
                    for chunk in v.poll(
                        now,
                        s.connection.rtt.smoothed,
                        s.connection.latency_budget(),
                        s.connection.last_received,
                    ) {
                        s.connection.queue(chunk);
                    }
                }
                let destination = s.connection.peer;
                self.outbox.extend(
                    s.connection
                        .flush(now)
                        .into_iter()
                        .map(|bytes| OutboundDatagram { bytes, destination }),
                );
                self.collect_frames();
            }
        }
        self.bound_queues(now, unix);
    }
    pub fn next_deadline(&self, now: u64) -> Option<u64> {
        match &self.state {
            State::Idle => None,
            State::Waiting(t) => Some(*t),
            State::Handshaking(h) => Some(h.next_send),
            State::Connected => {
                let s = self.session.as_ref()?;
                let c = &s.connection;
                let mut wake = c
                    .last_received
                    .saturating_add(self.config.silence_timeout)
                    .min(c.next_deadline());
                if s.pending_motion.is_some() {
                    wake = wake.min(s.last_motion.saturating_add(1_000));
                }
                for v in s.videos.values() {
                    if let Some(d) = v.next_deadline(now, c.rtt.smoothed, c.last_received) {
                        wake = wake.min(d);
                    }
                }
                Some(wake)
            }
        }
    }
    pub fn close(&mut self, now: u64) {
        if let Some(s) = &mut self.session {
            s.connection.queue(Chunk::Close(CloseCode::AppRequest));
            let destination = s.connection.peer;
            self.outbox.extend(
                s.connection
                    .flush(now)
                    .into_iter()
                    .map(|bytes| OutboundDatagram { bytes, destination }),
            );
        }
        self.session = None;
        self.state = State::Idle;
    }
}

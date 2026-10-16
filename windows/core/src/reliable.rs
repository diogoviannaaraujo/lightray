use crate::{
    crypto::serial_newer,
    memory::{MemoryBudget, MemoryReservation},
    wire::ReliableSegment,
};
use std::collections::HashMap;
fn reserve(
    local: &MemoryBudget,
    shared: Option<&MemoryBudget>,
    bytes: usize,
    headroom: usize,
) -> Option<Vec<MemoryReservation>> {
    if local
        .used_bytes()
        .checked_add(bytes)?
        .checked_add(headroom)?
        > local.limit()
    {
        return None;
    }
    let mut out = vec![local.reserve(bytes)?];
    if let Some(shared) = shared {
        out.push(shared.reserve(bytes)?);
    }
    Some(out)
}
#[derive(Debug)]
struct Message {
    seq: u32,
    segments: Vec<Vec<u8>>,
    _reservation: Vec<MemoryReservation>,
    sent_at: Option<u64>,
    attempts: u32,
}
#[derive(Debug)]
pub struct ReliableSender {
    pub stream: u8,
    next_seq: u32,
    messages: Vec<Message>,
    budget: MemoryBudget,
    shared: Option<MemoryBudget>,
}
impl ReliableSender {
    pub fn new(stream: u8) -> Self {
        Self::with_budget(stream, MemoryBudget::new(4 << 20), None)
    }
    pub fn with_budget(stream: u8, budget: MemoryBudget, shared: Option<MemoryBudget>) -> Self {
        Self {
            stream,
            next_seq: 0,
            messages: Vec::new(),
            budget,
            shared,
        }
    }
    pub fn next_seq(&self) -> u32 {
        self.next_seq
    }
    pub fn is_idle(&self) -> bool {
        self.messages.is_empty()
    }
    pub fn unacknowledged(&self) -> usize {
        self.messages.len()
    }
    pub fn enqueue(&mut self, payload: &[u8], max_segment_payload: usize) -> bool {
        if max_segment_payload == 0
            || payload.len() > ReliableReceiver::MAX_MESSAGE_BYTES
            || self.messages.len() >= 1024
        {
            return false;
        }
        let count = payload.len().max(1).div_ceil(max_segment_payload);
        if count > ReliableReceiver::MAX_SEGMENTS {
            return false;
        }
        let Some(reservation) = reserve(
            &self.budget,
            self.shared.as_ref(),
            payload.len() * 2 + count * 64 + 256,
            0,
        ) else {
            return false;
        };
        let segments = if payload.is_empty() {
            vec![Vec::new()]
        } else {
            payload
                .chunks(max_segment_payload)
                .map(<[u8]>::to_vec)
                .collect()
        };
        self.messages.push(Message {
            seq: self.next_seq,
            segments,
            _reservation: reservation,
            sent_at: None,
            attempts: 0,
        });
        self.next_seq = self.next_seq.wrapping_add(1);
        true
    }
    pub fn acknowledge(&mut self, seq: u32) {
        if let Some(index) = self.messages.iter().position(|m| m.seq == seq) {
            self.messages.remove(index);
        }
    }
    pub fn due(&mut self, now: u64, timeout: u64) -> Vec<ReliableSegment> {
        let mut out = Vec::new();
        for m in &mut self.messages {
            if let Some(at) = m.sent_at
                && now
                    < at.saturating_add(
                        timeout.saturating_mul(1u64 << m.attempts.saturating_sub(1).min(6)),
                    )
            {
                continue;
            }
            for (index, payload) in m.segments.iter().enumerate() {
                out.push(ReliableSegment {
                    stream: self.stream,
                    msg_seq: m.seq,
                    seg_index: index as u16,
                    seg_count: m.segments.len() as u16,
                    payload: payload.clone(),
                });
            }
            m.sent_at = Some(now);
            m.attempts = m.attempts.saturating_add(1);
        }
        out
    }
    pub fn next_deadline(&self, timeout: u64) -> Option<u64> {
        self.messages
            .iter()
            .map(|m| {
                m.sent_at.map_or(0, |at| {
                    at.saturating_add(
                        timeout.saturating_mul(1u64 << m.attempts.saturating_sub(1).min(6)),
                    )
                })
            })
            .min()
    }
}
#[derive(Debug)]
struct Partial {
    seg_count: u16,
    segments: Vec<Option<Vec<u8>>>,
    received: usize,
    bytes: usize,
    reservations: Vec<MemoryReservation>,
}
#[derive(Debug)]
struct Completed {
    bytes: Vec<u8>,
    _reservations: Vec<MemoryReservation>,
}
#[derive(Debug, PartialEq, Eq)]
pub enum ReliableOutcome {
    Accepted { ack: bool, deliver: Vec<Vec<u8>> },
    Discarded,
}
#[derive(Debug)]
pub struct ReliableReceiver {
    pub stream: u8,
    expected: u32,
    partial: HashMap<u32, Partial>,
    complete: HashMap<u32, Completed>,
    budget: MemoryBudget,
    shared: Option<MemoryBudget>,
}
impl ReliableReceiver {
    pub const MAX_MESSAGE_BYTES: usize = 1 << 20;
    pub const MAX_SEGMENTS: usize = 8192;
    pub fn new(stream: u8) -> Self {
        Self::with_budget(stream, MemoryBudget::new(4 << 20), None)
    }
    pub fn with_budget(stream: u8, budget: MemoryBudget, shared: Option<MemoryBudget>) -> Self {
        Self {
            stream,
            expected: 0,
            partial: HashMap::new(),
            complete: HashMap::new(),
            budget,
            shared,
        }
    }
    pub fn expected(&self) -> u32 {
        self.expected
    }
    pub fn receive(&mut self, s: &ReliableSegment) -> ReliableOutcome {
        if s.stream != self.stream
            || s.seg_count == 0
            || s.seg_count as usize > Self::MAX_SEGMENTS
            || s.seg_index >= s.seg_count
            || s.payload.len() > Self::MAX_MESSAGE_BYTES
        {
            return ReliableOutcome::Discarded;
        }
        if serial_newer(self.expected, s.msg_seq) {
            return ReliableOutcome::Accepted {
                ack: true,
                deliver: Vec::new(),
            };
        }
        if s.msg_seq.wrapping_sub(self.expected) >= 1024 {
            return ReliableOutcome::Discarded;
        }
        if self.complete.contains_key(&s.msg_seq) {
            return ReliableOutcome::Accepted {
                ack: true,
                deliver: Vec::new(),
            };
        }
        let headroom = if s.msg_seq == self.expected {
            0
        } else {
            (Self::MAX_MESSAGE_BYTES * 2 + Self::MAX_SEGMENTS * 64 + 256).min(self.budget.limit())
        };
        if !self.partial.contains_key(&s.msg_seq) {
            let Some(reservations) = reserve(
                &self.budget,
                self.shared.as_ref(),
                s.seg_count as usize * 64 + 256,
                headroom,
            ) else {
                return ReliableOutcome::Discarded;
            };
            self.partial.insert(
                s.msg_seq,
                Partial {
                    seg_count: s.seg_count,
                    segments: vec![None; s.seg_count as usize],
                    received: 0,
                    bytes: 0,
                    reservations,
                },
            );
        }
        let p = self.partial.get_mut(&s.msg_seq).unwrap();
        if p.seg_count != s.seg_count {
            return ReliableOutcome::Discarded;
        }
        if p.segments[s.seg_index as usize].is_some() {
            return ReliableOutcome::Accepted {
                ack: false,
                deliver: Vec::new(),
            };
        }
        if p.bytes + s.payload.len() > Self::MAX_MESSAGE_BYTES {
            return ReliableOutcome::Discarded;
        }
        let Some(reservations) = reserve(
            &self.budget,
            self.shared.as_ref(),
            s.payload.len() * 2,
            headroom,
        ) else {
            return ReliableOutcome::Discarded;
        };
        p.reservations.extend(reservations);
        p.segments[s.seg_index as usize] = Some(s.payload.clone());
        p.received += 1;
        p.bytes += s.payload.len();
        if p.received != p.seg_count as usize {
            return ReliableOutcome::Accepted {
                ack: false,
                deliver: Vec::new(),
            };
        }
        let p = self.partial.remove(&s.msg_seq).unwrap();
        self.complete.insert(
            s.msg_seq,
            Completed {
                bytes: p.segments.into_iter().flat_map(|s| s.unwrap()).collect(),
                _reservations: p.reservations,
            },
        );
        let mut deliver = Vec::new();
        while let Some(message) = self.complete.remove(&self.expected) {
            deliver.push(message.bytes);
            self.expected = self.expected.wrapping_add(1);
        }
        ReliableOutcome::Accepted { ack: true, deliver }
    }
}

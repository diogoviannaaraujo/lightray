use crate::{
    bytes::{ByteReader, ByteWriter},
    crypto::wrapping_difference,
    fec::FecLayout,
};
use serde::{Deserialize, Serialize};

#[repr(u16)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CloseCode {
    Normal = 0,
    AppRequest = 1,
    Timeout = 2,
    ProtocolViolation = 3,
    VersionMismatch = 4,
    GoingAway = 5,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FecParameters {
    pub max_block_length: u8,
    pub parity_per_block: u8,
    pub last_length: u16,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaFragment {
    pub stream: u8,
    pub flags: u8,
    pub frame_id: u32,
    pub index: u16,
    pub count: u16,
    pub stride: u16,
    pub fec: Option<FecParameters>,
    pub payload: Vec<u8>,
}
impl MediaFragment {
    pub const KEYFRAME: u8 = 1;
    pub const RETRANSMISSION: u8 = 2;
    pub const PARITY: u8 = 8;
    pub fn is_parity(&self) -> bool {
        self.flags & Self::PARITY != 0
    }
    pub fn datagram_overhead(fec: bool) -> usize {
        if fec { 55 } else { 51 }
    }
    pub fn stride_for_datagram_size(size: usize, fec: bool) -> usize {
        size.saturating_sub(Self::datagram_overhead(fec))
    }
    fn body(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        w.u8(self.stream);
        w.u8(self.flags);
        w.u32(self.frame_id);
        w.u16(self.index);
        w.u16(self.count);
        w.u16(self.stride);
        if let Some(fec) = &self.fec {
            w.u8(7);
            w.append(&[1, 5, 1, fec.max_block_length, fec.parity_per_block]);
            w.u16(fec.last_length);
        } else {
            w.u8(3);
            w.append(&[1, 1, 0]);
        }
        w.append(&self.payload);
        w.bytes
    }
    fn parse(body: &[u8]) -> Option<Self> {
        let mut r = ByteReader::new(body);
        let stream = r.u8().ok()?;
        let flags = r.u8().ok()?;
        let frame_id = r.u32().ok()?;
        let index = r.u16().ok()?;
        let count = r.u16().ok()?;
        let stride = r.u16().ok()?;
        let ext_len = r.u8().ok()? as usize;
        let mut e = ByteReader::new(r.take(ext_len).ok()?);
        let mut fec = None;
        while e.remaining() != 0 {
            let t = e.u8().ok()?;
            let n = e.u8().ok()? as usize;
            let v = e.take(n).ok()?;
            if t != 1 {
                continue;
            }
            match (v.first(), n) {
                (Some(0), _) => fec = None,
                (Some(1), 5) => {
                    fec = Some(FecParameters {
                        max_block_length: v[1],
                        parity_per_block: v[2],
                        last_length: u16::from_be_bytes([v[3], v[4]]),
                    })
                }
                _ => return None,
            }
        }
        let payload = r.rest().to_vec();
        if count == 0 || stride == 0 || payload.is_empty() || payload.len() > stride as usize {
            return None;
        }
        if let Some(f) = &fec
            && (f.last_length == 0 || f.last_length > stride)
        {
            return None;
        }
        if flags & Self::PARITY != 0 {
            let f = fec.as_ref()?;
            let layout = FecLayout::new(
                count as usize,
                f.max_block_length as usize,
                f.parity_per_block as usize,
            )?;
            if index as usize >= layout.parity_count() || payload.len() != stride as usize {
                return None;
            }
        } else {
            if index >= count || (index != count - 1 && payload.len() != stride as usize) {
                return None;
            }
            if let Some(f) = &fec {
                FecLayout::new(
                    count as usize,
                    f.max_block_length as usize,
                    f.parity_per_block as usize,
                )?;
                if index == count - 1 && payload.len() != f.last_length as usize {
                    return None;
                }
            }
        }
        Some(Self {
            stream,
            flags,
            frame_id,
            index,
            count,
            stride,
            fec,
            payload,
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReliableSegment {
    pub stream: u8,
    pub msg_seq: u32,
    pub seg_index: u16,
    pub seg_count: u16,
    pub payload: Vec<u8>,
}
impl ReliableSegment {
    pub const HEADER_LENGTH: usize = 9;
    fn body(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        w.u8(self.stream);
        w.u32(self.msg_seq);
        w.u16(self.seg_index);
        w.u16(self.seg_count);
        w.append(&self.payload);
        w.bytes
    }
    fn parse(body: &[u8]) -> Option<Self> {
        let mut r = ByteReader::new(body);
        let stream = r.u8().ok()?;
        let msg_seq = r.u32().ok()?;
        let seg_index = r.u16().ok()?;
        let seg_count = r.u16().ok()?;
        if seg_count == 0 || seg_index >= seg_count {
            return None;
        }
        Some(Self {
            stream,
            msg_seq,
            seg_index,
            seg_count,
            payload: r.rest().to_vec(),
        })
    }
}
#[derive(Clone, Debug, Copy, PartialEq, Eq, Hash)]
pub struct ReliableAck {
    pub stream: u8,
    pub msg_seq: u32,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Feedback {
    pub base_seq: u32,
    pub received: Vec<bool>,
    pub base_arrival: u32,
    pub deltas: Vec<i16>,
    pub acks: Vec<ReliableAck>,
}
impl Feedback {
    pub fn from_arrivals(
        base_seq: u32,
        count: usize,
        arrivals: &[(usize, u32)],
        acks: Vec<ReliableAck>,
    ) -> Self {
        let mut received = vec![false; count];
        let mut deltas = Vec::new();
        let base = arrivals.first().map_or(0, |a| a.1);
        let mut previous = base;
        for (i, (offset, time)) in arrivals.iter().enumerate() {
            received[*offset] = true;
            let delta = if i == 0 {
                0
            } else {
                ((wrapping_difference(*time, previous) + 2) >> 2)
                    .clamp(i16::MIN as i64, i16::MAX as i64) as i16
            };
            deltas.push(delta);
            previous = previous.wrapping_add((delta as i32 * 4) as u32);
        }
        Self {
            base_seq,
            received,
            base_arrival: base,
            deltas,
            acks,
        }
    }
    pub fn arrivals(&self) -> Vec<(u32, u32)> {
        let mut result = Vec::new();
        let mut time = self.base_arrival;
        let mut k = 0;
        for (i, bit) in self.received.iter().enumerate() {
            if *bit {
                if k > 0 {
                    time = time.wrapping_add((self.deltas[k] as i32 * 4) as u32);
                }
                result.push((self.base_seq.wrapping_add(i as u32), time));
                k += 1;
            }
        }
        result
    }
    fn body(&self) -> Vec<u8> {
        assert!(
            self.acks.len() <= 256
                && self.received.len() <= 65535
                && self.received.iter().filter(|b| **b).count() == self.deltas.len()
        );
        let mut w = ByteWriter::new();
        w.u32(self.base_seq);
        w.u16(self.received.len() as u16);
        w.u32(self.base_arrival);
        for bits in self.received.chunks(8) {
            let byte = bits
                .iter()
                .enumerate()
                .fold(0, |byte, (i, bit)| byte | if *bit { 0x80 >> i } else { 0 });
            w.u8(byte);
        }
        for d in &self.deltas {
            w.i16(*d);
        }
        w.u16(self.acks.len() as u16);
        for a in &self.acks {
            w.u8(a.stream);
            w.u32(a.msg_seq);
        }
        w.bytes
    }
    fn parse(body: &[u8]) -> Option<Self> {
        let mut r = ByteReader::new(body);
        let base_seq = r.u32().ok()?;
        let count = r.u16().ok()? as usize;
        let base_arrival = r.u32().ok()?;
        let bitmap = r.take(count.div_ceil(8)).ok()?;
        let received: Vec<_> = (0..count)
            .map(|i| bitmap[i / 8] & (0x80 >> (i % 8)) != 0)
            .collect();
        let mut deltas = Vec::new();
        for _ in 0..received.iter().filter(|b| **b).count() {
            deltas.push(r.i16().ok()?);
        }
        let count = r.u16().ok()?;
        if count > 256 {
            return None;
        }
        let mut acks = Vec::new();
        for _ in 0..count {
            acks.push(ReliableAck {
                stream: r.u8().ok()?,
                msg_seq: r.u32().ok()?,
            });
        }
        if r.remaining() != 0 {
            return None;
        }
        Some(Self {
            base_seq,
            received,
            base_arrival,
            deltas,
            acks,
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NackEntry {
    pub frame_id: u32,
    pub first: u16,
    pub count: u16,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Nack {
    pub stream: u8,
    pub entries: Vec<NackEntry>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FrameAckEntry {
    pub stream: u8,
    pub frame_id: u32,
}
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RefreshReason {
    Loss = 0,
    DecoderReset = 1,
    Resume = 2,
}
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RefreshPreferred {
    Ltr = 0,
    Idr = 1,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RefreshRequest {
    pub stream: u8,
    pub reason: RefreshReason,
    pub preferred: RefreshPreferred,
    pub last_good_frame: u32,
    pub lost_frame: u32,
    pub req_id: u32,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Chunk {
    Padding,
    MediaFragment(MediaFragment),
    Reliable(ReliableSegment),
    Datagram { stream: u8, payload: Vec<u8> },
    Feedback(Feedback),
    Nack(Nack),
    FrameAck(Vec<FrameAckEntry>),
    RefreshRequest(RefreshRequest),
    Ping { id: u32 },
    Pong { id: u32, hold_micros: u32 },
    Close(CloseCode),
    Unknown { kind: u8 },
}
#[derive(Clone, Default, Debug)]
pub struct ParsedChunks {
    pub chunks: Vec<Chunk>,
    pub malformed: usize,
}
impl Chunk {
    pub fn encoded(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        match self {
            Self::Padding => w.tlv(0, &[]),
            Self::MediaFragment(f) => w.tlv(1, &f.body()),
            Self::Reliable(s) => w.tlv(2, &s.body()),
            Self::Datagram { stream, payload } => {
                let mut b = vec![*stream];
                b.extend(payload);
                w.tlv(3, &b);
            }
            Self::Feedback(f) => w.tlv(0x10, &f.body()),
            Self::Nack(n) => {
                let mut b = ByteWriter::new();
                b.u8(n.stream);
                for e in &n.entries {
                    b.u32(e.frame_id);
                    b.u16(e.first);
                    b.u16(e.count);
                }
                w.tlv(0x11, &b.bytes);
            }
            Self::FrameAck(entries) => {
                let mut b = ByteWriter::new();
                for e in entries {
                    b.u8(e.stream);
                    b.u32(e.frame_id);
                }
                w.tlv(0x12, &b.bytes);
            }
            Self::RefreshRequest(q) => {
                let mut b = ByteWriter::new();
                b.u8(q.stream);
                b.u8(q.reason as u8);
                b.u8(q.preferred as u8);
                b.u32(q.last_good_frame);
                b.u32(q.lost_frame);
                b.u32(q.req_id);
                w.tlv(0x13, &b.bytes);
            }
            Self::Ping { id } => w.tlv(0x30, &id.to_be_bytes()),
            Self::Pong { id, hold_micros } => w.tlv(
                0x31,
                &[id.to_be_bytes(), hold_micros.to_be_bytes()].concat(),
            ),
            Self::Close(code) => w.tlv(0x34, &(*code as u16).to_be_bytes()),
            Self::Unknown { .. } => {}
        }
        w.bytes
    }
    pub fn parse(body: &[u8]) -> ParsedChunks {
        let mut result = ParsedChunks::default();
        let mut r = ByteReader::new(body);
        while r.remaining() >= 3 {
            let kind = r.u8().unwrap();
            let len = r.u16().unwrap() as usize;
            let Ok(value) = r.take(len) else {
                break;
            };
            if let Some(chunk) = Self::parse_body(kind, value) {
                result.chunks.push(chunk);
            } else {
                result.malformed += 1;
            }
        }
        result
    }
    fn parse_body(kind: u8, value: &[u8]) -> Option<Self> {
        let mut r = ByteReader::new(value);
        Some(match kind {
            0 => Self::Padding,
            1 => Self::MediaFragment(MediaFragment::parse(value)?),
            2 => Self::Reliable(ReliableSegment::parse(value)?),
            3 => Self::Datagram {
                stream: r.u8().ok()?,
                payload: r.rest().to_vec(),
            },
            0x10 => Self::Feedback(Feedback::parse(value)?),
            0x11 => {
                let stream = r.u8().ok()?;
                if !r.remaining().is_multiple_of(8) {
                    return None;
                }
                let mut entries = Vec::new();
                while r.remaining() != 0 {
                    entries.push(NackEntry {
                        frame_id: r.u32().ok()?,
                        first: r.u16().ok()?,
                        count: r.u16().ok()?,
                    });
                }
                Self::Nack(Nack { stream, entries })
            }
            0x12 => {
                if !value.len().is_multiple_of(5) {
                    return None;
                }
                let mut entries = Vec::new();
                while r.remaining() != 0 {
                    entries.push(FrameAckEntry {
                        stream: r.u8().ok()?,
                        frame_id: r.u32().ok()?,
                    });
                }
                Self::FrameAck(entries)
            }
            0x13 => {
                if value.len() != 15 {
                    return None;
                }
                let stream = r.u8().ok()?;
                let reason = match r.u8().ok()? {
                    0 => RefreshReason::Loss,
                    1 => RefreshReason::DecoderReset,
                    2 => RefreshReason::Resume,
                    _ => return None,
                };
                let preferred = match r.u8().ok()? {
                    0 => RefreshPreferred::Ltr,
                    1 => RefreshPreferred::Idr,
                    _ => return None,
                };
                Self::RefreshRequest(RefreshRequest {
                    stream,
                    reason,
                    preferred,
                    last_good_frame: r.u32().ok()?,
                    lost_frame: r.u32().ok()?,
                    req_id: r.u32().ok()?,
                })
            }
            0x30 if value.len() == 4 => Self::Ping { id: r.u32().ok()? },
            0x31 if value.len() == 8 => Self::Pong {
                id: r.u32().ok()?,
                hold_micros: r.u32().ok()?,
            },
            0x34 => Self::Close(match r.u16().ok()? {
                1 => CloseCode::AppRequest,
                2 => CloseCode::Timeout,
                3 => CloseCode::ProtocolViolation,
                4 => CloseCode::VersionMismatch,
                5 => CloseCode::GoingAway,
                _ => CloseCode::Normal,
            }),
            0x30 | 0x31 => return None,
            _ => Self::Unknown { kind },
        })
    }
}

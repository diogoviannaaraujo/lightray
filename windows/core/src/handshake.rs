use crate::{
    Error, Result,
    bytes::{ByteReader, ByteWriter},
    crypto::{NoiseHandshake, hmac},
};
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

pub const VERSION: u8 = 1;
pub const INITIATION: u8 = 0x80;
pub const RESPONSE: u8 = 0x81;
pub const SESSION_UNKNOWN: u8 = 0x82;
pub const CAPABILITY_LTR: u8 = 1;
pub const CAPABILITY_FEC: u8 = 4;

#[derive(Clone, PartialEq, Eq, zeroize::ZeroizeOnDrop)]
pub struct Pairing {
    pub id: u64,
    pub psk: [u8; 32],
}
impl Pairing {
    pub fn generate() -> Self {
        let mut bytes = [0; 40];
        OsRng.fill_bytes(&mut bytes);
        Self {
            id: u64::from_be_bytes(bytes[..8].try_into().unwrap()),
            psk: bytes[8..].try_into().unwrap(),
        }
    }
    pub fn token(&self) -> String {
        let mut s = String::from("lr1-");
        for b in self.id.to_be_bytes().iter().chain(self.psk.iter()) {
            use std::fmt::Write;
            write!(s, "{b:02x}").unwrap();
        }
        s
    }
    pub fn parse(token: &str) -> Option<Self> {
        let hex = token.trim().strip_prefix("lr1-")?;
        if hex.len() != 80 {
            return None;
        }
        let mut bytes = [0; 40];
        for (i, b) in bytes.iter_mut().enumerate() {
            *b = u8::from_str_radix(hex.get(i * 2..i * 2 + 2)?, 16).ok()?;
        }
        Some(Self {
            id: u64::from_be_bytes(bytes[..8].try_into().ok()?),
            psk: bytes[8..].try_into().ok()?,
        })
    }
}
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum StreamKind {
    Video = 1,
    Audio = 2,
    Input = 3,
    Mic = 4,
    Data = 6,
}
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Direction {
    HostToClient = 1,
    ClientToHost = 2,
    Bidirectional = 3,
}
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum StreamClass {
    Media = 0,
    Realtime = 1,
    Reliable = 2,
    Unreliable = 3,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StreamEntry {
    pub id: u8,
    pub kind: StreamKind,
    pub direction: Direction,
    pub stream_class: StreamClass,
}
impl StreamEntry {
    pub const CONTROL: Self = Self {
        id: 0,
        kind: StreamKind::Data,
        direction: Direction::Bidirectional,
        stream_class: StreamClass::Reliable,
    };
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StreamTable {
    pub entries: Vec<StreamEntry>,
}
impl StreamTable {
    pub fn entry(&self, id: u8) -> Option<StreamEntry> {
        if id == 0 {
            Some(StreamEntry::CONTROL)
        } else {
            self.entries.iter().find(|e| e.id == id).copied()
        }
    }
    pub fn first(&self, kind: StreamKind, direction: Direction) -> Option<StreamEntry> {
        self.entries
            .iter()
            .find(|e| e.kind == kind && e.direction == direction)
            .copied()
    }
    pub fn encoded(&self) -> Vec<u8> {
        self.entries
            .iter()
            .flat_map(|e| [e.id, e.kind as u8, e.direction as u8, e.stream_class as u8])
            .collect()
    }
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.is_empty() || !bytes.len().is_multiple_of(4) || bytes.len() / 4 > 32 {
            return Err(invalid("stream table size"));
        }
        let mut entries = Vec::new();
        let mut ids = HashSet::new();
        for b in bytes.as_chunks::<4>().0 {
            if b[0] == 0 || !ids.insert(b[0]) {
                return Err(invalid("stream table entry"));
            }
            let kind = match b[1] {
                1 => StreamKind::Video,
                2 => StreamKind::Audio,
                3 => StreamKind::Input,
                4 => StreamKind::Mic,
                6 => StreamKind::Data,
                _ => return Err(invalid("stream kind")),
            };
            let direction = match b[2] {
                1 => Direction::HostToClient,
                2 => Direction::ClientToHost,
                3 => Direction::Bidirectional,
                _ => return Err(invalid("stream direction")),
            };
            let stream_class = match b[3] {
                0 => StreamClass::Media,
                1 => StreamClass::Realtime,
                2 => StreamClass::Reliable,
                3 => StreamClass::Unreliable,
                _ => return Err(invalid("stream class")),
            };
            entries.push(StreamEntry {
                id: b[0],
                kind,
                direction,
                stream_class,
            });
        }
        Ok(Self { entries })
    }
}
fn invalid(reason: &str) -> Error {
    Error::InvalidParameters(reason.into())
}
#[derive(Clone, Default, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandshakeParams {
    pub timestamp: Option<u64>,
    pub capabilities: Option<u8>,
    pub stream_table: Option<StreamTable>,
    pub max_datagram_size: Option<u16>,
    pub resume_session_id: Option<u32>,
}
impl HandshakeParams {
    pub fn encoded(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        if let Some(n) = self.timestamp {
            w.tlv(2, &n.to_be_bytes());
        }
        if let Some(n) = self.capabilities {
            w.tlv(3, &[n]);
        }
        if let Some(t) = &self.stream_table {
            w.tlv(4, &t.encoded());
        }
        if let Some(n) = self.max_datagram_size {
            w.tlv(5, &n.to_be_bytes());
        }
        if let Some(n) = self.resume_session_id {
            w.tlv(6, &n.to_be_bytes());
        }
        w.bytes
    }
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let mut out = Self::default();
        let mut seen = HashSet::new();
        let mut r = ByteReader::new(bytes);
        while r.remaining() != 0 {
            let t = r.u8().map_err(|_| invalid("trailing bytes"))?;
            let len = r.u16().map_err(|_| invalid("trailing bytes"))? as usize;
            let value = r.take(len).map_err(|_| invalid("TLV overruns"))?;
            if (1..=7).contains(&t) && !seen.insert(t) {
                return Err(invalid("duplicate TLV"));
            }
            let mut v = ByteReader::new(value);
            match t {
                2 if len == 8 => out.timestamp = Some(v.u64()?),
                3 if len == 1 => out.capabilities = Some(v.u8()?),
                4 => out.stream_table = Some(StreamTable::decode(value)?),
                5 if len == 2 => {
                    let size = v.u16()?;
                    if !(256..=9000).contains(&size) {
                        return Err(invalid("datagram size range"));
                    }
                    out.max_datagram_size = Some(size);
                }
                6 if len == 4 => out.resume_session_id = Some(v.u32()?),
                2 | 3 | 5 | 6 => return Err(invalid("TLV length")),
                _ => {}
            }
        }
        Ok(out)
    }
}
#[derive(Clone)]
pub struct ClientHandshake {
    pub datagram: Vec<u8>,
    pub params: HandshakeParams,
    state: NoiseHandshake,
}
#[derive(Clone, Debug)]
pub struct HandshakeResult {
    pub session_id: u32,
    pub reset_token: [u8; 16],
    pub params: HandshakeParams,
    pub send_key: [u8; 32],
    pub receive_key: [u8; 32],
    pub handshake_hash: [u8; 32],
}
impl ClientHandshake {
    pub fn new(psk: [u8; 32], pairing_id: u64, params: HandshakeParams) -> Result<Self> {
        let mut e = [0; 32];
        OsRng.fill_bytes(&mut e);
        Self::with_ephemeral(psk, pairing_id, params, e)
    }
    pub fn with_ephemeral(
        psk: [u8; 32],
        pairing_id: u64,
        params: HandshakeParams,
        ephemeral: [u8; 32],
    ) -> Result<Self> {
        let size = params
            .max_datagram_size
            .ok_or_else(|| invalid("missing datagram size"))? as usize;
        if !(256..=9000).contains(&size)
            || params.timestamp.is_none()
            || params.stream_table.is_none()
        {
            return Err(invalid("INIT missing required parameters"));
        }
        let mut w = ByteWriter::new();
        w.append(&[INITIATION, VERSION, 0, 0]);
        w.u64(pairing_id);
        let mut state = NoiseHandshake::new(
            &[b"lightray-v1".as_slice(), &w.bytes].concat(),
            psk,
            ephemeral,
        );
        let encoded = params.encoded();
        if 2 + encoded.len() > size - 60 {
            return Err(invalid("parameters exceed INIT"));
        }
        let mut p = ByteWriter::new();
        p.u16(encoded.len() as u16);
        p.append(&encoded);
        p.bytes.resize(size - 60, 0);
        w.append(&state.write_a(&p.bytes)?);
        Ok(Self {
            datagram: w.bytes,
            params,
            state,
        })
    }
    pub fn open(&self, response: &[u8]) -> Result<Option<HandshakeResult>> {
        if response.len() > self.datagram.len()
            || response.len() < 50
            || response[..2] != [RESPONSE, VERSION]
        {
            return Ok(None);
        }
        let mut s = self.state.clone();
        let Some(payload) = s.read_b(&response[2..]) else {
            return Ok(None);
        };
        if payload.len() < 20 {
            return Err(invalid("RESPONSE payload too short"));
        }
        let mut r = ByteReader::new(&payload);
        let session_id = r.u32()?;
        if session_id == 0 {
            return Err(invalid("session id 0"));
        }
        let token = r.take(16)?.try_into().unwrap();
        let accepted = HandshakeParams::decode(r.rest())?;
        let table = accepted
            .stream_table
            .as_ref()
            .ok_or_else(|| invalid("missing stream table"))?;
        let size = accepted
            .max_datagram_size
            .ok_or_else(|| invalid("missing datagram size"))?;
        if accepted.timestamp.is_some() || accepted.resume_session_id.is_some() {
            return Err(invalid("forbidden RESPONSE parameter"));
        }
        if size > self.params.max_datagram_size.unwrap()
            || accepted.capabilities.unwrap_or(0) & !self.params.capabilities.unwrap_or(0) != 0
        {
            return Err(invalid("RESPONSE exceeds proposal"));
        }
        if !table.entries.iter().all(|e| {
            self.params
                .stream_table
                .as_ref()
                .unwrap()
                .entries
                .contains(e)
        }) {
            return Err(invalid("RESPONSE changes stream table"));
        }
        let (send_key, receive_key) = s.split();
        Ok(Some(HandshakeResult {
            session_id,
            reset_token: token,
            params: accepted,
            send_key,
            receive_key,
            handshake_hash: s.handshake_hash(),
        }))
    }
}
#[derive(Clone)]
pub struct OpenedInit {
    pub pairing_id: u64,
    pub params: HandshakeParams,
    pub datagram: Vec<u8>,
    state: NoiseHandshake,
    remote: [u8; 32],
}
#[derive(Clone, Debug)]
pub struct HandshakeResponse {
    pub response: Vec<u8>,
    pub send_key: [u8; 32],
    pub receive_key: [u8; 32],
    pub handshake_hash: [u8; 32],
}
impl OpenedInit {
    pub fn open(datagram: &[u8], lookup: &impl Fn(u64) -> Option<[u8; 32]>) -> Result<Self> {
        if !(256..=9000).contains(&datagram.len()) {
            return Err(Error::Discard("INIT size".into()));
        }
        if datagram[..2] != [INITIATION, VERSION] {
            return Err(Error::Discard("INIT type/version".into()));
        }
        let id = u64::from_be_bytes(datagram[4..12].try_into().unwrap());
        let psk = lookup(id).ok_or_else(|| Error::Discard("unknown pairing".into()))?;
        let mut state = NoiseHandshake::new(
            &[b"lightray-v1".as_slice(), &datagram[..12]].concat(),
            psk,
            [0; 32],
        );
        let (payload, remote) = state.read_a(&datagram[12..]).ok_or(Error::Authentication)?;
        let mut r = ByteReader::new(&payload);
        let len = r.u16()? as usize;
        let params = HandshakeParams::decode(r.take(len)?)?;
        Ok(Self {
            pairing_id: id,
            params,
            datagram: datagram.to_vec(),
            state,
            remote,
        })
    }
    pub fn validate(&self, unix_time: u64) -> Result<()> {
        let size = self
            .params
            .max_datagram_size
            .ok_or_else(|| invalid("INIT missing size"))?;
        let timestamp = self
            .params
            .timestamp
            .ok_or_else(|| invalid("INIT missing timestamp"))?;
        if self.params.stream_table.is_none() {
            return Err(invalid("INIT missing table"));
        }
        if size as usize != self.datagram.len() {
            return Err(Error::Discard("INIT length differs from size".into()));
        }
        if timestamp.abs_diff(unix_time) > 30 {
            return Err(Error::Discard("INIT timestamp outside window".into()));
        }
        Ok(())
    }
    pub fn respond(
        &self,
        session_id: u32,
        token: [u8; 16],
        params: HandshakeParams,
    ) -> Result<HandshakeResponse> {
        let mut e = [0; 32];
        OsRng.fill_bytes(&mut e);
        self.respond_with_ephemeral(session_id, token, params, e)
    }
    pub fn respond_with_ephemeral(
        &self,
        session_id: u32,
        token: [u8; 16],
        params: HandshakeParams,
        ephemeral: [u8; 32],
    ) -> Result<HandshakeResponse> {
        if session_id == 0 {
            return Err(invalid("session id 0"));
        }
        let mut s = self.state.clone();
        s.ephemeral = ephemeral;
        let mut p = ByteWriter::new();
        p.u32(session_id);
        p.append(&token);
        p.append(&params.encoded());
        let response = [vec![RESPONSE, VERSION], s.write_b(&p.bytes, &self.remote)?].concat();
        if response.len() > self.datagram.len() {
            return Err(invalid("RESPONSE exceeds INIT"));
        }
        let (receive_key, send_key) = s.split();
        Ok(HandshakeResponse {
            response,
            send_key,
            receive_key,
            handshake_hash: s.handshake_hash(),
        })
    }
}
pub fn reset_token(secret: &[u8], session_id: u32) -> [u8; 16] {
    hmac(
        secret,
        &[b"lightray-v1 reset".as_slice(), &session_id.to_be_bytes()].concat(),
    )[..16]
        .try_into()
        .unwrap()
}
pub fn session_unknown(session_id: u32, token: [u8; 16]) -> Vec<u8> {
    [
        vec![SESSION_UNKNOWN, VERSION],
        session_id.to_be_bytes().to_vec(),
        token.to_vec(),
    ]
    .concat()
}

/// Bounded byte-exact retransmission cache. Call before timestamp validation.
#[derive(Default)]
pub struct InitCache {
    entries: HashMap<[u8; 32], (u64, Vec<u8>)>,
}
impl InitCache {
    pub fn lookup(&mut self, init: &[u8], now: u64) -> Option<Vec<u8>> {
        self.entries
            .retain(|_, (at, _)| now.saturating_sub(*at) <= 60_000_000);
        self.entries
            .get(&crate::crypto::hash(init))
            .map(|(_, v)| v.clone())
    }
    pub fn insert(&mut self, init: &[u8], response: Vec<u8>, now: u64) {
        if self.entries.len() >= 256
            && let Some(key) = self
                .entries
                .iter()
                .min_by_key(|(_, v)| v.0)
                .map(|(k, _)| *k)
        {
            self.entries.remove(&key);
        }
        self.entries
            .insert(crate::crypto::hash(init), (now, response));
    }
}

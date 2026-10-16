use crate::{
    Error, Result,
    bytes::{ByteReader, ByteWriter},
};
use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::ZeroizeOnDrop;

pub const PACKET_OVERHEAD: usize = 32;
pub const NOISE_PROTOCOL: &str = "Noise_NNpsk0_25519_AESGCM_SHA256";

pub fn hash(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}
pub fn hmac(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut h = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("HMAC accepts any key");
    h.update(data);
    h.finalize().into_bytes().into()
}
fn hkdf(ck: &[u8], input: &[u8], count: usize) -> Vec<[u8; 32]> {
    let temp = hmac(ck, input);
    let mut out = Vec::new();
    let mut prev = Vec::new();
    for i in 1..=count {
        prev.push(i as u8);
        let next = hmac(&temp, &prev);
        out.push(next);
        prev = next.to_vec();
    }
    out
}
pub fn nonce(n: u64) -> [u8; 12] {
    let mut out = [0; 12];
    out[4..].copy_from_slice(&n.to_be_bytes());
    out
}
pub fn encrypt(key: &[u8; 32], n: u64, ad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>> {
    if n == u64::MAX {
        return Err(Error::ResourceLimit);
    }
    Aes256Gcm::new(key.into())
        .encrypt(
            Nonce::from_slice(&nonce(n)),
            Payload {
                msg: plaintext,
                aad: ad,
            },
        )
        .map_err(|_| Error::Authentication)
}
pub fn decrypt(key: &[u8; 32], n: u64, ad: &[u8], ciphertext: &[u8]) -> Option<Vec<u8>> {
    if n == u64::MAX {
        return None;
    }
    Aes256Gcm::new(key.into())
        .decrypt(
            Nonce::from_slice(&nonce(n)),
            Payload {
                msg: ciphertext,
                aad: ad,
            },
        )
        .ok()
}

#[derive(Clone, ZeroizeOnDrop)]
pub struct TrafficKey([u8; 32]);
impl TrafficKey {
    pub fn new(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ProtectedHeader {
    pub flags: u8,
    pub session_id: u32,
    pub transport_seq: u32,
    pub send_time_micros: u32,
}
impl ProtectedHeader {
    pub const LENGTH: usize = 16;
    pub fn parse(datagram: &[u8]) -> Option<Self> {
        if datagram.len() < 16 || datagram[0] & 0x80 != 0 {
            return None;
        }
        let mut r = ByteReader::new(datagram);
        let flags = r.u8().ok()?;
        r.take(3).ok()?;
        Some(Self {
            flags,
            session_id: r.u32().ok()?,
            transport_seq: r.u32().ok()?,
            send_time_micros: r.u32().ok()?,
        })
    }
    pub fn encoded(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        w.u8(self.flags);
        w.append(&[0; 3]);
        w.u32(self.session_id);
        w.u32(self.transport_seq);
        w.u32(self.send_time_micros);
        w.bytes
    }
}
pub fn seal_packet(
    header: ProtectedHeader,
    key: &TrafficKey,
    packet_number: u64,
    chunks: &[u8],
) -> Result<Vec<u8>> {
    if packet_number as u32 != header.transport_seq {
        return Err(Error::InvalidParameters(
            "packet number/header mismatch".into(),
        ));
    }
    let mut bytes = header.encoded();
    let encrypted = encrypt(&key.0, packet_number, &bytes, chunks)?;
    bytes.extend(encrypted);
    Ok(bytes)
}
pub fn open_packet(datagram: &[u8], key: &TrafficKey, packet_number: u64) -> Option<Vec<u8>> {
    if datagram.len() < 32 {
        return None;
    }
    decrypt(&key.0, packet_number, &datagram[..16], &datagram[16..])
}
pub fn reconstruct_packet_number(expected: u64, transport_seq: u32) -> u64 {
    let window = 1u64 << 32;
    let half = 1u64 << 31;
    let candidate = (expected & !(window - 1)) | u64::from(transport_seq);
    if expected >= candidate && expected - candidate >= half && candidate <= u64::MAX - window {
        return candidate + window;
    }
    if candidate > expected && candidate - expected > half && candidate >= window {
        return candidate - window;
    }
    candidate
}
pub fn wrapping_difference(a: u32, b: u32) -> i64 {
    i64::from(a.wrapping_sub(b) as i32)
}
pub fn serial_newer(a: u32, b: u32) -> bool {
    a != b && a.wrapping_sub(b) < (1 << 31)
}
#[derive(Clone, Debug, Default)]
pub struct ReplayWindow {
    bits: [u64; 32],
    highest: Option<u64>,
}
impl ReplayWindow {
    pub fn highest(&self) -> Option<u64> {
        self.highest
    }
    pub fn expected(&self) -> u64 {
        self.highest.map_or(0, |n| n.saturating_add(1))
    }
    pub fn accepts(&self, n: u64) -> bool {
        self.highest.is_none_or(|highest| {
            n > highest
                || (highest - n < 2048
                    && self.bits[(n % 2048 / 64) as usize] & (1 << (n % 64)) == 0)
        })
    }
    pub fn record(&mut self, n: u64) {
        if let Some(h) = self.highest {
            if n > h {
                if n - h >= 2048 {
                    self.bits.fill(0);
                } else {
                    for i in h + 1..=n {
                        self.bits[(i % 2048 / 64) as usize] &= !(1 << (i % 64));
                    }
                }
                self.highest = Some(n);
            }
        } else {
            self.highest = Some(n);
        }
        self.bits[(n % 2048 / 64) as usize] |= 1 << (n % 64);
    }
}

#[derive(Clone, zeroize::Zeroize, zeroize::ZeroizeOnDrop)]
struct SymmetricState {
    ck: [u8; 32],
    h: [u8; 32],
    k: Option<[u8; 32]>,
    n: u64,
}
impl SymmetricState {
    fn new() -> Self {
        let mut h = [0; 32];
        if NOISE_PROTOCOL.len() <= 32 {
            h[..NOISE_PROTOCOL.len()].copy_from_slice(NOISE_PROTOCOL.as_bytes());
        } else {
            h = hash(NOISE_PROTOCOL.as_bytes());
        }
        Self {
            ck: h,
            h,
            k: None,
            n: 0,
        }
    }
    fn mix_hash(&mut self, bytes: &[u8]) {
        self.h = hash(&[self.h.as_slice(), bytes].concat());
    }
    fn mix_key(&mut self, bytes: &[u8]) {
        let v = hkdf(&self.ck, bytes, 2);
        self.ck = v[0];
        self.k = Some(v[1]);
        self.n = 0;
    }
    fn mix_key_and_hash(&mut self, bytes: &[u8]) {
        let v = hkdf(&self.ck, bytes, 3);
        self.ck = v[0];
        self.mix_hash(&v[1]);
        self.k = Some(v[2]);
        self.n = 0;
    }
    fn encrypt_and_hash(&mut self, plaintext: &[u8]) -> Result<Vec<u8>> {
        let cipher = if let Some(k) = self.k {
            let out = encrypt(&k, self.n, &self.h, plaintext)?;
            self.n += 1;
            out
        } else {
            plaintext.to_vec()
        };
        self.mix_hash(&cipher);
        Ok(cipher)
    }
    fn decrypt_and_hash(&mut self, cipher: &[u8]) -> Option<Vec<u8>> {
        let plain = if let Some(k) = self.k {
            let out = decrypt(&k, self.n, &self.h, cipher)?;
            self.n += 1;
            out
        } else {
            cipher.to_vec()
        };
        self.mix_hash(cipher);
        Some(plain)
    }
}
#[derive(Clone, zeroize::Zeroize, zeroize::ZeroizeOnDrop)]
pub(crate) struct NoiseHandshake {
    symmetric: SymmetricState,
    pub(crate) ephemeral: [u8; 32],
    psk: [u8; 32],
}
impl NoiseHandshake {
    pub(crate) fn new(prologue: &[u8], psk: [u8; 32], ephemeral: [u8; 32]) -> Self {
        let mut s = Self {
            symmetric: SymmetricState::new(),
            ephemeral,
            psk,
        };
        s.symmetric.mix_hash(prologue);
        s
    }
    fn public_key(&self) -> [u8; 32] {
        PublicKey::from(&StaticSecret::from(self.ephemeral)).to_bytes()
    }
    fn mix_ephemeral(&mut self, public: &[u8]) {
        self.symmetric.mix_hash(public);
        self.symmetric.mix_key(public);
    }
    fn dh(&self, remote: &[u8; 32]) -> Option<[u8; 32]> {
        let shared = StaticSecret::from(self.ephemeral).diffie_hellman(&PublicKey::from(*remote));
        if shared.was_contributory() {
            Some(shared.to_bytes())
        } else {
            None
        }
    }
    pub(crate) fn write_a(&mut self, payload: &[u8]) -> Result<Vec<u8>> {
        self.symmetric.mix_key_and_hash(&self.psk);
        let public = self.public_key();
        self.mix_ephemeral(&public);
        Ok([public.to_vec(), self.symmetric.encrypt_and_hash(payload)?].concat())
    }
    pub(crate) fn read_a(&mut self, message: &[u8]) -> Option<(Vec<u8>, [u8; 32])> {
        if message.len() < 48 {
            return None;
        }
        self.symmetric.mix_key_and_hash(&self.psk);
        let remote: [u8; 32] = message[..32].try_into().ok()?;
        self.mix_ephemeral(&remote);
        Some((self.symmetric.decrypt_and_hash(&message[32..])?, remote))
    }
    pub(crate) fn write_b(&mut self, payload: &[u8], remote: &[u8; 32]) -> Result<Vec<u8>> {
        let public = self.public_key();
        self.mix_ephemeral(&public);
        self.symmetric
            .mix_key(&self.dh(remote).ok_or(Error::Authentication)?);
        Ok([public.to_vec(), self.symmetric.encrypt_and_hash(payload)?].concat())
    }
    pub(crate) fn read_b(&mut self, message: &[u8]) -> Option<Vec<u8>> {
        if message.len() < 48 {
            return None;
        }
        let remote: [u8; 32] = message[..32].try_into().ok()?;
        self.mix_ephemeral(&remote);
        self.symmetric.mix_key(&self.dh(&remote)?);
        self.symmetric.decrypt_and_hash(&message[32..])
    }
    pub(crate) fn split(&self) -> ([u8; 32], [u8; 32]) {
        let v = hkdf(&self.symmetric.ck, &[], 2);
        (v[0], v[1])
    }
    pub(crate) fn handshake_hash(&self) -> [u8; 32] {
        self.symmetric.h
    }
}

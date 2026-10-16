use crate::{Error, Result};

#[derive(Default, Clone, Debug)]
pub struct ByteWriter {
    pub bytes: Vec<u8>,
}
impl ByteWriter {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn u8(&mut self, n: u8) {
        self.bytes.push(n);
    }
    pub fn u16(&mut self, n: u16) {
        self.append(&n.to_be_bytes());
    }
    pub fn i16(&mut self, n: i16) {
        self.append(&n.to_be_bytes());
    }
    pub fn u32(&mut self, n: u32) {
        self.append(&n.to_be_bytes());
    }
    pub fn u64(&mut self, n: u64) {
        self.append(&n.to_be_bytes());
    }
    pub fn append(&mut self, bytes: &[u8]) {
        self.bytes.extend_from_slice(bytes);
    }
    pub fn tlv(&mut self, kind: u8, bytes: &[u8]) {
        self.u8(kind);
        self.u16(u16::try_from(bytes.len()).expect("TLV too large"));
        self.append(bytes);
    }
}

#[derive(Clone, Debug)]
pub struct ByteReader<'a> {
    bytes: &'a [u8],
    offset: usize,
}
impl<'a> ByteReader<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }
    pub fn remaining(&self) -> usize {
        self.bytes.len() - self.offset
    }
    pub fn offset(&self) -> usize {
        self.offset
    }
    pub fn rest(&self) -> &'a [u8] {
        &self.bytes[self.offset..]
    }
    pub fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if n > self.remaining() {
            return Err(Error::Truncated);
        }
        let bytes = &self.bytes[self.offset..self.offset + n];
        self.offset += n;
        Ok(bytes)
    }
    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    pub fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_be_bytes(self.take(2)?.try_into().unwrap()))
    }
    pub fn i16(&mut self) -> Result<i16> {
        Ok(i16::from_be_bytes(self.take(2)?.try_into().unwrap()))
    }
    pub fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }
    pub fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_be_bytes(self.take(8)?.try_into().unwrap()))
    }
}

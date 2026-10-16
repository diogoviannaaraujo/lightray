//! RFC 5510 systematic Reed–Solomon over GF(256), matching the Apple encoder.
use crate::{Error, Result};
use std::{collections::HashMap, ops::Range, sync::OnceLock};
fn tables() -> &'static ([u8; 510], [u8; 256]) {
    static T: OnceLock<([u8; 510], [u8; 256])> = OnceLock::new();
    T.get_or_init(|| {
        let mut e = [0; 510];
        let mut l = [0; 256];
        let mut x = 1u16;
        for i in 0..255 {
            e[i] = x as u8;
            e[i + 255] = x as u8;
            l[x as usize] = i as u8;
            x <<= 1;
            if x & 256 != 0 {
                x ^= 0x11d;
            }
        }
        (e, l)
    })
}
fn mul(a: u8, b: u8) -> u8 {
    if a == 0 || b == 0 {
        0
    } else {
        let (e, l) = tables();
        e[l[a as usize] as usize + l[b as usize] as usize]
    }
}
fn inv(a: u8) -> u8 {
    let (e, l) = tables();
    e[255 - l[a as usize] as usize]
}
fn power(i: usize) -> u8 {
    tables().0[i % 255]
}
fn accumulate(source: &[u8], factor: u8, target: &mut [u8]) {
    if factor == 0 {
        return;
    }
    for (s, t) in source.iter().zip(target) {
        *t ^= mul(*s, factor);
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FecLayout {
    pub data_count: usize,
    pub max_block_length: usize,
    pub parity_per_block: usize,
    pub block_count: usize,
    long_length: usize,
    short_length: usize,
    long_blocks: usize,
}
impl FecLayout {
    pub fn new(
        data_count: usize,
        max_block_length: usize,
        parity_per_block: usize,
    ) -> Option<Self> {
        if data_count == 0 || max_block_length == 0 || parity_per_block == 0 {
            return None;
        }
        let block_count = data_count.div_ceil(max_block_length);
        let long_length = data_count.div_ceil(block_count);
        let short_length = data_count / block_count;
        let long_blocks = data_count - short_length * block_count;
        if long_length.checked_add(parity_per_block)? > 255 {
            return None;
        }
        Some(Self {
            data_count,
            max_block_length,
            parity_per_block,
            block_count,
            long_length,
            short_length,
            long_blocks,
        })
    }
    pub fn for_frame(data_count: usize, percent: usize, min_parity: usize) -> Self {
        let min_parity = min_parity.clamp(1, 254);
        let max_block = (255 - min_parity).min(25_500 / (100 + percent)).max(1);
        let blocks = data_count.div_ceil(max_block);
        let longest = data_count.div_ceil(blocks);
        let parity = min_parity
            .max((longest * percent).div_ceil(100))
            .min(255 - longest);
        Self::new(data_count, max_block, parity).expect("frame must have data")
    }
    pub fn parity_count(&self) -> usize {
        self.block_count * self.parity_per_block
    }
    pub fn position_count(&self) -> usize {
        self.data_count + self.parity_count()
    }
    pub fn range_of_block(&self, b: usize) -> Range<usize> {
        let start = if b < self.long_blocks {
            b * self.long_length
        } else {
            self.long_blocks * self.long_length + (b - self.long_blocks) * self.short_length
        };
        start
            ..start
                + if b < self.long_blocks {
                    self.long_length
                } else {
                    self.short_length
                }
    }
    pub fn block_of_data(&self, index: usize) -> usize {
        let long = self.long_blocks * self.long_length;
        if index < long {
            index / self.long_length
        } else {
            self.long_blocks + (index - long) / self.short_length
        }
    }
    pub fn position_of_data(&self, index: usize) -> usize {
        index + self.block_of_data(index) * self.parity_per_block
    }
    pub fn position_of_parity(&self, index: usize) -> usize {
        self.range_of_block(index / self.parity_per_block).end + index
    }
    pub fn fragment_at(&self, position: usize) -> (bool, usize) {
        let long_span = self.long_length + self.parity_per_block;
        let short_span = self.short_length + self.parity_per_block;
        let b = if position < self.long_blocks * long_span {
            position / long_span
        } else {
            self.long_blocks + (position - self.long_blocks * long_span) / short_span
        };
        let start = if b < self.long_blocks {
            b * long_span
        } else {
            self.long_blocks * long_span + (b - self.long_blocks) * short_span
        };
        let offset = position - start;
        let data = self.range_of_block(b);
        if offset < data.len() {
            (false, data.start + offset)
        } else {
            (true, b * self.parity_per_block + offset - data.len())
        }
    }
}
pub type FECLayout = FecLayout;
#[derive(Default, Debug)]
pub struct ReedSolomon {
    cache: HashMap<(usize, usize), Vec<u8>>,
    cache_bytes: usize,
}
impl ReedSolomon {
    pub fn coefficients(&mut self, k: usize, p: usize) -> Vec<u8> {
        assert!(k > 0 && p > 0 && k + p <= 255);
        if let Some(c) = self.cache.get(&(k, p)) {
            return c.clone();
        }
        let nodes: Vec<_> = (0..k).map(power).collect();
        let denom: Vec<_> = (0..k)
            .map(|i| {
                (0..k)
                    .filter(|l| *l != i)
                    .fold(1, |a, l| mul(a, nodes[i] ^ nodes[l]))
            })
            .collect();
        let mut rows = vec![0; k * p];
        for j in 0..p {
            let y = power(k + j);
            let num = nodes.iter().fold(1, |a, x| mul(a, y ^ x));
            for i in 0..k {
                rows[j * k + i] = mul(num, inv(mul(y ^ nodes[i], denom[i])));
            }
        }
        if self.cache_bytes + rows.len() > 1 << 20 {
            self.cache.clear();
            self.cache_bytes = 0;
        }
        self.cache_bytes += rows.len();
        self.cache.insert((k, p), rows.clone());
        rows
    }
    pub fn encode(&mut self, data: &[u8], k: usize, p: usize, length: usize) -> Result<Vec<u8>> {
        if k == 0 || p == 0 || k + p > 255 || length == 0 || data.len() < k.saturating_mul(length) {
            return Err(Error::InvalidParameters("FEC shape".into()));
        }
        let rows = self.coefficients(k, p);
        let mut parity = vec![0; p * length];
        for i in 0..k {
            for j in 0..p {
                accumulate(
                    &data[i * length..(i + 1) * length],
                    rows[j * k + i],
                    &mut parity[j * length..(j + 1) * length],
                );
            }
        }
        Ok(parity)
    }
    pub fn recover(
        &mut self,
        shards: &mut [u8],
        k: usize,
        p: usize,
        length: usize,
        missing: &[usize],
        parity: &[(usize, &[u8])],
    ) -> Result<()> {
        let e = missing.len();
        if e == 0 {
            return Ok(());
        }
        if k == 0
            || p == 0
            || k + p > 255
            || e > p
            || e != parity.len()
            || length == 0
            || shards.len() < k.saturating_mul(length)
            || missing.iter().any(|i| *i >= k)
            || parity.iter().any(|(row, b)| *row >= p || b.len() != length)
        {
            return Err(Error::InvalidParameters("FEC recovery shape".into()));
        }
        let mut unique = missing.to_vec();
        unique.sort_unstable();
        unique.dedup();
        let mut rows_unique: Vec<_> = parity.iter().map(|(i, _)| *i).collect();
        rows_unique.sort_unstable();
        rows_unique.dedup();
        if unique.len() != e || rows_unique.len() != e {
            return Err(Error::InvalidParameters("duplicate FEC shard".into()));
        }
        let rows = self.coefficients(k, p);
        let mut syndromes = vec![0; e * length];
        let mut matrix = vec![0; e * e];
        for (a, (row, bytes)) in parity.iter().enumerate() {
            let target = &mut syndromes[a * length..(a + 1) * length];
            target.copy_from_slice(bytes);
            for i in 0..k {
                if !missing.contains(&i) {
                    accumulate(
                        &shards[i * length..(i + 1) * length],
                        rows[row * k + i],
                        target,
                    );
                }
            }
            for (b, column) in missing.iter().enumerate() {
                matrix[a * e + b] = rows[row * k + column];
            }
        }
        let inverse = invert(&matrix, e)?;
        for (b, column) in missing.iter().enumerate() {
            let target = &mut shards[column * length..(column + 1) * length];
            target.fill(0);
            for a in 0..e {
                accumulate(
                    &syndromes[a * length..(a + 1) * length],
                    inverse[b * e + a],
                    target,
                );
            }
        }
        Ok(())
    }
}
fn invert(matrix: &[u8], n: usize) -> Result<Vec<u8>> {
    let mut m = matrix.to_vec();
    let mut inverse = vec![0; n * n];
    for i in 0..n {
        inverse[i * n + i] = 1;
    }
    for c in 0..n {
        let pivot = (c..n)
            .find(|r| m[r * n + c] != 0)
            .ok_or_else(|| Error::InvalidParameters("singular FEC matrix".into()))?;
        if pivot != c {
            for j in 0..n {
                m.swap(pivot * n + j, c * n + j);
                inverse.swap(pivot * n + j, c * n + j);
            }
        }
        let scale = inv(m[c * n + c]);
        for j in 0..n {
            m[c * n + j] = mul(m[c * n + j], scale);
            inverse[c * n + j] = mul(inverse[c * n + j], scale);
        }
        for r in 0..n {
            if r == c {
                continue;
            }
            let factor = m[r * n + c];
            for j in 0..n {
                m[r * n + j] ^= mul(factor, m[c * n + j]);
                inverse[r * n + j] ^= mul(factor, inverse[c * n + j]);
            }
        }
    }
    Ok(inverse)
}

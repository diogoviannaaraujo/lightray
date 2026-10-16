mod capture;
mod decode;
mod gpu;
mod nvenc;
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct VideoConfig {
    pub width: u32,
    pub height: u32,
    pub vps: Vec<u8>,
    pub sps: Vec<u8>,
    pub pps: Vec<u8>,
}
#[derive(Clone, Debug)]
pub struct EncodedFrame {
    pub data: Vec<u8>,
    pub config: Option<VideoConfig>,
    pub keyframe: bool,
    pub timestamp: u64,
}
pub use capture::CaptureEncoder;
pub use decode::DecoderRenderer;
impl VideoConfig {
    /// Read coded dimensions and conformance cropping from an HEVC SPS (raw NAL, no start code).
    pub fn from_parameter_sets(vps: Vec<u8>, sps: Vec<u8>, pps: Vec<u8>) -> anyhow::Result<Self> {
        use anyhow::ensure;
        ensure!(
            vps.len() >= 2
                && sps.len() >= 4
                && pps.len() >= 2
                && vps.len() <= 65535
                && sps.len() <= 65535
                && pps.len() <= 65535,
            "Invalid HEVC parameter sets"
        );
        ensure!(
            (vps[0] >> 1) & 63 == 32 && (sps[0] >> 1) & 63 == 33 && (pps[0] >> 1) & 63 == 34,
            "Invalid HEVC parameter-set NAL types"
        );
        let mut rbsp = Vec::new();
        let mut zeros = 0;
        for &byte in &sps[2..] {
            if zeros >= 2 && byte == 3 {
                zeros = 0;
                continue;
            }
            rbsp.push(byte);
            zeros = if byte == 0 { zeros + 1 } else { 0 };
        }
        struct Bits<'a> {
            data: &'a [u8],
            at: usize,
        }
        impl Bits<'_> {
            fn read(&mut self, count: usize) -> anyhow::Result<u32> {
                anyhow::ensure!(
                    count <= 32 && self.at + count <= self.data.len() * 8,
                    "Truncated HEVC SPS"
                );
                let mut value = 0;
                for _ in 0..count {
                    value =
                        (value << 1) | ((self.data[self.at / 8] >> (7 - self.at % 8)) & 1) as u32;
                    self.at += 1;
                }
                Ok(value)
            }
            fn skip(&mut self, count: usize) -> anyhow::Result<()> {
                anyhow::ensure!(
                    self.at + count <= self.data.len() * 8,
                    "Truncated HEVC profile"
                );
                self.at += count;
                Ok(())
            }
            fn ue(&mut self) -> anyhow::Result<u32> {
                let mut zeros = 0;
                while self.read(1)? == 0 {
                    zeros += 1;
                    anyhow::ensure!(zeros < 31, "HEVC SPS Exp-Golomb overflow");
                }
                Ok((1 << zeros) - 1 + self.read(zeros)?)
            }
        }
        let mut bits = Bits { data: &rbsp, at: 0 };
        bits.skip(4)?;
        let sublayers = bits.read(3)? as usize;
        bits.skip(1)?;
        bits.skip(96)?;
        let mut flags = Vec::new();
        for _ in 0..sublayers {
            flags.push((bits.read(1)? != 0, bits.read(1)? != 0));
        }
        if sublayers > 0 {
            bits.skip((8 - sublayers) * 2)?;
        }
        for (profile, level) in flags {
            if profile {
                bits.skip(88)?;
            }
            if level {
                bits.skip(8)?;
            }
        }
        bits.ue()?;
        let chroma = bits.ue()?;
        ensure!(chroma <= 3, "Invalid HEVC chroma format");
        let separate = chroma == 3 && bits.read(1)? != 0;
        let mut width = bits.ue()?;
        let mut height = bits.ue()?;
        if bits.read(1)? != 0 {
            let left = bits.ue()?;
            let right = bits.ue()?;
            let top = bits.ue()?;
            let bottom = bits.ue()?;
            let (sx, sy) = if separate {
                (1, 1)
            } else {
                match chroma {
                    1 => (2, 2),
                    2 => (2, 1),
                    _ => (1, 1),
                }
            };
            width = width
                .checked_sub(
                    (left + right)
                        .checked_mul(sx)
                        .ok_or_else(|| anyhow::anyhow!("Invalid SPS cropping"))?,
                )
                .ok_or_else(|| anyhow::anyhow!("Invalid SPS crop width"))?;
            height = height
                .checked_sub(
                    (top + bottom)
                        .checked_mul(sy)
                        .ok_or_else(|| anyhow::anyhow!("Invalid SPS cropping"))?,
                )
                .ok_or_else(|| anyhow::anyhow!("Invalid SPS crop height"))?;
        }
        ensure!(
            (64..=7680).contains(&width) && (64..=4320).contains(&height),
            "Unsupported HEVC dimensions"
        );
        Ok(Self {
            width,
            height,
            vps,
            sps,
            pps,
        })
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct MediaTimings {
    pub capture_ms: f64,
    pub encode_ms: f64,
    pub decode_ms: f64,
    pub present_ms: f64,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn apple_parameter_sets_and_truncated_sps() {
        let encoded = nvenc::parse_annex_b(
            include_bytes!("../../../tools/windows/reference/videotoolbox-idr.hevc"),
            1920,
            1080,
            1,
        )
        .unwrap();
        let config = encoded.config.unwrap();
        let parsed = VideoConfig::from_parameter_sets(
            config.vps.clone(),
            config.sps.clone(),
            config.pps.clone(),
        )
        .unwrap();
        assert_eq!((parsed.width, parsed.height), (1920, 1080));
        for length in 0..config.sps.len() {
            // Early prefix truncation must fail without ever reading beyond the NAL.
            if length < 16 {
                assert!(VideoConfig::from_parameter_sets(
                    config.vps.clone(),
                    config.sps[..length].to_vec(),
                    config.pps.clone()
                )
                .is_err());
            }
        }
    }
    #[test]
    #[ignore = "Requires an interactive NVIDIA GPU and installed hardware HEVC decoder"]
    fn gpu_lifecycle_and_resolution_change() {
        let mut decoder = DecoderRenderer::new(1920, 1080).unwrap();
        for (width, height) in [(1920, 1080), (640, 480), (1280, 720)] {
            let mut encoder = CaptureEncoder::synthetic(width, height, 60, 18_000_000).unwrap();
            for index in 0..5 {
                let frame = encoder.frame(index == 0, index + 1).unwrap().unwrap();
                assert!(decoder.decode(&frame).unwrap());
            }
            decoder.resize(1280, 720).unwrap();
            decoder.reset().unwrap();
        }
    }
}

#[cfg(test)]
mod gpu_fixture_tests {
    use super::*;
    #[test]
    #[ignore = "Requires hardware HEVC decoding"]
    fn apple_videotoolbox_decode_and_idr_recovery() {
        let bytes = include_bytes!("../../../tools/windows/reference/videotoolbox-idr.hevc");
        let starts: Vec<_> = bytes
            .windows(4)
            .enumerate()
            .filter_map(|(i, b)| (b == [0, 0, 0, 1]).then_some(i))
            .collect();
        let mut pending = Vec::new();
        let mut index = 0;
        let mut decoded = 0;
        let mut decoder = DecoderRenderer::new(1920, 1080).unwrap();
        for (n, &start) in starts.iter().enumerate() {
            let end = starts.get(n + 1).copied().unwrap_or(bytes.len());
            let ty = (bytes[start + 4] >> 1) & 63;
            pending.extend_from_slice(&bytes[start..end]);
            if ty <= 31 {
                if index == 40 {
                    decoder.reset().unwrap();
                }
                if !(40..=45).contains(&index) {
                    let frame =
                        nvenc::parse_annex_b(&pending, 1920, 1080, index * 16667 + 1).unwrap();
                    assert!(
                        decoder.decode(&frame).unwrap(),
                        "Apple frame {index} did not decode"
                    );
                    decoded += 1;
                }
                pending.clear();
                index += 1;
            }
        }
        assert_eq!(index, 120);
        assert_eq!(decoded, 114);
    }
}

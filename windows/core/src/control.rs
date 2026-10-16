use crate::bytes::{ByteReader, ByteWriter};
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DisplayInfo {
    pub id: u32,
    pub is_primary: bool,
    pub supports_hdr: bool,
    pub width: u32,
    pub height: u32,
    pub refresh_millihertz: u32,
    pub layout_x: i32,
    pub layout_y: i32,
    pub layout_width: u32,
    pub layout_height: u32,
    pub name: String,
}
impl DisplayInfo {
    pub fn encoded(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        w.u32(self.id);
        w.u8(u8::from(self.is_primary) | (u8::from(self.supports_hdr) << 1));
        w.u16(self.width.min(65535) as u16);
        w.u16(self.height.min(65535) as u16);
        w.u32(self.refresh_millihertz);
        w.u32(self.layout_x as u32);
        w.u32(self.layout_y as u32);
        w.u32(self.layout_width);
        w.u32(self.layout_height);
        let mut end = self.name.len().min(64);
        while !self.name.is_char_boundary(end) {
            end -= 1;
        }
        w.append(&self.name.as_bytes()[..end]);
        w.bytes
    }
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        let mut r = ByteReader::new(bytes);
        let id = r.u32().ok()?;
        if id == 0 {
            return None;
        }
        let flags = r.u8().ok()?;
        let width = r.u16().ok()? as u32;
        let height = r.u16().ok()? as u32;
        let refresh_millihertz = r.u32().ok()?;
        let layout_x = r.u32().ok()? as i32;
        let layout_y = r.u32().ok()? as i32;
        let layout_width = r.u32().ok()?;
        let layout_height = r.u32().ok()?;
        if r.remaining() > 64 {
            return None;
        }
        let name = std::str::from_utf8(r.rest()).ok()?.to_owned();
        Some(Self {
            id,
            is_primary: flags & 1 != 0,
            supports_hdr: flags & 2 != 0,
            width,
            height,
            refresh_millihertz,
            layout_x,
            layout_y,
            layout_width,
            layout_height,
            name,
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ControlMessage {
    SelectDisplay {
        req_id: u32,
        stream: u8,
        display: u32,
    },
    DisplaySelected {
        req_id: u32,
        stream: u8,
        display: u32,
    },
    StreamDisplay {
        stream: u8,
        display: u32,
    },
    Displays(Vec<DisplayInfo>),
}
impl ControlMessage {
    pub fn encoded(&self) -> Vec<u8> {
        let mut w = ByteWriter::new();
        let (kind, req, stream, display) = match self {
            Self::SelectDisplay {
                req_id,
                stream,
                display,
            } => (1, *req_id, *stream, Some(*display)),
            Self::DisplaySelected {
                req_id,
                stream,
                display,
            } => (2, *req_id, *stream, Some(*display)),
            Self::StreamDisplay { stream, display } => (3, 0, *stream, Some(*display)),
            Self::Displays(_) => (0xf0, 0, 0, None),
        };
        w.u8(kind);
        w.u32(req);
        w.u8(stream);
        if let Some(id) = display {
            w.tlv(0xf0, &id.to_be_bytes());
        }
        if let Self::Displays(list) = self {
            for info in list {
                w.tlv(0xf1, &info.encoded());
            }
        }
        w.bytes
    }
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        let mut r = ByteReader::new(bytes);
        let kind = r.u8().ok()?;
        let req_id = r.u32().ok()?;
        let stream = r.u8().ok()?;
        let mut display = None;
        let mut infos = Vec::new();
        while r.remaining() != 0 {
            let t = r.u8().ok()?;
            let n = r.u16().ok()? as usize;
            let v = r.take(n).ok()?;
            match t {
                0xf0 => {
                    if n != 4 {
                        return None;
                    }
                    display = Some(u32::from_be_bytes(v.try_into().ok()?));
                }
                0xf1 => infos.push(DisplayInfo::parse(v)?),
                _ => {}
            }
        }
        Some(match kind {
            1 => Self::SelectDisplay {
                req_id,
                stream,
                display: display?,
            },
            2 => Self::DisplaySelected {
                req_id,
                stream,
                display: display?,
            },
            3 => Self::StreamDisplay {
                stream,
                display: display?,
            },
            0xf0 => Self::Displays(infos),
            _ => return None,
        })
    }
}

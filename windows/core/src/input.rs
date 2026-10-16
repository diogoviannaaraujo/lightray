use crate::{
    Error, Result,
    bytes::{ByteReader, ByteWriter},
};
use serde::{Deserialize, Serialize};
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PointerButton {
    Left = 1,
    Right = 2,
    Middle = 3,
    Back = 4,
    Forward = 5,
}
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ScrollUnits {
    WheelNotch120 = 0,
    Pixels = 1,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputDevice {
    Keyboard,
    Pointer,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum InputMessage {
    Key {
        usage: u16,
        down: bool,
        is_repeat: bool,
    },
    Text(String),
    Pointer {
        x: u16,
        y: u16,
        display: u32,
    },
    Button {
        button: PointerButton,
        down: bool,
    },
    Scroll {
        dx: i16,
        dy: i16,
        units: ScrollUnits,
    },
}
impl InputMessage {
    pub fn device(&self) -> InputDevice {
        match self {
            Self::Key { .. } | Self::Text(_) => InputDevice::Keyboard,
            _ => InputDevice::Pointer,
        }
    }
    pub fn encoded(&self) -> Result<Vec<u8>> {
        let mut w = ByteWriter::new();
        match self {
            Self::Key {
                usage,
                down,
                is_repeat,
            } => {
                w.u8(1);
                w.u16(*usage);
                w.u8(u8::from(*down) | (u8::from(*is_repeat) << 1));
            }
            Self::Text(text) => {
                if text.is_empty() || text.len() > 1024 {
                    return Err(Error::InvalidParameters("text length".into()));
                }
                w.u8(2);
                w.u16(text.len() as u16);
                w.append(text.as_bytes());
            }
            Self::Pointer { x, y, display } => {
                w.u8(0x10);
                w.u16(*x);
                w.u16(*y);
                w.u32(*display);
            }
            Self::Button { button, down } => {
                w.u8(0x11);
                w.u8(*button as u8);
                w.u8(u8::from(*down));
            }
            Self::Scroll { dx, dy, units } => {
                w.u8(0x12);
                w.i16(*dx);
                w.i16(*dy);
                w.u8(*units as u8);
            }
        }
        Ok(w.bytes)
    }
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        let mut r = ByteReader::new(bytes);
        Some(match r.u8().ok()? {
            1 => {
                let usage = r.u16().ok()?;
                let flags = r.u8().ok()?;
                Self::Key {
                    usage,
                    down: flags & 1 != 0,
                    is_repeat: flags & 2 != 0,
                }
            }
            2 => {
                let n = r.u16().ok()? as usize;
                if n == 0 || n > 1024 {
                    return None;
                }
                Self::Text(std::str::from_utf8(r.take(n).ok()?).ok()?.to_owned())
            }
            0x10 => Self::Pointer {
                x: r.u16().ok()?,
                y: r.u16().ok()?,
                display: r.u32().unwrap_or(0),
            },
            0x11 => {
                let button = match r.u8().ok()? {
                    1 => PointerButton::Left,
                    2 => PointerButton::Right,
                    3 => PointerButton::Middle,
                    4 => PointerButton::Back,
                    5 => PointerButton::Forward,
                    _ => return None,
                };
                Self::Button {
                    button,
                    down: r.u8().ok()? != 0,
                }
            }
            0x12 => {
                let dx = r.i16().ok()?;
                let dy = r.i16().ok()?;
                let units = match r.u8().ok()? {
                    0 => ScrollUnits::WheelNotch120,
                    1 => ScrollUnits::Pixels,
                    _ => return None,
                };
                Self::Scroll { dx, dy, units }
            }
            _ => return None,
        })
    }
}

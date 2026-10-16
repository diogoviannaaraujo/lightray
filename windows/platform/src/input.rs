use anyhow::{bail, ensure, Result};
use std::{
    collections::{BTreeMap, BTreeSet},
    time::{Duration, Instant},
};
use windows::Win32::UI::HiDpi::{
    SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::{Input::KeyboardAndMouse::*, WindowsAndMessaging::*};

struct PhysicalCoordinates(DPI_AWARENESS_CONTEXT);
impl PhysicalCoordinates {
    fn enter() -> Result<Self> {
        let previous =
            unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
        ensure!(
            !previous.0.is_null(),
            "Unable to select physical desktop coordinates"
        );
        Ok(Self(previous))
    }
}
impl Drop for PhysicalCoordinates {
    fn drop(&mut self) {
        unsafe {
            SetThreadDpiAwarenessContext(self.0);
        }
    }
}

#[derive(Default)]
pub struct InputInjector {
    keys: BTreeSet<u16>,
    buttons: BTreeSet<u8>,
    displays: BTreeMap<u32, crate::Display>,
    last_display_refresh: Option<Instant>,
}
fn send(input: INPUT) -> Result<()> {
    unsafe {
        ensure!(
            SendInput(&[input], std::mem::size_of::<INPUT>() as i32) == 1,
            "Windows blocked remote input (desktop may be locked or elevated)"
        );
    }
    Ok(())
}
fn keyboard(scan: u16, flags: KEYBD_EVENT_FLAGS) -> Result<()> {
    send(INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wScan: scan,
                dwFlags: flags,
                ..Default::default()
            },
        },
    })
}
fn virtual_pause(down: bool) -> Result<()> {
    send(INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VK_PAUSE,
                dwFlags: if down {
                    KEYBD_EVENT_FLAGS(0)
                } else {
                    KEYEVENTF_KEYUP
                },
                ..Default::default()
            },
        },
    })
}
fn mouse(flags: MOUSE_EVENT_FLAGS, x: i32, y: i32, data: u32) -> Result<()> {
    send(INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx: x,
                dy: y,
                mouseData: data,
                dwFlags: flags,
                ..Default::default()
            },
        },
    })
}
// USB HID keyboard page 0x07 -> PC set-1 scan code. E0 encoded in bit 8.
pub fn hid_scan(hid: u16) -> Option<u16> {
    Some(match hid {
        4..=29 => [
            0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31,
            0x18, 0x19, 0x10, 0x13, 0x1f, 0x14, 0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c,
        ][(hid - 4) as usize],
        30..=38 => hid - 28,
        39 => 0x0b,
        40 => 0x1c,
        41 => 1,
        42 => 0x0e,
        43 => 0x0f,
        44 => 0x39,
        45 => 0x0c,
        46 => 0x0d,
        47 => 0x1a,
        48 => 0x1b,
        49 | 50 => 0x2b,
        51 => 0x27,
        52 => 0x28,
        53 => 0x29,
        54 => 0x33,
        55 => 0x34,
        56 => 0x35,
        57 => 0x3a,
        58..=67 => hid - 58 + 0x3b,
        68 => 0x57,
        69 => 0x58,
        70 => 0x137,
        71 => 0x46,
        72 => 0x145,
        73 => 0x152,
        74 => 0x147,
        75 => 0x149,
        76 => 0x153,
        77 => 0x14f,
        78 => 0x151,
        79 => 0x14d,
        80 => 0x14b,
        81 => 0x150,
        82 => 0x148,
        83 => 0x45,
        84 => 0x135,
        85 => 0x37,
        86 => 0x4a,
        87 => 0x4e,
        88 => 0x11c,
        89..=97 => [0x4f, 0x50, 0x51, 0x4b, 0x4c, 0x4d, 0x47, 0x48, 0x49][(hid - 89) as usize],
        98 => 0x52,
        99 => 0x53,
        100 => 0x56,
        101 => 0x15d,
        224 => 0x1d,
        225 => 0x2a,
        226 => 0x38,
        227 => 0x15b,
        228 => 0x11d,
        229 => 0x36,
        230 => 0x138,
        231 => 0x15c,
        _ => return None,
    })
}
impl InputInjector {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn key(&mut self, hid: u16, down: bool) -> Result<()> {
        let scan = hid_scan(hid).ok_or_else(|| anyhow::anyhow!("Unsupported HID key {hid}"))?;
        if down == self.keys.contains(&hid) {
            return Ok(());
        }
        let mut flags = KEYEVENTF_SCANCODE;
        if scan & 0x100 != 0 {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }
        if !down {
            flags |= KEYEVENTF_KEYUP;
        }
        if hid == 72 {
            virtual_pause(down)?;
        } else {
            keyboard(scan & 0xff, flags)?;
        }
        if down {
            self.keys.insert(hid);
        } else {
            self.keys.remove(&hid);
        }
        Ok(())
    }
    pub fn key_repeat(&mut self, hid: u16) -> Result<()> {
        if !self.keys.contains(&hid) {
            return self.key(hid, true);
        }
        let scan = hid_scan(hid).ok_or_else(|| anyhow::anyhow!("Unsupported HID key {hid}"))?;
        let mut flags = KEYEVENTF_SCANCODE;
        if scan & 0x100 != 0 {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }
        if hid == 72 {
            virtual_pause(true)
        } else {
            keyboard(scan & 0xff, flags)
        }
    }
    pub fn text(&mut self, text: &str) -> Result<()> {
        ensure!(text.len() <= 16384, "Text input too long");
        for unit in text.encode_utf16() {
            keyboard(unit, KEYEVENTF_UNICODE)?;
            keyboard(unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)?;
        }
        Ok(())
    }
    pub fn refresh_displays(&mut self) -> Result<()> {
        self.displays = crate::enumerate_displays()?
            .into_iter()
            .map(|d| (d.id, d))
            .collect();
        self.last_display_refresh = Some(Instant::now());
        Ok(())
    }
    pub fn pointer(&mut self, display_id: u32, x: f64, y: f64) -> Result<()> {
        ensure!(x.is_finite() && y.is_finite(), "Non-finite pointer");
        let _coordinates = PhysicalCoordinates::enter()?;
        if !self.displays.contains_key(&display_id)
            || self
                .last_display_refresh
                .is_none_or(|last| last.elapsed() >= Duration::from_secs(1))
        {
            self.refresh_displays()?;
        }
        let d = self
            .displays
            .get(&display_id)
            .ok_or_else(|| anyhow::anyhow!("Display not available"))?;
        unsafe {
            let left = GetSystemMetrics(SM_XVIRTUALSCREEN);
            let top = GetSystemMetrics(SM_YVIRTUALSCREEN);
            let width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
            let height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
            ensure!(width > 1 && height > 1, "Desktop unavailable");
            let px = d.x as f64 + x.clamp(0., 1.) * (d.width - 1) as f64;
            let py = d.y as f64 + y.clamp(0., 1.) * (d.height - 1) as f64;
            mouse(
                MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                ((px - left as f64) * 65535. / (width - 1) as f64).round() as i32,
                ((py - top as f64) * 65535. / (height - 1) as f64).round() as i32,
                0,
            )
        }
    }
    pub fn button(&mut self, button: u8, down: bool) -> Result<()> {
        if down == self.buttons.contains(&button) {
            return Ok(());
        }
        let (flag, data) = match (button, down) {
            (0, true) => (MOUSEEVENTF_LEFTDOWN, 0),
            (0, false) => (MOUSEEVENTF_LEFTUP, 0),
            (1, true) => (MOUSEEVENTF_RIGHTDOWN, 0),
            (1, false) => (MOUSEEVENTF_RIGHTUP, 0),
            (2, true) => (MOUSEEVENTF_MIDDLEDOWN, 0),
            (2, false) => (MOUSEEVENTF_MIDDLEUP, 0),
            (3 | 4, true) => (MOUSEEVENTF_XDOWN, (button - 2) as u32),
            (3 | 4, false) => (MOUSEEVENTF_XUP, (button - 2) as u32),
            _ => bail!("Unsupported mouse button"),
        };
        mouse(flag, 0, 0, data)?;
        if down {
            self.buttons.insert(button);
        } else {
            self.buttons.remove(&button);
        }
        Ok(())
    }
    pub fn scroll(&mut self, x: f64, y: f64) -> Result<()> {
        ensure!(x.is_finite() && y.is_finite(), "Non-finite scroll");
        for (value, flag) in [(x, MOUSEEVENTF_HWHEEL), (y, MOUSEEVENTF_WHEEL)] {
            if value != 0. {
                mouse(
                    flag,
                    0,
                    0,
                    (value.clamp(-100., 100.) * 120.).round() as i32 as u32,
                )?;
            }
        }
        Ok(())
    }
    pub fn release_all(&mut self) {
        for key in self.keys.clone() {
            let _ = self.key(key, false);
        }
        for button in self.buttons.clone() {
            let _ = self.button(button, false);
        }
    }
}
impl Drop for InputInjector {
    fn drop(&mut self) {
        self.release_all();
    }
}
#[cfg(test)]
mod tests {
    #[test]
    fn hid_mapping() {
        assert_eq!(super::hid_scan(4), Some(0x1e));
        assert_eq!(super::hid_scan(228), Some(0x11d));
        assert_eq!(super::hid_scan(300), None);
    }
}

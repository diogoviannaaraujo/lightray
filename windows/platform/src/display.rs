use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use windows::{
    core::PCWSTR,
    Win32::{
        Graphics::{Dxgi::*, Gdi::*},
        UI::WindowsAndMessaging::MONITORINFOF_PRIMARY,
    },
};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Display {
    pub id: u32,
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub refresh_millihz: u32,
    pub primary: bool,
}

pub(crate) struct Output {
    pub display: Display,
    pub adapter: IDXGIAdapter1,
    pub monitor: HMONITOR,
}

pub(crate) fn outputs() -> Result<Vec<Output>> {
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1()?;
        let mut values = Vec::new();
        let mut adapter_index = 0;
        while let Ok(adapter) = factory.EnumAdapters1(adapter_index) {
            adapter_index += 1;
            let desc = adapter.GetDesc1()?;
            if desc.VendorId != 0x10de {
                continue;
            }
            let mut output_index = 0;
            while let Ok(output) = adapter.EnumOutputs(output_index) {
                output_index += 1;
                let desc = output.GetDesc()?;
                if !desc.AttachedToDesktop.as_bool() {
                    continue;
                }
                let mut mode = DEVMODEW {
                    dmSize: std::mem::size_of::<DEVMODEW>() as u16,
                    ..Default::default()
                };
                let refresh = if EnumDisplaySettingsExW(
                    PCWSTR(desc.DeviceName.as_ptr()),
                    ENUM_CURRENT_SETTINGS,
                    &mut mode,
                    ENUM_DISPLAY_SETTINGS_FLAGS(0),
                )
                .as_bool()
                {
                    mode.dmDisplayFrequency.saturating_mul(1000)
                } else {
                    60000
                };
                let mut info = MONITORINFO {
                    cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                    ..Default::default()
                };
                GetMonitorInfoW(desc.Monitor, &mut info).ok()?;
                let name = String::from_utf16_lossy(
                    &desc.DeviceName[..desc
                        .DeviceName
                        .iter()
                        .position(|x| *x == 0)
                        .unwrap_or(desc.DeviceName.len())],
                );
                // DISPLAYn remains stable while adapters are enumerated differently after driver updates.
                let id = name
                    .chars()
                    .filter(char::is_ascii_digit)
                    .collect::<String>()
                    .parse()
                    .unwrap_or((adapter_index << 16) | output_index);
                let rect = desc.DesktopCoordinates;
                values.push(Output {
                    display: Display {
                        id,
                        name,
                        x: rect.left,
                        y: rect.top,
                        width: (rect.right - rect.left) as u32,
                        height: (rect.bottom - rect.top) as u32,
                        refresh_millihz: refresh,
                        primary: info.dwFlags & MONITORINFOF_PRIMARY != 0,
                    },
                    adapter: adapter.clone(),
                    monitor: desc.Monitor,
                });
            }
        }
        if values.len() > 32 {
            bail!("Display enumeration exceeded 32 outputs");
        }
        Ok(values)
    }
}
pub fn enumerate_displays() -> Result<Vec<Display>> {
    Ok(outputs()?.into_iter().map(|o| o.display).collect())
}

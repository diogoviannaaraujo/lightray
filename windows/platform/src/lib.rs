#![cfg(windows)]
pub mod display;
pub mod input;
pub mod media;
pub mod secrets;
pub use display::{enumerate_displays, Display};
pub use input::InputInjector;
pub use media::{CaptureEncoder, DecoderRenderer, EncodedFrame, MediaTimings, VideoConfig};
/// False on the secure desktop, lock screen, or when access to the input desktop is denied.
pub fn is_desktop_available() -> bool {
    use windows::Win32::{Foundation::HANDLE, System::StationsAndDesktops::*};
    unsafe {
        let desktop = match OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS) {
            Ok(value) => value,
            Err(_) => return false,
        };
        let mut name = [0u16; 256];
        let available = GetUserObjectInformationW(
            HANDLE(desktop.0),
            UOI_NAME,
            Some(name.as_mut_ptr().cast()),
            std::mem::size_of_val(&name) as u32,
            None,
        )
        .is_ok()
            && String::from_utf16_lossy(
                &name[..name.iter().position(|v| *v == 0).unwrap_or(name.len())],
            )
            .eq_ignore_ascii_case("Default");
        let _ = CloseDesktop(desktop);
        available
    }
}
pub use secrets::{protect, unprotect};

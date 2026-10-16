//! C ABI v1: opaque integer handles, copied UTF-8 JSON, and explicit COM ownership.
use crate::engine::{Command, EngineHandle};
use serde_json::Value;
use std::{
    collections::HashMap,
    ffi::c_void,
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Duration,
};

const INVALID: i32 = -1;
const BUSY: i32 = -2;
const LIMIT: usize = 1024 * 1024;
static NEXT: AtomicU64 = AtomicU64::new(1);
static HANDLES: OnceLock<Mutex<HashMap<u64, Arc<EngineHandle>>>> = OnceLock::new();
fn handles() -> &'static Mutex<HashMap<u64, Arc<EngineHandle>>> {
    HANDLES.get_or_init(Mutex::default)
}
fn lookup(id: u64) -> Option<Arc<EngineHandle>> {
    handles().lock().ok()?.get(&id).cloned()
}
fn guarded(f: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(INVALID)
}

#[no_mangle]
pub extern "C" fn lr_abi_version() -> u32 {
    1
}
#[no_mangle]
pub extern "C" fn lr_create(role: u32) -> u64 {
    catch_unwind(AssertUnwindSafe(|| {
        if role != 1 && role != 2 {
            return 0;
        }
        let mut registry = match handles().lock() {
            Ok(value) => value,
            Err(_) => return 0,
        };
        if registry.len() >= 32 {
            return 0;
        }
        let engine = match crate::engine::spawn(role) {
            Ok(value) => value,
            Err(_) => return 0,
        };
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        registry.insert(id, Arc::new(engine));
        id
    }))
    .unwrap_or(0)
}

/// JSON buffer is borrowed only until return. The engine owns its parsed copy.
/// # Safety
/// `json` must point to `length` readable bytes for this call.
#[no_mangle]
pub unsafe extern "C" fn lr_command(id: u64, json: *const u8, length: u32) -> i32 {
    guarded(|| {
        if json.is_null() || length == 0 || length as usize > 65536 {
            return INVALID;
        }
        let Some(engine) = lookup(id) else {
            return INVALID;
        };
        let Ok(value) =
            serde_json::from_slice::<Value>(std::slice::from_raw_parts(json, length as usize))
        else {
            return INVALID;
        };
        if !value.is_object() {
            return INVALID;
        }
        if engine.sender.try_send(Command::Json(value)).is_err() {
            engine.safety_trip.store(true, Ordering::Release);
            return BUSY;
        }
        0
    })
}

/// 0: copied one event, 1: empty, 2: capacity too small (event retained), negative: invalid.
/// # Safety
/// `buffer` must be writable for `capacity` bytes and `length` for one u32.
#[no_mangle]
pub unsafe extern "C" fn lr_poll(id: u64, buffer: *mut u8, capacity: u32, length: *mut u32) -> i32 {
    guarded(|| {
        if buffer.is_null() || length.is_null() || capacity as usize > LIMIT {
            return INVALID;
        }
        *length = 0;
        let Some(engine) = lookup(id) else {
            return INVALID;
        };
        let Ok(mut events) = engine.events.lock() else {
            return INVALID;
        };
        let Some(event) = events.front() else {
            return 1;
        };
        let Ok(bytes) = serde_json::to_vec(event) else {
            return INVALID;
        };
        *length = bytes.len() as u32;
        if bytes.len() > capacity as usize {
            return 2;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len());
        events.pop_front();
        0
    })
}

/// Returns one AddRef'd IDXGISwapChain pointer. The caller must Release it after UI attachment.
#[no_mangle]
pub extern "C" fn lr_swap_chain(id: u64, stream: u8) -> *mut c_void {
    catch_unwind(AssertUnwindSafe(|| {
        let engine = lookup(id)?;
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        engine
            .sender
            .try_send(Command::SwapChain { stream, reply: tx })
            .ok()?;
        rx.recv_timeout(Duration::from_secs(2))
            .ok()
            .map(|value| value as *mut c_void)
    }))
    .ok()
    .flatten()
    .unwrap_or(std::ptr::null_mut())
}
#[no_mangle]
pub extern "C" fn lr_resize(id: u64, stream: u8, width: u32, height: u32) -> i32 {
    guarded(|| {
        if width == 0 || height == 0 || width > 16384 || height > 16384 {
            return INVALID;
        }
        let Some(engine) = lookup(id) else {
            return INVALID;
        };
        if engine
            .sender
            .try_send(Command::Resize {
                stream,
                width,
                height,
            })
            .is_ok()
        {
            0
        } else {
            BUSY
        }
    })
}
#[no_mangle]
pub extern "C" fn lr_destroy(id: u64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let engine = handles()
            .lock()
            .ok()
            .and_then(|mut registry| registry.remove(&id));
        if let Some(engine) = engine {
            engine.stop();
        }
    }));
}

pub fn smoke() -> anyhow::Result<()> {
    use anyhow::ensure;
    let id = lr_create(2);
    ensure!(id != 0, "Unable to create client engine");
    struct Cleanup(u64);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            lr_destroy(self.0);
        }
    }
    let _cleanup = Cleanup(id);
    let command = br#"{"command":"computers"}"#;
    ensure!(
        unsafe { lr_command(id, command.as_ptr(), command.len() as u32) } == 0,
        "Command rejected"
    );
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let mut byte = [0u8];
    let mut needed = 0;
    loop {
        let status = unsafe { lr_poll(id, byte.as_mut_ptr(), 1, &mut needed) };
        if status == 2 {
            break;
        }
        ensure!(status == 1, "Unexpected poll result");
        ensure!(std::time::Instant::now() < deadline, "Event timed out");
        std::thread::sleep(Duration::from_millis(10));
    }
    ensure!(
        needed > 1 && needed as usize <= LIMIT,
        "Invalid required event size"
    );
    let mut buffer = vec![0u8; needed as usize];
    ensure!(
        unsafe { lr_poll(id, buffer.as_mut_ptr(), buffer.len() as u32, &mut needed) } == 0,
        "Event lost during capacity negotiation"
    );
    let event: Value = serde_json::from_slice(&buffer)?;
    ensure!(event["kind"] == "computers", "Unexpected engine event");
    lr_destroy(id);
    ensure!(
        lr_resize(id, 1, 640, 480) == INVALID,
        "Destroyed handle remained valid"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn abi_rejects_invalid_versions_handles_and_buffers() {
        assert_eq!(lr_abi_version(), 1);
        assert_eq!(lr_create(99), 0);
        assert_eq!(unsafe { lr_command(999, std::ptr::null(), 0) }, INVALID);
        assert!(lr_swap_chain(999, 1).is_null());
        assert_eq!(lr_resize(999, 1, 0, 0), INVALID);
        lr_destroy(999);
    }
    #[test]
    fn abi_owned_handle_lifetime_and_capacity_negotiation() {
        smoke().unwrap();
    }
}

//! Current-user login agent and local, SID/session-restricted control channel.
use anyhow::{bail, Context, Result};
use serde_json::Value;
use std::{
    ffi::c_void,
    path::PathBuf,
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    thread,
    time::{Duration, Instant},
};

type Handle = *mut c_void;
const INVALID_HANDLE: Handle = -1isize as Handle;
#[repr(C)]
struct SecurityAttributes {
    length: u32,
    descriptor: *mut c_void,
    inherit: i32,
}
#[repr(C)]
struct TokenUser {
    sid: *mut c_void,
    attributes: u32,
}
#[link(name = "kernel32")]
extern "system" {
    fn GetCurrentProcess() -> Handle;
    fn GetCurrentProcessId() -> u32;
    fn ProcessIdToSessionId(process: u32, session: *mut u32) -> i32;
    fn CloseHandle(handle: Handle) -> i32;
    fn LocalFree(memory: Handle) -> Handle;
    fn CreateNamedPipeW(
        name: *const u16,
        access: u32,
        mode: u32,
        instances: u32,
        out_size: u32,
        in_size: u32,
        timeout: u32,
        attributes: *const SecurityAttributes,
    ) -> Handle;
    fn ConnectNamedPipe(pipe: Handle, overlapped: Handle) -> i32;
    fn DisconnectNamedPipe(pipe: Handle) -> i32;
    fn GetNamedPipeClientProcessId(pipe: Handle, process: *mut u32) -> i32;
    fn CreateFileW(
        name: *const u16,
        access: u32,
        share: u32,
        attributes: Handle,
        creation: u32,
        flags: u32,
        template: Handle,
    ) -> Handle;
    fn SetNamedPipeHandleState(
        pipe: Handle,
        mode: *const u32,
        count: *const u32,
        timeout: *const u32,
    ) -> i32;
    fn ReadFile(
        handle: Handle,
        buffer: *mut u8,
        size: u32,
        read: *mut u32,
        overlapped: Handle,
    ) -> i32;
    fn WriteFile(
        handle: Handle,
        buffer: *const u8,
        size: u32,
        written: *mut u32,
        overlapped: Handle,
    ) -> i32;
}
#[link(name = "advapi32")]
extern "system" {
    fn OpenProcessToken(process: Handle, access: u32, token: *mut Handle) -> i32;
    fn GetTokenInformation(
        token: Handle,
        class: u32,
        buffer: Handle,
        size: u32,
        needed: *mut u32,
    ) -> i32;
    fn ConvertSidToStringSidW(sid: Handle, text: *mut *mut u16) -> i32;
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text: *const u16,
        revision: u32,
        descriptor: *mut Handle,
        size: *mut u32,
    ) -> i32;
}
struct OwnedHandle(Handle);
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}
fn os_error() -> anyhow::Error {
    std::io::Error::last_os_error().into()
}
pub fn identity() -> Result<(String, u32)> {
    unsafe {
        let mut raw = ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), 8, &mut raw) == 0 {
            return Err(os_error());
        }
        let token = OwnedHandle(raw);
        let mut needed = 0;
        GetTokenInformation(token.0, 1, ptr::null_mut(), 0, &mut needed);
        let mut buffer = vec![0u8; needed as usize];
        if GetTokenInformation(token.0, 1, buffer.as_mut_ptr().cast(), needed, &mut needed) == 0 {
            return Err(os_error());
        }
        let user = ptr::read_unaligned(buffer.as_ptr().cast::<TokenUser>());
        let mut text = ptr::null_mut();
        if ConvertSidToStringSidW(user.sid, &mut text) == 0 {
            return Err(os_error());
        }
        let mut len = 0;
        while *text.add(len) != 0 {
            len += 1;
        }
        let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, len));
        LocalFree(text.cast());
        let mut session = 0;
        if ProcessIdToSessionId(GetCurrentProcessId(), &mut session) == 0 {
            return Err(os_error());
        }
        Ok((sid, session))
    }
}
fn pipe_name() -> Result<String> {
    let (sid, session) = identity()?;
    Ok(format!(r"\\.\pipe\Lightray.Host.{sid}.{session}"))
}
const MAX_MESSAGE: usize = 65536;
fn read_frame(handle: Handle, deadline: Instant) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    let mut length = None;
    loop {
        if Instant::now() >= deadline {
            bail!("Host control request timed out");
        }
        let mut buffer = [0u8; 4096];
        let mut read = 0;
        let ok = unsafe {
            ReadFile(
                handle,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
                &mut read,
                ptr::null_mut(),
            )
        };
        if ok == 0 {
            let error = std::io::Error::last_os_error();
            if matches!(error.raw_os_error(), Some(232) | Some(536)) {
                thread::sleep(Duration::from_millis(5));
                continue;
            }
            return Err(error.into());
        }
        if read == 0 {
            thread::sleep(Duration::from_millis(5));
            continue;
        }
        bytes.extend_from_slice(&buffer[..read as usize]);
        if bytes.len() >= 4 && length.is_none() {
            let size = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
            if size == 0 || size > MAX_MESSAGE {
                bail!("Invalid control message length");
            }
            length = Some(size);
        }
        if let Some(length) = length {
            if bytes.len() >= length + 4 {
                if bytes.len() != length + 4 {
                    bail!("Unexpected control message tail");
                }
                return Ok(bytes.split_off(4));
            }
        }
    }
}
fn write_frame(handle: Handle, value: &Value) -> Result<()> {
    let bytes = serde_json::to_vec(value)?;
    if bytes.is_empty() || bytes.len() > MAX_MESSAGE {
        bail!("Control message is too large");
    }
    let mut frame = (bytes.len() as u32).to_le_bytes().to_vec();
    frame.extend(bytes);
    let mut written = 0;
    if unsafe {
        WriteFile(
            handle,
            frame.as_ptr(),
            frame.len() as u32,
            &mut written,
            ptr::null_mut(),
        )
    } == 0
        || written as usize != frame.len()
    {
        bail!("Unable to write control message");
    }
    Ok(())
}
pub fn request(value: &Value) -> Result<Value> {
    request_at(&pipe_name()?, value)
}
fn request_at(pipe_name: &str, value: &Value) -> Result<Value> {
    let name = wide(pipe_name);
    let deadline = Instant::now() + Duration::from_secs(2);
    let raw = loop {
        let raw = unsafe {
            CreateFileW(
                name.as_ptr(),
                0xc0000000,
                0,
                ptr::null_mut(),
                3,
                0,
                ptr::null_mut(),
            )
        };
        if raw != INVALID_HANDLE {
            break raw;
        }
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(231) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
            continue;
        }
        return Err(error).context("Host agent is not running or is busy");
    };
    let pipe = OwnedHandle(raw);
    let mode = 1u32;
    if unsafe { SetNamedPipeHandleState(pipe.0, &mode, ptr::null(), ptr::null()) } == 0 {
        return Err(os_error());
    }
    write_frame(pipe.0, value)?;
    Ok(serde_json::from_slice(&read_frame(
        pipe.0,
        Instant::now() + Duration::from_secs(3),
    )?)?)
}
pub struct ControlRequest {
    pub message: Value,
    pub reply: mpsc::SyncSender<Value>,
}
pub fn serve(
    stop: Arc<AtomicBool>,
    sender: mpsc::SyncSender<ControlRequest>,
) -> Result<thread::JoinHandle<()>> {
    serve_at(stop, sender, &pipe_name()?)
}
fn serve_at(
    stop: Arc<AtomicBool>,
    sender: mpsc::SyncSender<ControlRequest>,
    pipe_name: &str,
) -> Result<thread::JoinHandle<()>> {
    let (sid, session) = identity()?;
    let name = wide(pipe_name);
    let sddl = wide(&format!("D:P(A;;GA;;;{sid})"));
    let raw = unsafe {
        let mut descriptor = ptr::null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            ptr::null_mut(),
        ) == 0
        {
            return Err(os_error());
        }
        let attrs = SecurityAttributes {
            length: std::mem::size_of::<SecurityAttributes>() as u32,
            descriptor,
            inherit: 0,
        };
        // FIRST_PIPE_INSTANCE prevents a second host from taking over this control endpoint.
        let raw = CreateNamedPipeW(
            name.as_ptr(),
            3 | 0x00080000,
            1 | 8,
            1,
            MAX_MESSAGE as u32 + 4,
            MAX_MESSAGE as u32 + 4,
            1000,
            &attrs,
        );
        LocalFree(descriptor);
        raw
    };
    if raw == INVALID_HANDLE {
        return Err(os_error()).context("Another host agent is already running");
    }
    let raw = raw as usize;
    Ok(thread::spawn(move || {
        let pipe = OwnedHandle(raw as Handle);
        while !stop.load(Ordering::Acquire) {
            if unsafe { ConnectNamedPipe(pipe.0, ptr::null_mut()) } == 0 {
                let error = std::io::Error::last_os_error();
                if matches!(error.raw_os_error(), Some(232) | Some(233) | Some(109)) {
                    // A client may close before the nonblocking listener accepts it.
                    // Reset that disconnected instance or every future client sees PIPE_BUSY.
                    unsafe {
                        DisconnectNamedPipe(pipe.0);
                    }
                }
                if error.raw_os_error() != Some(535) {
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
            }
            let mut process = 0;
            let mut peer_session = u32::MAX;
            let allowed = unsafe {
                GetNamedPipeClientProcessId(pipe.0, &mut process) != 0
                    && ProcessIdToSessionId(process, &mut peer_session) != 0
                    && peer_session == session
            };
            if allowed {
                let result = (|| -> Result<()> {
                    let data = read_frame(pipe.0, Instant::now() + Duration::from_secs(2))?;
                    let message: Value = serde_json::from_slice(&data)?;
                    if message.get("version").and_then(Value::as_u64).unwrap_or(1) != 1 {
                        bail!("Unsupported host control version");
                    }
                    let (tx, rx) = mpsc::sync_channel(1);
                    sender
                        .try_send(ControlRequest { message, reply: tx })
                        .context("Host control queue full")?;
                    let response = rx
                        .recv_timeout(Duration::from_secs(3))
                        .context("Host is busy")?;
                    write_frame(pipe.0, &response)
                })();
                if let Err(error) = result {
                    let _ = write_frame(
                        pipe.0,
                        &serde_json::json!({"ok":false,"error":error.to_string()}),
                    );
                }
                // Give the nonblocking client a chance to consume the buffered reply.
                thread::sleep(Duration::from_millis(20));
            }
            unsafe {
                DisconnectNamedPipe(pipe.0);
            }
        }
    }))
}
pub fn agent_path() -> Result<PathBuf> {
    Ok(std::env::current_exe()?
        .parent()
        .context("Application directory unavailable")?
        .join("lightray-host-agent.exe"))
}
fn ps_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}
fn powershell(script: String) -> Result<()> {
    use std::os::windows::process::CommandExt;
    let output = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(0x08000000)
        .output()?;
    if !output.status.success() {
        bail!(
            "Login task: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(())
}
pub fn enable() -> Result<()> {
    use std::os::windows::process::CommandExt;
    let executable = agent_path()?;
    if !executable.is_file() {
        bail!("Host agent executable is missing from this installation");
    }
    let (sid, _) = identity()?;
    powershell(format!("$ErrorActionPreference='Stop'; $user=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name; $action=New-ScheduledTaskAction -Execute {} -Argument '--service'; $trigger=New-ScheduledTaskTrigger -AtLogOn -User $user; $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited; $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries; Register-ScheduledTask -TaskName {} -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null", ps_literal(&executable.to_string_lossy()), ps_literal(&format!("Lightray Host {sid}"))))?;
    if request(&serde_json::json!({"command":"status"})).is_err() {
        std::process::Command::new(executable)
            .arg("--service")
            .creation_flags(0x08000000)
            .spawn()?;
    }
    Ok(())
}
pub fn disable() -> Result<()> {
    let (sid, _) = identity()?;
    powershell(format!("$ErrorActionPreference='Stop'; $task=Get-ScheduledTask -TaskName {} -ErrorAction SilentlyContinue; if ($task) {{ Unregister-ScheduledTask -InputObject $task -Confirm:$false }}", ps_literal(&format!("Lightray Host {sid}"))))?;
    // An absent agent is already stopped; other failures remain visible to the caller.
    if let Ok(reply) = request(&serde_json::json!({"command":"stop"})) {
        if reply.get("ok") == Some(&Value::Bool(false)) {
            bail!("Host agent refused to stop");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn current_identity_is_real_and_scoped() {
        let (sid, session) = identity().unwrap();
        assert!(sid.starts_with("S-1-"));
        assert!(pipe_name().unwrap().ends_with(&format!(".{session}")));
    }
    #[test]
    fn task_arguments_quote_paths() {
        assert_eq!(ps_literal("a'b"), "'a''b'");
    }
    #[test]
    fn abandoned_pipe_client_cannot_poison_future_control_requests() {
        let name = format!(
            r"\\.\pipe\Lightray.Test.{}.{}",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        );
        let stop = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::sync_channel::<ControlRequest>(4);
        let server = serve_at(stop.clone(), tx, &name).unwrap();
        let raw_name = wide(&name);
        let raw = unsafe {
            CreateFileW(
                raw_name.as_ptr(),
                0xc0000000,
                0,
                ptr::null_mut(),
                3,
                0,
                ptr::null_mut(),
            )
        };
        assert_ne!(raw, INVALID_HANDLE);
        drop(OwnedHandle(raw));
        let handler = thread::spawn(move || {
            if let Ok(request) = rx.recv_timeout(Duration::from_secs(7)) {
                assert_eq!(request.message["command"], "status");
                let _ = request.reply.send(serde_json::json!({"ok":true}));
            }
        });
        let result = request_at(&name, &serde_json::json!({"command":"status"}));
        stop.store(true, Ordering::Release);
        let _ = server.join();
        let _ = handler.join();
        assert_eq!(result.unwrap()["ok"], true);
    }
}

//! Opt-in acceptance test for the real current-user host lifecycle.
//!
//! Run only through `lightray-check --service-smoke`. Pre-existing login tasks or
//! agents are never stopped or replaced. All settings and credentials created by
//! this test stay under its unique `target/acceptance` directory.
use crate::{abi, service, settings::HostSettings};
use anyhow::{bail, ensure, Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::os::windows::process::CommandExt;
use std::{
    ffi::{c_void, OsString},
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const CREATE_NO_WINDOW: u32 = 0x08000000;
type Handle = *mut c_void;
#[link(name = "kernel32")]
extern "system" {
    fn CreateFileW(
        name: *const u16,
        access: u32,
        share: u32,
        security: Handle,
        creation: u32,
        flags: u32,
        template: Handle,
    ) -> Handle;
    fn GetNamedPipeServerProcessId(pipe: Handle, pid: *mut u32) -> i32;
    fn SetNamedPipeHandleState(
        pipe: Handle,
        mode: *const u32,
        count: *const u32,
        timeout: *const u32,
    ) -> i32;
    fn WriteFile(
        handle: Handle,
        buffer: *const u8,
        size: u32,
        written: *mut u32,
        overlapped: Handle,
    ) -> i32;
    fn ReadFile(
        handle: Handle,
        buffer: *mut u8,
        size: u32,
        read: *mut u32,
        overlapped: Handle,
    ) -> i32;
    fn CloseHandle(handle: Handle) -> i32;
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> Handle;
    fn WaitForSingleObject(handle: Handle, millis: u32) -> u32;
    fn TerminateProcess(handle: Handle, exit_code: u32) -> i32;
}
struct OwnedHandle(Handle);
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
fn ps_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}
fn powershell(script: &str) -> Result<String> {
    let script =
        format!("[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); {script}");
    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(CREATE_NO_WINDOW)
        .output()?;
    ensure!(
        output.status.success(),
        "Acceptance PowerShell: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(String::from_utf8(output.stdout)?
        .trim()
        .trim_start_matches('\u{feff}')
        .to_owned())
}
#[derive(Clone, Debug, Deserialize)]
struct TaskRecord {
    name: String,
    path: String,
    execute: String,
    arguments: String,
    action_count: usize,
}
fn task_record(name: &str) -> Result<Option<TaskRecord>> {
    let script=format!("$ErrorActionPreference='Stop'; $t=Get-ScheduledTask -TaskName {} -ErrorAction SilentlyContinue; if ($null -eq $t) {{ 'null'; exit 0 }}; [ordered]@{{ name=$t.TaskName; path=$t.TaskPath; execute=[string]$t.Actions[0].Execute; arguments=[string]$t.Actions[0].Arguments; action_count=@($t.Actions).Count }} | ConvertTo-Json -Compress",ps_literal(name));
    Ok(serde_json::from_str(&powershell(&script)?)?)
}
fn canonical_text(path: &Path) -> String {
    std::fs::canonicalize(path)
        .unwrap_or_else(|_| path.to_owned())
        .to_string_lossy()
        .trim_start_matches(r"\\?\")
        .to_ascii_lowercase()
}
fn is_test_task(record: &TaskRecord, name: &str, executable: &Path) -> bool {
    record.name == name
        && record.path == r"\"
        && record.action_count == 1
        && record.arguments.trim() == "--service"
        && canonical_text(Path::new(&record.execute)) == canonical_text(executable)
}
fn pipe_server_pid() -> Result<Option<u32>> {
    let (sid, session) = service::identity()?;
    let name = format!(r"\\.\pipe\Lightray.Host.{sid}.{session}");
    let name: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        unsafe {
            let raw = CreateFileW(
                name.as_ptr(),
                0xc0000000,
                0,
                std::ptr::null_mut(),
                3,
                0,
                std::ptr::null_mut(),
            );
            if raw == -1isize as Handle {
                let error = std::io::Error::last_os_error();
                if matches!(error.raw_os_error(), Some(2) | Some(3)) {
                    return Ok(None);
                }
                if error.raw_os_error() == Some(231) && Instant::now() < deadline {
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
                return Err(error.into());
            }
            let pipe = OwnedHandle(raw);
            let mut pid = 0;
            ensure!(
                GetNamedPipeServerProcessId(pipe.0, &mut pid) != 0,
                "Cannot identify the host pipe server: {}",
                std::io::Error::last_os_error()
            );
            // Complete a normal read-only request. Opening and closing without
            // a frame leaves the server waiting for its two-second deadline.
            let mode = 1u32;
            ensure!(
                SetNamedPipeHandleState(pipe.0, &mode, std::ptr::null(), std::ptr::null()) != 0,
                "Cannot select nonblocking control mode"
            );
            let payload = br#"{"command":"status"}"#;
            let mut frame = (payload.len() as u32).to_le_bytes().to_vec();
            frame.extend_from_slice(payload);
            let mut written = 0;
            ensure!(
                WriteFile(
                    pipe.0,
                    frame.as_ptr(),
                    frame.len() as u32,
                    &mut written,
                    std::ptr::null_mut()
                ) != 0
                    && written as usize == frame.len(),
                "Cannot write the read-only ownership request"
            );
            let read_deadline = Instant::now() + Duration::from_secs(3);
            let mut response = Vec::new();
            loop {
                ensure!(
                    Instant::now() < read_deadline,
                    "Read-only ownership request timed out"
                );
                let mut buffer = [0u8; 4096];
                let mut length = 0;
                if ReadFile(
                    pipe.0,
                    buffer.as_mut_ptr(),
                    buffer.len() as u32,
                    &mut length,
                    std::ptr::null_mut(),
                ) == 0
                {
                    let error = std::io::Error::last_os_error();
                    if matches!(error.raw_os_error(), Some(232) | Some(536)) {
                        thread::sleep(Duration::from_millis(5));
                        continue;
                    }
                    return Err(error.into());
                }
                response.extend_from_slice(&buffer[..length as usize]);
                ensure!(response.len() <= 65540, "Oversized ownership status reply");
                if response.len() >= 4 {
                    let expected = u32::from_le_bytes(response[..4].try_into()?) as usize;
                    ensure!(
                        expected > 0 && expected <= 65536,
                        "Invalid ownership status reply length"
                    );
                    if response.len() == expected + 4 {
                        let _: Value = serde_json::from_slice(&response[4..])?;
                        break;
                    }
                }
                thread::sleep(Duration::from_millis(5));
            }
            drop(pipe);
            thread::sleep(Duration::from_millis(35));
            return Ok(Some(pid));
        }
    }
}
#[derive(Deserialize)]
struct ProcessRecord {
    parent: u32,
    executable: String,
}
fn our_agent_pids(executable: &Path) -> Result<Vec<u32>> {
    #[derive(Deserialize)]
    struct Candidate {
        pid: u32,
        executable: String,
    }
    let script=format!("$ErrorActionPreference='Stop'; $p=@(Get-CimInstance Win32_Process -Filter 'ParentProcessId={}' | ForEach-Object {{[ordered]@{{pid=[uint32]$_.ProcessId;executable=[string]$_.ExecutablePath}}}}); ConvertTo-Json -InputObject $p -Compress",std::process::id());
    let candidates: Vec<Candidate> = serde_json::from_str(&powershell(&script)?)?;
    Ok(candidates
        .into_iter()
        .filter(|p| canonical_text(Path::new(&p.executable)) == canonical_text(executable))
        .map(|p| p.pid)
        .collect())
}
fn is_our_agent(pid: u32, executable: &Path) -> Result<bool> {
    let script=format!("$ErrorActionPreference='Stop'; $p=Get-CimInstance Win32_Process -Filter 'ProcessId={pid}'; if ($null -eq $p) {{ 'null'; exit 0 }}; [ordered]@{{parent=[uint32]$p.ParentProcessId;executable=[string]$p.ExecutablePath}}|ConvertTo-Json -Compress");
    let process: Option<ProcessRecord> = serde_json::from_str(&powershell(&script)?)?;
    Ok(process.is_some_and(|p| {
        p.parent == std::process::id()
            && canonical_text(Path::new(&p.executable)) == canonical_text(executable)
    }))
}
fn process_alive(pid: u32) -> Result<bool> {
    unsafe {
        let raw = OpenProcess(0x00100000, 0, pid);
        if raw.is_null() {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(87) {
                return Ok(false);
            }
            return Err(error.into());
        }
        let handle = OwnedHandle(raw);
        match WaitForSingleObject(handle.0, 0) {
            0 => Ok(false),
            258 => Ok(true),
            _ => Err(std::io::Error::last_os_error().into()),
        }
    }
}
fn terminate_test_owned_agent(pid: u32, executable: &Path) -> Result<()> {
    if !process_alive(pid)? {
        return Ok(());
    }
    ensure!(
        is_our_agent(pid, executable)?,
        "Cleanup refuses to terminate a process not owned by this acceptance run"
    );
    unsafe {
        let raw = OpenProcess(0x00100001, 0, pid);
        ensure!(
            !raw.is_null(),
            "Cannot open the verified test-owned agent for cleanup"
        );
        let process = OwnedHandle(raw);
        ensure!(
            TerminateProcess(process.0, 1) != 0,
            "Cannot terminate the verified test-owned agent: {}",
            std::io::Error::last_os_error()
        );
        ensure!(
            WaitForSingleObject(process.0, 5000) == 0,
            "Verified test-owned agent did not terminate"
        );
    }
    Ok(())
}
struct UiHandle(u64);
impl UiHandle {
    fn new() -> Result<Self> {
        let id = abi::lr_create(1);
        ensure!(id != 0, "Unable to create the host settings ABI handle");
        Ok(Self(id))
    }
    fn command(&self, value: &Value) -> Result<()> {
        let bytes = serde_json::to_vec(value)?;
        ensure!(
            unsafe { abi::lr_command(self.0, bytes.as_ptr(), bytes.len() as u32) } == 0,
            "Host ABI command was rejected"
        );
        Ok(())
    }
    fn events(&self) -> Result<Vec<Value>> {
        let mut events = Vec::new();
        let mut buffer = vec![0u8; 4096];
        for _ in 0..128 {
            let mut length = 0;
            let mut status = unsafe {
                abi::lr_poll(
                    self.0,
                    buffer.as_mut_ptr(),
                    buffer.len() as u32,
                    &mut length,
                )
            };
            if status == 1 {
                break;
            }
            if status == 2 {
                ensure!(
                    length > 0 && length <= 1024 * 1024,
                    "Invalid ABI event length"
                );
                buffer.resize(length as usize, 0);
                status = unsafe {
                    abi::lr_poll(
                        self.0,
                        buffer.as_mut_ptr(),
                        buffer.len() as u32,
                        &mut length,
                    )
                };
            }
            ensure!(status == 0, "Host ABI polling failed: {status}");
            let event: Value = serde_json::from_slice(&buffer[..length as usize])?;
            if event["kind"] == "error" {
                bail!(
                    "Host settings UI: {}",
                    event["message"].as_str().unwrap_or("Unknown error")
                );
            }
            events.push(event);
        }
        Ok(events)
    }
}
impl Drop for UiHandle {
    fn drop(&mut self) {
        abi::lr_destroy(self.0);
    }
}

struct Acceptance {
    previous_dir: Option<OsString>,
    directory: PathBuf,
    task_name: String,
    executable: PathBuf,
    started: bool,
    owned_pid: Option<u32>,
    clean: bool,
}
impl Acceptance {
    fn cleanup(&mut self) -> Result<()> {
        let result = self.graceful_cleanup();
        if result.is_err() && self.started && !self.clean {
            // Failure-only fallback is restricted to a direct child of this
            // check process running the exact expected agent executable.
            let candidates = if let Some(pid) = self.owned_pid {
                vec![pid]
            } else {
                our_agent_pids(&self.executable)?
            };
            for pid in candidates {
                terminate_test_owned_agent(pid, &self.executable)?;
            }
            if let Some(task) = task_record(&self.task_name)? {
                if is_test_task(&task, &self.task_name, &self.executable) {
                    let script=format!("$ErrorActionPreference='Stop'; $t=Get-ScheduledTask -TaskName {} -TaskPath '\\' -ErrorAction SilentlyContinue; if($t -and @($t.Actions).Count -eq 1 -and $t.Actions[0].Execute -ieq {} -and $t.Actions[0].Arguments.Trim() -eq '--service') {{Unregister-ScheduledTask -InputObject $t -Confirm:$false}}",ps_literal(&self.task_name),ps_literal(&self.executable.to_string_lossy()));
                    powershell(&script)?;
                }
            }
            self.clean = true;
        }
        result
    }
    fn graceful_cleanup(&mut self) -> Result<()> {
        if !self.started || self.clean {
            return Ok(());
        }
        let mut saved = HostSettings::load().unwrap_or_else(|_| HostSettings {
            synthetic: true,
            allow_input: false,
            ..Default::default()
        });
        saved.sharing = false;
        saved.save()?;
        // Both task preflight checks ran before Start Sharing. Do not remove a
        // subsequently replaced task with a different action or task path.
        if let Some(task) = task_record(&self.task_name)? {
            ensure!(
                is_test_task(&task, &self.task_name, &self.executable),
                "Cleanup refused: the login task was replaced by another application"
            );
            let script=format!("$ErrorActionPreference='Stop'; $t=Get-ScheduledTask -TaskName {} -TaskPath '\\' -ErrorAction SilentlyContinue; if($t) {{ if(@($t.Actions).Count -ne 1 -or $t.Actions[0].Execute -ine {} -or $t.Actions[0].Arguments.Trim() -ne '--service') {{throw 'Task ownership changed; cleanup refused'}}; Unregister-ScheduledTask -InputObject $t -Confirm:$false }}",ps_literal(&self.task_name),ps_literal(&self.executable.to_string_lossy()));
            powershell(&script)?;
        }
        if self.owned_pid.is_none() {
            let candidates = our_agent_pids(&self.executable)?;
            ensure!(
                candidates.len() <= 1,
                "Cleanup found multiple test-owned agents; refusing ambiguous cleanup"
            );
            self.owned_pid = candidates.first().copied();
        }
        let startup_deadline = Instant::now() + Duration::from_secs(8);
        if let Some(pid) = self.owned_pid {
            while process_alive(pid)? && pipe_server_pid()?.is_none() {
                ensure!(Instant::now()<startup_deadline,"The test-owned agent never opened its control pipe; cleanup cannot safely request Stop");
                thread::sleep(Duration::from_millis(50));
            }
        }
        if let Some(pid) = pipe_server_pid()? {
            ensure!(
                self.owned_pid.is_none_or(|owned| owned == pid)
                    && is_our_agent(pid, &self.executable)?,
                "Cleanup refused: the current host pipe belongs to another process"
            );
            self.owned_pid = Some(pid);
            let response = service::request(&json!({"command":"stop"}))?;
            ensure!(
                response["ok"] == true,
                "The test-owned agent refused cleanup Stop"
            );
        }
        if let Some(pid) = self.owned_pid {
            let deadline = Instant::now() + Duration::from_secs(8);
            while process_alive(pid)? {
                ensure!(
                    Instant::now() < deadline,
                    "Test-owned host agent did not exit after Stop Sharing; PID {pid}"
                );
                thread::sleep(Duration::from_millis(50));
            }
        }
        ensure!(
            task_record(&self.task_name)?.is_none(),
            "The test login task still exists after cleanup"
        );
        self.clean = true;
        Ok(())
    }
}
impl Drop for Acceptance {
    fn drop(&mut self) {
        if let Err(error) = self.cleanup() {
            eprintln!("Service acceptance cleanup: {error:#}");
        }
        match &self.previous_dir {
            Some(value) => std::env::set_var("LIGHTRAY_DATA_DIR", value),
            None => std::env::remove_var("LIGHTRAY_DATA_DIR"),
        }
    }
}
fn wait_ready(ui: &UiHandle) -> Result<Value> {
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut last = Value::Null;
    loop {
        ui.command(&json!({"command":"status"}))?;
        for event in ui.events()? {
            if event["kind"] == "host_status" {
                if event["running"] == true && event["ready"] == true {
                    return Ok(event);
                }
                last = event;
            }
        }
        ensure!(
            Instant::now() < deadline,
            "Host did not become ready within thirty seconds: {last}"
        );
        thread::sleep(Duration::from_millis(200));
    }
}
fn skipped(reason: &str) -> Result<()> {
    println!(
        "{}",
        serde_json::to_string(
            &json!({"status":"skipped","check":"service-smoke","reason":reason,"existing_service_unchanged":true})
        )?
    );
    Ok(())
}
/// Exercise the actual login task and detached agent through the host C ABI.
/// Preflight conflicts produce a skipped result without changing any state.
pub fn service_smoke() -> Result<()> {
    let (sid, session) = service::identity()?;
    ensure!(
        session != 0,
        "Service acceptance requires an interactive desktop session"
    );
    let task_name = format!("Lightray Host {sid}");
    if task_record(&task_name)?.is_some() {
        return skipped("A current-user Lightray Host login task already exists");
    }
    if service::request(&json!({"command":"status"})).is_ok() || pipe_server_pid()?.is_some() {
        return skipped("A current-session Lightray Host agent already exists");
    }
    let executable = service::agent_path()?;
    ensure!(
        executable.is_file(),
        "Build lightray-host-agent beside lightray-check before running service acceptance"
    );
    let unique = SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis();
    let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../target/acceptance")
        .join(format!("service-{}-{unique}", std::process::id()));
    std::fs::create_dir_all(&directory)?;
    let previous_dir = std::env::var_os("LIGHTRAY_DATA_DIR");
    std::env::set_var("LIGHTRAY_DATA_DIR", &directory);
    let mut acceptance = Acceptance {
        previous_dir,
        directory,
        task_name,
        executable,
        started: false,
        owned_pid: None,
        clean: false,
    };
    // Close the preflight-to-start gap after the isolated environment is installed.
    if task_record(&acceptance.task_name)?.is_some()
        || service::request(&json!({"command":"status"})).is_ok()
        || pipe_server_pid()?.is_some()
    {
        return skipped("Another host appeared during acceptance preflight");
    }
    let port = std::net::UdpSocket::bind("127.0.0.1:0")?
        .local_addr()?
        .port();
    let desired = HostSettings {
        sharing: false,
        port,
        synthetic: true,
        allow_input: false,
        max_width: 1920,
        max_height: 1080,
        fps: 60,
        ..Default::default()
    };
    let first = UiHandle::new()?;
    acceptance.started = true;
    first.command(&json!({"command":"start","settings":desired}))?;
    let ready = wait_ready(&first)?;
    let task = task_record(&acceptance.task_name)?
        .context("Start Sharing did not register a login task")?;
    ensure!(
        is_test_task(&task, &acceptance.task_name, &acceptance.executable),
        "Start Sharing registered unexpected task actions"
    );
    let pid = pipe_server_pid()?.context("Ready host has no control pipe")?;
    ensure!(
        is_our_agent(pid, &acceptance.executable)?,
        "Ready host agent is not a child of this acceptance process"
    );
    acceptance.owned_pid = Some(pid);
    ensure!(
        HostSettings::load()?.sharing,
        "Start Sharing did not persist enabled settings"
    );
    // Prove that a second acceptance process refuses an already running service
    // without touching the task or agent created by this process.
    let skip_probe = Command::new(std::env::current_exe()?)
        .arg("--service-smoke")
        .creation_flags(CREATE_NO_WINDOW)
        .output()?;
    ensure!(
        skip_probe.status.success(),
        "Existing-service preflight probe failed: {}",
        String::from_utf8_lossy(&skip_probe.stderr)
    );
    let skipped: Value = serde_json::from_slice(&skip_probe.stdout)?;
    ensure!(
        skipped["status"] == "skipped" && skipped["existing_service_unchanged"] == true,
        "A second service acceptance process did not refuse the existing test service"
    );
    drop(first);
    thread::sleep(Duration::from_millis(300));
    let survived = service::request(&json!({"command":"status"}))?;
    ensure!(
        survived["running"] == true && survived["ready"] == true && process_alive(pid)?,
        "Destroying the host UI handle stopped the background agent"
    );
    ensure!(
        task_record(&acceptance.task_name)?.is_some(),
        "Destroying the host UI handle removed automatic startup"
    );
    let second = UiHandle::new()?;
    second.command(&json!({"command":"stop"}))?;
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut stopped = false;
    while Instant::now() < deadline {
        for event in second.events()? {
            if event["kind"] == "host_status"
                && event["running"] == false
                && event["settings"]["sharing"] == false
            {
                stopped = true;
            }
        }
        if stopped && !process_alive(pid)? && task_record(&acceptance.task_name)?.is_none() {
            break;
        }
        thread::sleep(Duration::from_millis(200));
    }
    ensure!(
        stopped,
        "Stop Sharing did not report stopped and disabled settings"
    );
    ensure!(
        !process_alive(pid)?,
        "Stop Sharing left the test-owned agent running"
    );
    ensure!(
        task_record(&acceptance.task_name)?.is_none(),
        "Stop Sharing left the login task registered"
    );
    ensure!(
        !HostSettings::load()?.sharing,
        "Stop Sharing did not persist sharing=false"
    );
    drop(second);
    acceptance.clean = true;
    let report = json!({"status":"passed","check":"service-smoke","login_task_registered":true,"agent_ready":ready["ready"],"agent_survived_ui_destruction":true,"existing_service_skip_verified":true,"stop_removed_login_task":true,"stop_terminated_agent":true,"sharing_persisted_false":true,"input_injection_enabled":false,"isolated_data_directory":acceptance.directory});
    std::fs::write(
        acceptance.directory.join("service-smoke.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!("{}", serde_json::to_string(&report)?);
    Ok(())
}

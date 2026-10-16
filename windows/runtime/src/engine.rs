use crate::{
    service,
    settings::{self, HostSettings, SavedComputer},
};
use anyhow::{bail, Context, Result};
use lightray_core::{
    control::{ControlMessage, DisplayInfo},
    endpoint::{
        ClientConfig, ClientEndpoint, ClientEvent, HostConfig, HostEndpoint, HostEvent,
        OutboundDatagram,
    },
    handshake::Pairing,
    input::{InputMessage, PointerButton, ScrollUnits},
    media::{CodecConfig, EncodedFrame, FrameType, HostFrameTimings},
};
use lightray_windows::{CaptureEncoder, DecoderRenderer, Display, InputInjector, VideoConfig};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap, VecDeque},
    net::{SocketAddr, ToSocketAddrs, UdpSocket},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, Mutex,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use windows::core::Interface;

pub enum Command {
    Json(Value),
    SwapChain {
        stream: u8,
        reply: mpsc::SyncSender<usize>,
    },
    Resize {
        stream: u8,
        width: u32,
        height: u32,
    },
}
pub type Events = Arc<Mutex<VecDeque<Value>>>;
pub struct EngineHandle {
    pub sender: mpsc::SyncSender<Command>,
    pub events: Events,
    pub safety_trip: Arc<AtomicBool>,
    stopped: Arc<AtomicBool>,
    worker: Mutex<Option<thread::JoinHandle<()>>>,
}
impl EngineHandle {
    pub fn stop(&self) {
        self.stopped.store(true, Ordering::Release);
        if let Ok(mut worker) = self.worker.lock() {
            if let Some(worker) = worker.take() {
                let _ = worker.join();
            }
        }
    }
}
impl Drop for EngineHandle {
    fn drop(&mut self) {
        self.stop();
    }
}
pub fn emit(events: &Events, value: Value) {
    if let Ok(mut queue) = events.lock() {
        let kind = value.get("kind").and_then(Value::as_str).unwrap_or("");
        if matches!(kind, "stats" | "host_status" | "computers") {
            queue.retain(|old| {
                old.get("kind") != value.get("kind") || old.get("stream") != value.get("stream")
            });
        }
        if queue.len() >= 128 {
            queue.pop_front();
        }
        queue.push_back(value);
    }
}
pub fn spawn(role: u32) -> Result<EngineHandle> {
    let (sender, receiver) = mpsc::sync_channel(256);
    let events = Events::default();
    let stopped = Arc::new(AtomicBool::new(false));
    let safety_trip = Arc::new(AtomicBool::new(false));
    let output = events.clone();
    let stop = stopped.clone();
    let safety = safety_trip.clone();
    let worker = thread::Builder::new().name(format!("lightray-role-{role}")).spawn(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            if role == 1 { host_control(receiver, output.clone(), stop) } else { client_worker(receiver, output.clone(), stop, safety) }
        }));
        match result {
            Ok(Err(error)) => emit(&output, json!({"kind":"error","message":format!("{error:#}")})),
            Err(_) => emit(&output, json!({"kind":"error","message":"The native engine stopped unexpectedly. Remote input was released."})),
            _ => {}
        }
    })?;
    Ok(EngineHandle {
        sender,
        events,
        safety_trip,
        stopped,
        worker: Mutex::new(Some(worker)),
    })
}
fn text<'a>(value: &'a Value, name: &str) -> &'a str {
    value.get(name).and_then(Value::as_str).unwrap_or("")
}
fn number(value: &Value, name: &str, default: u64) -> u64 {
    value.get(name).and_then(Value::as_u64).unwrap_or(default)
}
fn flag(value: &Value, name: &str) -> bool {
    value.get(name).and_then(Value::as_bool).unwrap_or(false)
}
fn micros(origin: Instant) -> u64 {
    origin.elapsed().as_micros().min(u64::MAX as u128) as u64
}
fn unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn get_pairing() -> Result<Pairing> {
    let bytes =
        settings::protected_secret("pairing.dpapi", || Pairing::generate().token().into_bytes())?;
    Pairing::parse(std::str::from_utf8(&bytes)?)
        .context("Stored pairing is invalid; restore the original pairing file")
}
fn host_status() -> Value {
    let saved = HostSettings::load().unwrap_or_default();
    match service::request(&json!({"command":"status"})) {
        Ok(mut status) => {
            status["kind"] = "host_status".into();
            status["settings"] = json!(saved);
            status
        }
        Err(_) => {
            json!({"kind":"host_status","running":false,"ready":false,"settings":saved,"message":if saved.sharing {"Sharing is enabled, but the agent is not running. Start Sharing to retry; see Diagnostics for errors."} else {"Sharing is stopped."}})
        }
    }
}
fn host_control(
    receiver: mpsc::Receiver<Command>,
    events: Events,
    stop: Arc<AtomicBool>,
) -> Result<()> {
    while !stop.load(Ordering::Acquire) {
        let Ok(command) = receiver.recv_timeout(Duration::from_millis(100)) else {
            continue;
        };
        let Command::Json(value) = command else {
            continue;
        };
        let result = (|| -> Result<()> {
            match text(&value, "command") {
                "status" => emit(&events, host_status()),
                "pairing" => emit(
                    &events,
                    json!({"kind":"pairing","token":get_pairing()?.token()}),
                ),
                "start" | "configure" => {
                    let previous = HostSettings::load()?;
                    let mut desired = value
                        .get("settings")
                        .map(|v| serde_json::from_value::<HostSettings>(v.clone()))
                        .transpose()?
                        .unwrap_or_else(|| previous.clone());
                    desired.sharing = text(&value, "command") == "start" || previous.sharing;
                    desired.save()?;
                    if text(&value, "command") == "start" {
                        let already_running =
                            service::request(&json!({"command":"status"})).is_ok();
                        service::enable()?;
                        if already_running {
                            let answer = service::request(
                                &json!({"command":"configure","settings":desired}),
                            )?;
                            if !flag(&answer, "ok") {
                                bail!("{}", text(&answer, "error"));
                            }
                        }
                    } else if desired.sharing {
                        let answer =
                            service::request(&json!({"command":"configure","settings":desired}))?;
                        if !flag(&answer, "ok") {
                            bail!("{}", text(&answer, "error"));
                        }
                    }
                    emit(&events, host_status());
                }
                "stop" => {
                    let mut saved = HostSettings::load()?;
                    saved.sharing = false;
                    saved.save()?;
                    service::disable()?;
                    emit(&events, host_status());
                }
                _ => bail!("Unknown host command"),
            }
            Ok(())
        })();
        if let Err(error) = result {
            emit(
                &events,
                json!({"kind":"error","message":format!("{error:#}")}),
            );
        }
    }
    Ok(())
}
fn socket(bind: SocketAddr) -> Result<UdpSocket> {
    use socket2::{Domain, Protocol, Socket, Type};
    let socket = Socket::new(
        if bind.is_ipv6() {
            Domain::IPV6
        } else {
            Domain::IPV4
        },
        Type::DGRAM,
        Some(Protocol::UDP),
    )?;
    if bind.is_ipv6() {
        socket.set_only_v6(false)?;
    }
    socket.set_recv_buffer_size(4 * 1024 * 1024)?;
    socket.set_send_buffer_size(1024 * 1024)?;
    socket.bind(&bind.into())?;
    socket.set_nonblocking(true)?;
    Ok(socket.into())
}
fn flush(socket: &UdpSocket, packets: Vec<OutboundDatagram>) {
    for packet in packets {
        let _ = socket.send_to(&packet.bytes, packet.destination);
    }
}
fn display_info(display: &Display) -> DisplayInfo {
    DisplayInfo {
        id: display.id,
        is_primary: display.primary,
        supports_hdr: false,
        width: display.width,
        height: display.height,
        refresh_millihertz: display.refresh_millihz,
        layout_x: display.x,
        layout_y: display.y,
        layout_width: display.width,
        layout_height: display.height,
        name: display.name.clone(),
    }
}
fn inventory(settings: &HostSettings) -> Result<Vec<Display>> {
    if settings.synthetic {
        return Ok(vec![Display {
            id: 1,
            name: "Synthetic display".into(),
            x: 0,
            y: 0,
            width: settings.max_width,
            height: settings.max_height,
            refresh_millihz: settings.fps * 1000,
            primary: true,
        }]);
    }
    lightray_windows::enumerate_displays()
}
enum CaptureResult {
    Ready,
    Frame(
        lightray_windows::EncodedFrame,
        lightray_windows::media::MediaTimings,
    ),
    Error(String),
}
struct CaptureWorker {
    display: u32,
    ready: bool,
    last_frame: u64,
    awaiting_idr: bool,
    result: mpsc::Receiver<CaptureResult>,
    paused: Arc<AtomicBool>,
    force: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}
impl CaptureWorker {
    fn new(display: &Display, settings: &HostSettings) -> Result<Self> {
        let ratio = (settings.max_width as f64 / display.width as f64)
            .min(settings.max_height as f64 / display.height as f64)
            .min(1.);
        let width = ((display.width as f64 * ratio) as u32 / 2 * 2).max(64);
        let height = ((display.height as f64 * ratio) as u32 / 2 * 2).max(64);
        let settings = settings.clone();
        let id = display.id;
        let (tx, rx) = mpsc::sync_channel(2);
        let paused = Arc::new(AtomicBool::new(true));
        let run = paused.clone();
        let force = Arc::new(AtomicBool::new(true));
        let idr = force.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let end = stop.clone();
        let worker = thread::Builder::new()
            .name(format!("capture-{id}"))
            .spawn(move || {
                let result = (|| -> Result<()> {
                    let bitrate = settings.bitrate_mbps * 1_000_000 * 100 / 110;
                    let mut encoder = if settings.synthetic {
                        CaptureEncoder::synthetic(width, height, settings.fps, bitrate)?
                    } else {
                        CaptureEncoder::new(id, width, height, settings.fps, bitrate)?
                    };
                    tx.send(CaptureResult::Ready).ok();
                    let origin = Instant::now();
                    let mut next = Instant::now();
                    let interval = Duration::from_micros(1_000_000 / settings.fps as u64);
                    while !end.load(Ordering::Acquire) {
                        if run.load(Ordering::Acquire) {
                            thread::sleep(Duration::from_millis(10));
                            next = Instant::now();
                            continue;
                        }
                        if Instant::now() < next {
                            thread::sleep((next - Instant::now()).min(Duration::from_millis(2)));
                            continue;
                        }
                        next = (next + interval).max(Instant::now());
                        let force_idr = idr.swap(false, Ordering::AcqRel);
                        if let Some(frame) = encoder.frame(force_idr, micros(origin))? {
                            let timings = encoder.last_timings();
                            match tx.try_send(CaptureResult::Frame(frame, timings)) {
                                Ok(()) => {}
                                Err(mpsc::TrySendError::Full(_)) => {
                                    idr.store(true, Ordering::Release);
                                }
                                Err(mpsc::TrySendError::Disconnected(_)) => break,
                            }
                        } else if force_idr {
                            idr.store(true, Ordering::Release);
                        }
                    }
                    Ok(())
                })();
                if let Err(error) = result {
                    let _ = tx.try_send(CaptureResult::Error(format!("{error:#}")));
                }
            })?;
        Ok(Self {
            display: id,
            ready: false,
            last_frame: 0,
            awaiting_idr: true,
            result: rx,
            paused,
            force,
            stop,
            worker: Some(worker),
        })
    }
}
impl Drop for CaptureWorker {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
struct HostRunner {
    endpoint: HostEndpoint,
    socket: UdpSocket,
    settings: HostSettings,
    displays: Vec<Display>,
    workers: BTreeMap<u8, CaptureWorker>,
    pending: BTreeMap<u8, (u32, CaptureWorker)>,
    bindings: BTreeMap<u8, u32>,
    input: InputInjector,
    last_inventory: u64,
    locked: bool,
    last_lock_check: u64,
    log_input: bool,
    error: Option<String>,
    sample: u64,
}
impl HostRunner {
    fn new(settings: HostSettings, log_input: bool) -> Result<Self> {
        settings.validate()?;
        let pairing = get_pairing()?;
        let secret =
            settings::protected_secret("reset.dpapi", || Pairing::generate().psk.to_vec())?;
        let secret: [u8; 32] = secret
            .try_into()
            .map_err(|_| anyhow::anyhow!("Invalid reset secret"))?;
        let config = HostConfig {
            frame_rate: settings.fps as usize,
            bitrate: settings.bitrate_mbps as usize * 1_000_000,
            ..Default::default()
        };
        let endpoint =
            HostEndpoint::new(config, secret, HashMap::from([(pairing.id, pairing.psk)]));
        let displays = inventory(&settings)?;
        let mut workers = BTreeMap::new();
        if let Some(primary) = displays.iter().find(|d| d.primary).or(displays.first()) {
            workers.insert(1, CaptureWorker::new(primary, &settings)?);
        }
        let socket = socket(format!("[::]:{}", settings.port).parse()?)?;
        Ok(Self {
            endpoint,
            socket,
            settings,
            displays,
            workers,
            pending: BTreeMap::new(),
            bindings: BTreeMap::new(),
            input: InputInjector::new(),
            last_inventory: 0,
            locked: false,
            last_lock_check: 0,
            log_input,
            error: None,
            sample: 0,
        })
    }
    fn ready(&self) -> bool {
        !self.locked && self.workers.values().any(|w| w.ready)
    }
    fn announce(&mut self) {
        self.endpoint.send_control(ControlMessage::Displays(
            self.displays.iter().map(display_info).collect(),
        ));
        if let Some(session) = &self.endpoint.session {
            let streams = session.video_streams.clone();
            for stream in streams {
                self.endpoint.send_control(ControlMessage::StreamDisplay {
                    stream,
                    display: *self.bindings.get(&stream).unwrap_or(&0),
                });
            }
        }
    }
    fn bind(&mut self, stream: u8, display: u32, req_id: u32) -> Result<()> {
        if display == 0 {
            self.pending.remove(&stream);
            self.workers.remove(&stream);
            self.bindings.remove(&stream);
            self.endpoint.bind_display(req_id, stream, 0);
            return Ok(());
        }
        if self
            .workers
            .get(&stream)
            .is_some_and(|w| w.ready && w.display == display)
        {
            self.bindings.insert(stream, display);
            if let Some(worker) = self.workers.get_mut(&stream) {
                worker.awaiting_idr = true;
                worker.last_frame = 0;
            }
            self.workers[&stream].force.store(true, Ordering::Release);
            self.endpoint.bind_display(req_id, stream, display);
            return Ok(());
        }
        let Some(info) = self.displays.iter().find(|d| d.id == display) else {
            self.endpoint.send_control(ControlMessage::DisplaySelected {
                req_id,
                stream,
                display: *self.bindings.get(&stream).unwrap_or(&0),
            });
            return Ok(());
        };
        self.pending
            .insert(stream, (req_id, CaptureWorker::new(info, &self.settings)?));
        Ok(())
    }
    fn step(&mut self, now: u64) -> Result<()> {
        let mut buffer = [0u8; 65536];
        for _ in 0..1024 {
            match self.socket.recv_from(&mut buffer) {
                Ok((length, peer)) => self.endpoint.receive(&buffer[..length], peer, now, unix()),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error.into()),
            }
        }
        self.endpoint.tick(now, unix());
        if now.saturating_sub(self.last_lock_check) > 250_000 {
            self.last_lock_check = now;
            let locked = !self.settings.synthetic && !lightray_windows::is_desktop_available();
            if locked != self.locked {
                self.locked = locked;
                self.input.release_all();
                for w in self.workers.values() {
                    w.force.store(true, Ordering::Release);
                }
            }
        }
        for event in self.endpoint.take_events() {
            match event {
                HostEvent::SessionStarted { .. } => {
                    self.input.release_all();
                    self.pending.clear();
                    self.bindings.clear();
                    if let Some(session) = &self.endpoint.session {
                        self.workers
                            .retain(|stream, _| session.video_streams.contains(stream));
                    }
                    for worker in self.workers.values_mut() {
                        while let Ok(result) = worker.result.try_recv() {
                            match result {
                                CaptureResult::Ready => worker.ready = true,
                                CaptureResult::Error(error) => {
                                    worker.ready = false;
                                    self.error = Some(error);
                                }
                                _ => {}
                            }
                        }
                        worker.awaiting_idr = true;
                        worker.last_frame = 0;
                        worker.force.store(true, Ordering::Release);
                    }
                    let first = self
                        .endpoint
                        .session
                        .as_ref()
                        .and_then(|s| s.video_streams.first().copied());
                    if let (Some(stream), Some(primary)) = (
                        first,
                        self.displays
                            .iter()
                            .find(|d| d.primary)
                            .or(self.displays.first())
                            .map(|d| d.id),
                    ) {
                        self.bind(stream, primary, 0)?;
                    }
                    self.announce();
                    settings::log("Authenticated client connected");
                }
                HostEvent::SessionEnded { .. } | HostEvent::Paused => {
                    self.input.release_all();
                    self.pending.clear();
                    for worker in self.workers.values_mut() {
                        worker.last_frame = 0;
                        worker.awaiting_idr = true;
                        worker.force.store(true, Ordering::Release);
                    }
                    settings::log("Client paused or disconnected");
                }
                HostEvent::KeyframeNeeded { stream } => {
                    if let Some(worker) = self.workers.get_mut(&stream) {
                        worker.awaiting_idr = true;
                        worker.force.store(true, Ordering::Release);
                    }
                }
                HostEvent::DisplayRequested {
                    stream,
                    display,
                    req_id,
                } => self.bind(stream, display, req_id)?,
                HostEvent::Input(message)
                    if self.settings.allow_input
                        && !self.locked
                        && !self.log_input
                        && self.endpoint.is_streaming()
                        && self.bindings.iter().any(|(stream, _)| {
                            self.workers.get(stream).is_some_and(|w| {
                                w.ready
                                    && w.last_frame > 0
                                    && now.saturating_sub(w.last_frame) < 2_000_000
                            })
                        }) =>
                {
                    if let Err(error) = inject(&mut self.input, &self.displays, &message) {
                        self.input.release_all();
                        self.error = Some(error.to_string());
                    }
                }
                _ => {}
            }
        }
        let mut ready = Vec::new();
        let mut failed = Vec::new();
        for (&stream, (_, worker)) in &mut self.pending {
            match worker.result.try_recv() {
                Ok(CaptureResult::Ready) => {
                    worker.ready = true;
                    ready.push(stream);
                }
                Ok(CaptureResult::Error(error)) => {
                    self.error = Some(error);
                    failed.push(stream);
                }
                Err(mpsc::TryRecvError::Disconnected) => failed.push(stream),
                _ => {}
            }
        }
        for stream in ready {
            let (req_id, worker) = self.pending.remove(&stream).unwrap();
            let display = worker.display;
            self.workers.insert(stream, worker);
            self.bindings.insert(stream, display);
            self.endpoint.bind_display(req_id, stream, display);
            self.endpoint
                .send_control(ControlMessage::StreamDisplay { stream, display });
        }
        for stream in failed {
            if let Some((req_id, _)) = self.pending.remove(&stream) {
                self.endpoint.send_control(ControlMessage::DisplaySelected {
                    req_id,
                    stream,
                    display: *self.bindings.get(&stream).unwrap_or(&0),
                });
            }
        }
        let running = self.endpoint.is_streaming() && !self.locked;
        let mut announced = false;
        for (&stream, worker) in &mut self.workers {
            worker.paused.store(
                !running || !self.bindings.contains_key(&stream),
                Ordering::Release,
            );
            for _ in 0..3 {
                match worker.result.try_recv() {
                    Ok(CaptureResult::Ready) => {
                        worker.ready = true;
                        announced = true;
                    }
                    Ok(CaptureResult::Error(error)) => {
                        worker.ready = false;
                        self.input.release_all();
                        self.error = Some(error);
                    }
                    Err(mpsc::TryRecvError::Disconnected) => {
                        if worker.ready {
                            self.input.release_all();
                            self.error =
                                Some("Capture worker stopped; use Start Sharing to retry.".into());
                        }
                        worker.ready = false;
                        break;
                    }
                    Ok(CaptureResult::Frame(frame, timings))
                        if running
                            && worker.ready
                            && self.bindings.get(&stream) == Some(&worker.display) =>
                    {
                        if worker.awaiting_idr && !frame.keyframe {
                            continue;
                        }
                        if frame.keyframe {
                            worker.awaiting_idr = false;
                        }
                        worker.last_frame = now;
                        self.sample += 1;
                        self.endpoint.submit(
                            EncodedFrame {
                                is_keyframe: frame.keyframe,
                                payload: frame.data,
                                codec_config: frame.config.map(|c| CodecConfig {
                                    vps: c.vps,
                                    sps: c.sps,
                                    pps: c.pps,
                                }),
                                capture_time_micros: now,
                                host_timings: Some(HostFrameTimings {
                                    capture_micros: (timings.capture_ms * 1000.).min(1_000_000.)
                                        as u32,
                                    encode_micros: (timings.encode_ms * 1000.).min(1_000_000.)
                                        as u32,
                                    sample_id: self.sample,
                                }),
                            },
                            stream,
                            now,
                        );
                    }
                    _ => break,
                }
            }
        }
        if announced && self.endpoint.session.is_some() {
            let first = self
                .endpoint
                .session
                .as_ref()
                .and_then(|s| s.video_streams.first().copied());
            if let Some(stream) = first {
                if let Some(w) = self.workers.get(&stream).filter(|w| w.ready) {
                    self.bindings.insert(stream, w.display);
                    self.endpoint.send_control(ControlMessage::StreamDisplay {
                        stream,
                        display: w.display,
                    });
                }
            }
        }
        if running
            && !self.bindings.keys().any(|stream| {
                self.workers.get(stream).is_some_and(|w| {
                    w.ready && w.last_frame > 0 && now.saturating_sub(w.last_frame) < 2_000_000
                })
            })
        {
            self.input.release_all();
        }
        if now.saturating_sub(self.last_inventory) > 1_000_000 {
            self.last_inventory = now;
            if let Ok(displays) = inventory(&self.settings) {
                if serde_json::to_string(&displays)? != serde_json::to_string(&self.displays)? {
                    let changed: BTreeSet<u32> = displays
                        .iter()
                        .filter(|new| {
                            self.displays.iter().any(|old| {
                                old.id == new.id
                                    && (old.width != new.width || old.height != new.height)
                            })
                        })
                        .map(|d| d.id)
                        .collect();
                    self.displays = displays;
                    let stale: Vec<_> = self
                        .workers
                        .iter()
                        .filter_map(|(&stream, worker)| {
                            (!self.displays.iter().any(|d| d.id == worker.display))
                                .then_some(stream)
                        })
                        .collect();
                    for stream in stale {
                        let replacement = if self.bindings.len() == 1 {
                            self.displays
                                .iter()
                                .find(|d| d.primary)
                                .or(self.displays.first())
                                .map(|d| d.id)
                        } else {
                            None
                        };
                        self.bind(stream, replacement.unwrap_or(0), 0)?;
                    }
                    let restart: Vec<_> = self
                        .workers
                        .iter()
                        .filter_map(|(&stream, worker)| {
                            changed
                                .contains(&worker.display)
                                .then_some((stream, worker.display))
                        })
                        .collect();
                    for (stream, display) in restart {
                        if let Some(info) = self.displays.iter().find(|d| d.id == display) {
                            self.pending
                                .insert(stream, (0, CaptureWorker::new(info, &self.settings)?));
                        }
                    }
                    self.announce();
                }
            }
        }
        self.endpoint.tick(now, unix());
        flush(&self.socket, self.endpoint.take_outbox());
        Ok(())
    }
}
impl Drop for HostRunner {
    fn drop(&mut self) {
        self.input.release_all();
        self.endpoint.close(0);
        flush(&self.socket, self.endpoint.take_outbox());
    }
}
fn inject(input: &mut InputInjector, displays: &[Display], message: &InputMessage) -> Result<()> {
    match message {
        InputMessage::Key {
            usage,
            down,
            is_repeat,
        } => {
            if *down && *is_repeat {
                input.key_repeat(*usage)
            } else {
                input.key(*usage, *down)
            }
        }
        InputMessage::Text(text) => input.text(text),
        InputMessage::Pointer { x, y, display } => {
            let id = if *display == 0 {
                displays
                    .iter()
                    .find(|d| d.primary)
                    .or(displays.first())
                    .map(|d| d.id)
                    .unwrap_or(0)
            } else {
                *display
            };
            if !displays.iter().any(|d| d.id == id) {
                return Ok(());
            }
            input.pointer(id, *x as f64 / 65535., *y as f64 / 65535.)
        }
        InputMessage::Button { button, down } => input.button(*button as u8 - 1, *down),
        InputMessage::Scroll { dx, dy, units } => {
            let divisor = if *units == ScrollUnits::Pixels {
                40.
            } else {
                120.
            };
            input.scroll(-(*dx as f64) / divisor, *dy as f64 / divisor)
        }
    }
}
pub fn host_main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|s| s == "pair") {
        let path = args
            .windows(2)
            .find(|s| s[0] == "--output")
            .map(|s| &s[1])
            .context("Use pair --output FILE; pairing secrets are never printed in diagnostics")?;
        std::fs::write(path, get_pairing()?.token() + "\n")?;
        return Ok(());
    }
    let mut saved = HostSettings::load()?;
    let service_mode = args.iter().any(|s| s == "--service");
    if service::identity()?.1 == 0 {
        bail!("The host requires a signed-in interactive desktop session");
    }
    if service_mode && !saved.sharing {
        return Ok(());
    }
    if args.iter().any(|s| s == "--synthetic") {
        saved.synthetic = true;
    }
    for pair in args.windows(2) {
        match pair[0].as_str() {
            "--port" => saved.port = pair[1].parse()?,
            "--fps" => saved.fps = pair[1].parse()?,
            _ => {}
        }
    }
    let duration = args
        .windows(2)
        .find(|p| p[0] == "--seconds")
        .map(|p| p[1].parse::<u64>())
        .transpose()?;
    let stop = Arc::new(AtomicBool::new(false));
    let (tx, rx) = mpsc::sync_channel(16);
    let server = service::serve(stop.clone(), tx)?;
    let origin = Instant::now();
    let mut error = None;
    let mut runner = match HostRunner::new(saved.clone(), args.iter().any(|s| s == "--log-input")) {
        Ok(r) => Some(r),
        Err(e) => {
            settings::log(&format!("Host blocked: {e:#}"));
            error = Some(format!("{e:#}"));
            None
        }
    };
    settings::log("Host agent started");
    while !stop.load(Ordering::Acquire) {
        if duration.is_some_and(|s| origin.elapsed().as_secs() >= s) {
            break;
        }
        while let Ok(request) = rx.try_recv() {
            let response = match text(&request.message, "command") {
                "status" => {
                    json!({"version":1,"ok":true,"running":true,"ready":runner.as_ref().is_some_and(HostRunner::ready),"message":error.clone().or_else(||runner.as_ref().and_then(|r|r.error.clone())).unwrap_or_else(||if runner.as_ref().is_some_and(|r|r.locked){"Desktop locked; input released.".into()}else if runner.as_ref().is_some_and(HostRunner::ready){format!("Sharing on UDP {} · {} fps · {} Mb/s",saved.port,saved.fps,saved.bitrate_mbps)}else{"Preparing capture and encoder…".into()})})
                }
                "stop" => {
                    stop.store(true, Ordering::Release);
                    json!({"ok":true})
                }
                "configure" => {
                    match serde_json::from_value::<HostSettings>(
                        request.message["settings"].clone(),
                    )
                    .map_err(anyhow::Error::from)
                    .and_then(|settings| {
                        settings.validate()?;
                        Ok(settings)
                    }) {
                        Ok(settings) => {
                            drop(runner.take());
                            saved = settings;
                            match HostRunner::new(saved.clone(), false) {
                                Ok(r) => {
                                    runner = Some(r);
                                    error = None;
                                    json!({"ok":true})
                                }
                                Err(e) => {
                                    error = Some(format!("{e:#}"));
                                    json!({"ok":false,"error":error})
                                }
                            }
                        }
                        Err(e) => json!({"ok":false,"error":e.to_string()}),
                    }
                }
                _ => json!({"ok":false,"error":"Unknown command"}),
            };
            let _ = request.reply.send(response);
        }
        if let Some(active) = &mut runner {
            if let Err(e) = active.step(micros(origin)) {
                error = Some(format!("{e:#}"));
                settings::log(error.as_deref().unwrap());
                drop(runner.take());
            }
        }
        thread::sleep(Duration::from_millis(1));
    }
    drop(runner);
    stop.store(true, Ordering::Release);
    let _ = server.join();
    settings::log("Host agent stopped");
    Ok(())
}

struct ClientStream {
    renderer: DecoderRenderer,
    generation: u32,
    width: u32,
    height: u32,
    last_decode: u64,
    last_sample_time: u64,
    frames: u64,
    last_frames: u64,
    decode_us: u64,
}
struct ClientRunner {
    endpoint: Option<ClientEndpoint>,
    socket: Option<UdpSocket>,
    streams: BTreeMap<u8, ClientStream>,
    bindings: BTreeMap<u8, u32>,
    accepted_streams: Vec<u8>,
    events: Events,
    input_enabled: bool,
    held_keys: BTreeMap<u16, u16>,
    held_buttons: BTreeSet<u8>,
    swap_modifiers: bool,
    current: Option<SavedComputer>,
    last_stats: u64,
    connected_at: u64,
    last_progress: u64,
    error_at: u64,
}
impl ClientRunner {
    fn new(events: Events) -> Self {
        Self {
            endpoint: None,
            socket: None,
            streams: BTreeMap::new(),
            bindings: BTreeMap::new(),
            accepted_streams: Vec::new(),
            events,
            input_enabled: false,
            held_keys: BTreeMap::new(),
            held_buttons: BTreeSet::new(),
            swap_modifiers: false,
            current: None,
            last_stats: 0,
            connected_at: 0,
            last_progress: 0,
            error_at: 0,
        }
    }
    fn computers(&self) -> Result<()> {
        let computers:Vec<_>=settings::computers()?.into_iter().map(|c|json!({"name":c.name,"address":c.address,"pairing_id":c.pairing_id,"stats":c.stats,"local_cursor":c.local_cursor,"swap_modifiers":c.swap_modifiers})).collect();
        emit(
            &self.events,
            json!({"kind":"computers","computers":computers}),
        );
        Ok(())
    }
    fn connect(&mut self, value: &Value, now: u64) -> Result<()> {
        self.disconnect(now);
        let address = text(value, "address");
        if address.is_empty() || address.len() > 1024 {
            bail!("Enter a host name or IP address");
        }
        let host = resolve(address)?;
        let saved = settings::computers()?
            .into_iter()
            .find(|c| c.pairing_id == text(value, "pairing_id"));
        let token = if !text(value, "token").is_empty() {
            text(value, "token").to_string()
        } else if let Some(c) = &saved {
            String::from_utf8(lightray_windows::unprotect(&c.protected_token)?)?
        } else {
            bail!("Import the pairing file supplied by the host");
        };
        let pairing = Pairing::parse(&token)
            .context("Pairing code must be lr1- followed by 80 hexadecimal characters")?;
        let udp = socket(
            if host.is_ipv6() {
                "[::]:0"
            } else {
                "0.0.0.0:0"
            }
            .parse()?,
        )?;
        let mut endpoint = ClientEndpoint::new(ClientConfig::new(pairing.id, pairing.psk, host));
        endpoint.start(now, unix());
        flush(&udp, endpoint.take_outbox());
        self.swap_modifiers = saved.as_ref().is_some_and(|c| c.swap_modifiers);
        let computer = SavedComputer {
            name: if text(value, "name").is_empty() {
                address.to_string()
            } else {
                text(value, "name").to_string()
            },
            address: address.to_string(),
            pairing_id: format!("{:016x}", pairing.id),
            protected_token: lightray_windows::protect(token.as_bytes())?,
            stats: saved.as_ref().is_none_or(|c| c.stats),
            local_cursor: saved.as_ref().is_some_and(|c| c.local_cursor),
            swap_modifiers: self.swap_modifiers,
        };
        if flag(value, "remember") {
            settings::remember(computer.clone())?;
            self.computers()?;
        }
        self.current = Some(computer);
        self.endpoint = Some(endpoint);
        self.socket = Some(udp);
        self.connected_at = now;
        self.last_progress = now;
        Ok(())
    }
    fn disconnect(&mut self, now: u64) {
        self.release(now);
        if let Some(endpoint) = &mut self.endpoint {
            endpoint.close(now);
            if let Some(socket) = &self.socket {
                flush(socket, endpoint.take_outbox());
            }
        }
        self.endpoint = None;
        self.socket = None;
        self.accepted_streams.clear();
        for &stream in self.bindings.keys() {
            emit(
                &self.events,
                json!({"kind":"binding","stream":stream,"display":0}),
            );
        }
        self.bindings.clear();
        self.streams.clear();
    }
    fn live(&self, now: u64) -> bool {
        self.streams
            .values()
            .any(|s| video_is_live(s.frames, s.last_decode, now))
    }
    fn send(&mut self, input: InputMessage, now: u64) -> bool {
        let ok = self
            .endpoint
            .as_mut()
            .is_some_and(|e| e.send_input(input, now));
        if !ok {
            if let Some(endpoint) = &mut self.endpoint {
                endpoint.close(now);
            }
            self.input_enabled = false;
            self.held_keys.clear();
            self.held_buttons.clear();
            emit(
                &self.events,
                json!({"kind":"error","message":"Remote input queue overflowed. The session was closed to release held keys and buttons."}),
            );
        }
        ok
    }
    fn release(&mut self, now: u64) {
        self.input_enabled = false;
        let keys = std::mem::take(&mut self.held_keys);
        let buttons = std::mem::take(&mut self.held_buttons);
        for (_, usage) in keys {
            self.send(
                InputMessage::Key {
                    usage,
                    down: false,
                    is_repeat: false,
                },
                now,
            );
        }
        for button in buttons {
            if let Some(button) = pointer_button(button) {
                self.send(
                    InputMessage::Button {
                        button,
                        down: false,
                    },
                    now,
                );
            }
        }
    }
    fn command(&mut self, value: Value, now: u64) -> Result<()> {
        match text(&value, "command") {
            "computers" => self.computers()?,
            "forget" => {
                settings::forget(text(&value, "pairing_id"))?;
                self.computers()?;
            }
            "connect" => self.connect(&value, now)?,
            "disconnect" => {
                self.disconnect(now);
                emit(
                    &self.events,
                    json!({"kind":"disconnected","message":"Disconnected."}),
                );
            }
            "release_input" => self.release(now),
            "resume_input" => self.input_enabled = self.live(now),
            "preferences" => {
                self.release(now);
                self.swap_modifiers = flag(&value, "swap_modifiers");
                if let Some(computer) = &mut self.current {
                    computer.swap_modifiers = self.swap_modifiers;
                    computer.local_cursor = flag(&value, "local_cursor");
                    if let Some(stats) = value.get("stats").and_then(Value::as_bool) {
                        computer.stats = stats;
                    }
                    if settings::computers()?
                        .iter()
                        .any(|c| c.pairing_id == computer.pairing_id)
                    {
                        settings::remember(computer.clone())?;
                    }
                }
            }
            "select_display" | "open_display" => {
                self.release(now);
                let stream = if text(&value, "command") == "open_display" {
                    self.accepted_streams
                        .iter()
                        .find(|s| !self.bindings.contains_key(s))
                        .copied()
                        .context("All negotiated display streams are in use")?
                } else {
                    u8::try_from(number(&value, "stream", 1))?
                };
                let display = u32::try_from(number(&value, "display", 0))?;
                if !self
                    .endpoint
                    .as_mut()
                    .is_some_and(|e| e.select_display(display, stream))
                {
                    bail!("Display selection could not be queued");
                }
            }
            "text" if self.live(now) => {
                let text = text(&value, "text");
                if text.is_empty() || text.len() > 1024 {
                    bail!("Text must contain 1–1024 UTF-8 bytes");
                }
                self.send(InputMessage::Text(text.into()), now);
            }
            "key" if self.input_enabled && self.live(now) => {
                let original = u16::try_from(number(&value, "usage", 0))?;
                let down = flag(&value, "down");
                let usage = if let Some(usage) = self.held_keys.get(&original) {
                    *usage
                } else if self.swap_modifiers {
                    match original {
                        224 => 227,
                        227 => 224,
                        228 => 231,
                        231 => 228,
                        x => x,
                    }
                } else {
                    original
                };
                if down {
                    self.held_keys.insert(original, usage);
                } else {
                    self.held_keys.remove(&original);
                }
                self.send(
                    InputMessage::Key {
                        usage,
                        down,
                        is_repeat: flag(&value, "repeat"),
                    },
                    now,
                );
            }
            "pointer" if self.input_enabled && self.live(now) => {
                self.send(
                    InputMessage::Pointer {
                        x: u16::try_from(number(&value, "x", 0))?,
                        y: u16::try_from(number(&value, "y", 0))?,
                        display: u32::try_from(number(&value, "display", 0))?,
                    },
                    now,
                );
            }
            "button" if self.input_enabled && self.live(now) => {
                let raw = u8::try_from(number(&value, "button", 0))?;
                let button = pointer_button(raw).context("Invalid pointer button")?;
                let down = flag(&value, "down");
                if down {
                    self.held_buttons.insert(raw);
                } else {
                    self.held_buttons.remove(&raw);
                }
                self.send(InputMessage::Button { button, down }, now);
            }
            "scroll" if self.input_enabled && self.live(now) => {
                let delta = |key| {
                    value
                        .get(key)
                        .and_then(Value::as_i64)
                        .unwrap_or(0)
                        .clamp(i16::MIN as i64, i16::MAX as i64) as i16
                };
                self.send(
                    InputMessage::Scroll {
                        dx: delta("dx"),
                        dy: delta("dy"),
                        units: ScrollUnits::WheelNotch120,
                    },
                    now,
                );
            }
            "key" | "pointer" | "button" | "scroll" | "text" => {}
            _ => bail!("Unknown client command"),
        }
        Ok(())
    }
    fn step(&mut self, now: u64) -> Result<()> {
        if let (Some(socket), Some(endpoint)) = (&self.socket, &mut self.endpoint) {
            let mut buffer = [0u8; 65536];
            for _ in 0..1024 {
                match socket.recv_from(&mut buffer) {
                    Ok((n, peer)) => endpoint.receive(&buffer[..n], peer, now, unix()),
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(e) => return Err(e.into()),
                }
            }
            endpoint.tick(now, unix());
        }
        let events = self
            .endpoint
            .as_mut()
            .map(|e| e.take_events())
            .unwrap_or_default();
        let mut frames_waiting = HashMap::<u8, usize>::new();
        for event in &events {
            if let ClientEvent::Frame { stream, .. } = event {
                *frames_waiting.entry(*stream).or_default() += 1;
            }
        }
        for event in events {
            match event {
                ClientEvent::Connecting => emit(
                    &self.events,
                    json!({"kind":"disconnected","message":"Connecting to host…"}),
                ),
                ClientEvent::Connected {
                    session_id,
                    video_streams,
                    ..
                } => {
                    for &stream in self.streams.keys() {
                        emit(
                            &self.events,
                            json!({"kind":"surface_detach","stream":stream}),
                        );
                    }
                    self.streams.clear();
                    self.bindings.clear();
                    self.accepted_streams = video_streams.clone();
                    self.release(now);
                    self.last_progress = now;
                    emit(
                        &self.events,
                        json!({"kind":"connected","session_id":session_id,"streams":video_streams}),
                    );
                    emit(
                        &self.events,
                        json!({"kind":"session_reset","streams":self.accepted_streams}),
                    );
                    if let Some(computer) = &self.current {
                        emit(
                            &self.events,
                            json!({"kind":"preferences","stats":computer.stats,"local_cursor":computer.local_cursor,"swap_modifiers":computer.swap_modifiers}),
                        );
                    }
                }
                ClientEvent::Disconnected { reason } => {
                    self.release(now);
                    for &stream in self.streams.keys() {
                        emit(
                            &self.events,
                            json!({"kind":"surface_detach","stream":stream}),
                        );
                    }
                    self.streams.clear();
                    self.bindings.clear();
                    self.accepted_streams.clear();
                    emit(
                        &self.events,
                        json!({"kind":"disconnected","message":reason}),
                    );
                }
                ClientEvent::Displays(displays) => {
                    emit(&self.events, json!({"kind":"displays","displays":displays}))
                }
                ClientEvent::StreamDisplay { stream, display } => {
                    if display == 0 {
                        self.bindings.remove(&stream);
                        self.streams.remove(&stream);
                    } else {
                        self.bindings.insert(stream, display);
                    }
                    emit(
                        &self.events,
                        json!({"kind":"binding","stream":stream,"display":display}),
                    );
                }
                ClientEvent::Frame { stream, frame } => {
                    if frames_waiting.get(&stream).copied().unwrap_or(0) > 8
                        || now.saturating_sub(frame.completed_at) > 150_000
                    {
                        if let Some(state) = self.streams.get_mut(&stream) {
                            state.last_decode = 0;
                            let _ = state.renderer.reset();
                        }
                        emit(
                            &self.events,
                            json!({"kind":"stats","stream":stream,"live":false,"message":"Video queue interrupted · input released"}),
                        );
                        if let Some(e) = &mut self.endpoint {
                            e.decoder_failed(stream, frame.frame_id);
                        }
                        continue;
                    }
                    let keyframe = frame.header.frame_type == FrameType::Idr;
                    let config = frame
                        .header
                        .codec_config
                        .as_ref()
                        .map(|c| {
                            VideoConfig::from_parameter_sets(
                                c.vps.clone(),
                                c.sps.clone(),
                                c.pps.clone(),
                            )
                        })
                        .transpose()?;
                    if !self.streams.contains_key(&stream) {
                        let Some(config) = &config else {
                            if let Some(e) = &mut self.endpoint {
                                e.decoder_failed(stream, frame.frame_id);
                            }
                            continue;
                        };
                        match DecoderRenderer::new(config.width, config.height) {
                            Ok(renderer) => {
                                self.streams.insert(
                                    stream,
                                    ClientStream {
                                        renderer,
                                        generation: frame.header.config_generation,
                                        width: config.width,
                                        height: config.height,
                                        last_decode: 0,
                                        last_sample_time: 0,
                                        frames: 0,
                                        last_frames: 0,
                                        decode_us: 0,
                                    },
                                );
                                emit(&self.events, json!({"kind":"surface","stream":stream}));
                            }
                            Err(error) => {
                                if let Some(e) = &mut self.endpoint {
                                    e.decoder_failed(stream, frame.frame_id);
                                }
                                if now.saturating_sub(self.error_at) > 2_000_000 {
                                    self.error_at = now;
                                    emit(
                                        &self.events,
                                        json!({"kind":"error","message":format!("{error:#}")}),
                                    );
                                }
                                continue;
                            }
                        }
                    }
                    let state = self.streams.get_mut(&stream).unwrap();
                    if state.generation != frame.header.config_generation {
                        state.renderer.reset()?;
                        state.last_decode = 0;
                        state.generation = frame.header.config_generation;
                        if !keyframe {
                            if let Some(e) = &mut self.endpoint {
                                e.decoder_failed(stream, frame.frame_id);
                            }
                            continue;
                        }
                    }
                    if let Some(config) = &config {
                        state.width = config.width;
                        state.height = config.height;
                    }
                    // MF presentation time uses our full-width local clock; the host's wire
                    // capture clock wraps every ~72 minutes and is diagnostic only here.
                    state.last_sample_time = now.max(state.last_sample_time.saturating_add(1));
                    let native = lightray_windows::EncodedFrame {
                        data: frame.payload().to_vec(),
                        config,
                        keyframe,
                        timestamp: state.last_sample_time,
                    };
                    let start = Instant::now();
                    match state.renderer.decode(&native) {
                        Ok(true) => {
                            state.decode_us += start.elapsed().as_micros() as u64;
                            state.last_decode = now;
                            state.frames += 1;
                            self.last_progress = now;
                            if let Some(e) = &mut self.endpoint {
                                e.decoded(stream, frame.frame_id, keyframe);
                            }
                            if state.frames == 1 {
                                emit(
                                    &self.events,
                                    json!({"kind":"stats","stream":stream,"live":true,"width":state.width,"height":state.height,"fps":0,"message":"Live · click the video to control · Ctrl+Alt+Shift+F12 releases input"}),
                                );
                            }
                        }
                        Ok(false) => {}
                        Err(error) => {
                            state.last_decode = 0;
                            let device_lost = state.renderer.is_device_lost();
                            let _ = state.renderer.reset();
                            if let Some(e) = &mut self.endpoint {
                                e.decoder_failed(stream, frame.frame_id);
                            }
                            emit(
                                &self.events,
                                json!({"kind":"stats","stream":stream,"live":false,"message":"Decoder interrupted · input released"}),
                            );
                            if now.saturating_sub(self.error_at) > 2_000_000 {
                                self.error_at = now;
                                emit(
                                    &self.events,
                                    json!({"kind":"error","message":format!("Video decode: {error:#}")}),
                                );
                            }
                            if device_lost {
                                emit(
                                    &self.events,
                                    json!({"kind":"surface_detach","stream":stream}),
                                );
                                self.streams.remove(&stream);
                            }
                        }
                    }
                }
            }
        }
        if !self.live(now) && self.input_enabled {
            self.release(now);
        }
        if now.saturating_sub(self.last_stats) >= 1_000_000 {
            let elapsed = (now.saturating_sub(self.last_stats) as f64 / 1_000_000.).max(1.);
            self.last_stats = now;
            let rtt = self
                .endpoint
                .as_ref()
                .and_then(|e| e.session.as_ref())
                .map(|s| s.connection.rtt.smoothed as f64 / 1000.)
                .unwrap_or(0.);
            for (&stream, state) in &mut self.streams {
                let count = state.frames - state.last_frames;
                let fps = (count as f64 / elapsed).round() as u32;
                let decode = if count > 0 {
                    state.decode_us as f64 / count as f64 / 1000.
                } else {
                    0.
                };
                state.last_frames = state.frames;
                state.decode_us = 0;
                let live = video_is_live(state.frames, state.last_decode, now);
                emit(
                    &self.events,
                    json!({"kind":"stats","stream":stream,"live":live,"width":state.width,"height":state.height,"fps":fps,"decode_present_ms":decode,"rtt_ms":rtt,
                    "message":if live{format!("{} × {} · {fps} fps · RTT {rtt:.1} ms · decode/present {decode:.2} ms",state.width,state.height)}else{"Video interrupted · input released".into()}}),
                );
            }
        }
        if self.endpoint.is_some()
            && self.streams.is_empty()
            && now.saturating_sub(self.connected_at) > 12_000_000
            && now.saturating_sub(self.last_progress) > 12_000_000
        {
            self.disconnect(now);
            emit(
                &self.events,
                json!({"kind":"error","message":"No live video arrived within 12 seconds. Check the address, pairing, host status, and Windows Firewall."}),
            );
        }
        if let (Some(endpoint), Some(socket)) = (&mut self.endpoint, &self.socket) {
            endpoint.tick(now, unix());
            flush(socket, endpoint.take_outbox());
        }
        Ok(())
    }
}
fn video_is_live(frames: u64, last_decode: u64, now: u64) -> bool {
    frames > 0 && last_decode > 0 && now.saturating_sub(last_decode) < 2_000_000
}
fn pointer_button(value: u8) -> Option<PointerButton> {
    Some(match value {
        1 => PointerButton::Left,
        2 => PointerButton::Right,
        3 => PointerButton::Middle,
        4 => PointerButton::Back,
        5 => PointerButton::Forward,
        _ => return None,
    })
}
fn resolve(value: &str) -> Result<SocketAddr> {
    if let Ok(address) = value.parse::<SocketAddr>() {
        return Ok(address);
    }
    if let Ok(ip) = value.parse::<std::net::IpAddr>() {
        return Ok(SocketAddr::new(ip, 7373));
    }
    let address = if value.starts_with('[') && value.ends_with(']') {
        format!("{value}:7373")
    } else if value.contains(':') {
        value.to_string()
    } else {
        format!("{value}:7373")
    };
    address
        .to_socket_addrs()?
        .next()
        .context("Host name has no usable network address")
}
fn client_worker(
    receiver: mpsc::Receiver<Command>,
    events: Events,
    stop: Arc<AtomicBool>,
    safety: Arc<AtomicBool>,
) -> Result<()> {
    let origin = Instant::now();
    let mut runner = ClientRunner::new(events.clone());
    while !stop.load(Ordering::Acquire) {
        let now = micros(origin);
        if safety.swap(false, Ordering::AcqRel) {
            runner.disconnect(now);
            emit(
                &events,
                json!({"kind":"error","message":"Command queue overflow: remote input released and session disconnected."}),
            );
        }
        for _ in 0..256 {
            let Ok(command) = receiver.try_recv() else {
                break;
            };
            let result = match command {
                Command::Json(value) => runner.command(value, now),
                Command::SwapChain { stream, reply } => {
                    let pointer = runner
                        .streams
                        .get(&stream)
                        .map(|s| s.renderer.swap_chain() as usize)
                        .unwrap_or(0);
                    if reply.send(pointer).is_err() && pointer != 0 {
                        unsafe {
                            let unknown =
                                windows::core::IUnknown::from_raw(pointer as *mut std::ffi::c_void);
                            drop(unknown);
                        }
                    }
                    Ok(())
                }
                Command::Resize {
                    stream,
                    width,
                    height,
                } => {
                    if let Some(state) = runner.streams.get_mut(&stream) {
                        state.renderer.resize(width, height)
                    } else {
                        Ok(())
                    }
                }
            };
            if let Err(error) = result {
                emit(
                    &events,
                    json!({"kind":"error","message":format!("{error:#}")}),
                );
            }
        }
        if let Err(error) = runner.step(now) {
            runner.disconnect(now);
            emit(
                &events,
                json!({"kind":"error","message":format!("{error:#}")}),
            );
        }
        thread::sleep(Duration::from_millis(1));
    }
    runner.disconnect(micros(origin));
    Ok(())
}
pub fn check_main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|s| s == "--abi-smoke") {
        crate::abi::smoke()?;
        println!("{{\"abi_version\":1,\"status\":\"passed\",\"checks\":[\"version\",\"create\",\"commands\",\"bounded_poll\",\"destroy\",\"stale_handle\"]}}");
        return Ok(());
    }
    if args.iter().any(|s| s == "--service-smoke") {
        return crate::acceptance::service_smoke();
    }
    if args.iter().any(|s| s == "--stop-host") {
        let mut saved = HostSettings::load()?;
        saved.sharing = false;
        saved.save()?;
        let _ = service::request(&json!({"command":"stop"}));
        return Ok(());
    }
    crate::validation::run(&args)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn authenticated_endpoints() -> (HostEndpoint, ClientEndpoint) {
        let host: SocketAddr = "127.0.0.1:7373".parse().unwrap();
        let peer: SocketAddr = "127.0.0.1:45000".parse().unwrap();
        let mut host_endpoint = HostEndpoint::new(
            HostConfig::default(),
            [8; 32],
            HashMap::from([(42, [7; 32])]),
        );
        let mut config = ClientConfig::new(42, [7; 32], host);
        config.video_stream_count = 1;
        let mut client = ClientEndpoint::new(config);
        client.start(1_000, unix());
        for packet in client.take_outbox() {
            host_endpoint.receive(&packet.bytes, peer, 2_000, unix());
        }
        for packet in host_endpoint.take_outbox() {
            client.receive(&packet.bytes, host, 3_000, unix());
        }
        assert!(client.is_connected());
        host_endpoint.take_events();
        (host_endpoint, client)
    }
    #[test]
    fn resolves_all_literal_address_forms() {
        assert_eq!(resolve("127.0.0.1").unwrap().port(), 7373);
        assert_eq!(resolve("[::1]:1234").unwrap().port(), 1234);
        assert_eq!(resolve("::1").unwrap().port(), 7373);
    }
    #[test]
    fn public_computer_events_do_not_contain_secrets() {
        let events = Events::default();
        emit(&events, json!({"kind":"stats","stream":1,"n":1}));
        emit(&events, json!({"kind":"stats","stream":1,"n":2}));
        assert_eq!(events.lock().unwrap().len(), 1);
    }
    #[test]
    fn waiting_reset_and_stale_video_never_enable_input() {
        assert!(!video_is_live(0, 0, 1));
        assert!(!video_is_live(0, 10, 11));
        assert!(!video_is_live(1, 0, 11));
        assert!(video_is_live(1, 10, 10));
        assert!(video_is_live(1, 10, 2_000_009));
        assert!(!video_is_live(1, 10, 2_000_010));
        let mut runner = ClientRunner::new(Events::default());
        runner
            .command(json!({"command":"resume_input"}), 1)
            .unwrap();
        assert!(!runner.input_enabled);
        runner
            .command(json!({"command":"key","usage":4,"down":true}), 1)
            .unwrap();
        runner
            .command(json!({"command":"button","button":1,"down":true}), 1)
            .unwrap();
        assert!(runner.held_keys.is_empty());
        assert!(runner.held_buttons.is_empty());
    }
    #[test]
    fn focus_release_delivers_the_actual_mapped_keys_and_buttons() {
        let (mut host, client) = authenticated_endpoints();
        let mut runner = ClientRunner::new(Events::default());
        runner.endpoint = Some(client);
        runner.input_enabled = true;
        runner.held_keys.insert(224, 227);
        runner.held_keys.insert(4, 4);
        runner.held_buttons.insert(1);
        runner.release(4_000);
        assert!(!runner.input_enabled);
        assert!(runner.held_keys.is_empty());
        assert!(runner.held_buttons.is_empty());
        let endpoint = runner.endpoint.as_mut().unwrap();
        endpoint.tick(4_000, unix());
        for packet in endpoint.take_outbox() {
            host.receive(
                &packet.bytes,
                "127.0.0.1:45000".parse().unwrap(),
                5_000,
                unix(),
            );
        }
        let events = host.take_events();
        assert!(events.iter().any(|e| matches!(
            e,
            HostEvent::Input(InputMessage::Key {
                usage: 227,
                down: false,
                ..
            })
        )));
        assert!(events.iter().any(|e| matches!(
            e,
            HostEvent::Input(InputMessage::Key {
                usage: 4,
                down: false,
                ..
            })
        )));
        assert!(events.iter().any(|e| matches!(
            e,
            HostEvent::Input(InputMessage::Button {
                button: PointerButton::Left,
                down: false
            })
        )));
        assert!(!events
            .iter()
            .any(|e| matches!(e, HostEvent::Input(InputMessage::Key { usage: 224, .. }))));
    }
    #[test]
    fn replacement_handshake_clears_stale_display_bindings_and_prunes_session() {
        let (_, client) = authenticated_endpoints();
        let events = Events::default();
        let mut runner = ClientRunner::new(events.clone());
        runner.endpoint = Some(client);
        runner.bindings.insert(1, 100);
        runner.bindings.insert(16, 200);
        runner.accepted_streams = vec![1, 16];
        runner.step(4_000).unwrap();
        assert!(runner.bindings.is_empty());
        assert_eq!(runner.accepted_streams, vec![1]);
        let events = events.lock().unwrap();
        let reset = events
            .iter()
            .find(|e| e["kind"] == "session_reset")
            .unwrap();
        assert_eq!(reset["streams"], json!([1]));
    }
}

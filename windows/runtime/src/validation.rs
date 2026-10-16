//! Native validation path: NVIDIA moving pattern -> encrypted UDP -> hardware HEVC -> GPU.
//! This intentionally records CPU call durations separately from unavailable GPU timings.
use anyhow::{bail, ensure, Context, Result};
use lightray_core::{
    endpoint::{ClientConfig, ClientEndpoint, ClientEvent, HostConfig, HostEndpoint, HostEvent},
    handshake::Pairing,
    media::{CodecConfig, EncodedFrame},
};
use lightray_windows::{CaptureEncoder, DecoderRenderer, EncodedFrame as NativeFrame, VideoConfig};
use serde::Serialize;
use std::{
    collections::HashMap,
    io::ErrorKind,
    net::UdpSocket,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Default, Serialize)]
struct Distribution {
    samples: u64,
    total_us: u64,
    min_us: Option<u64>,
    max_us: u64,
    #[serde(skip)]
    values: Vec<u64>,
}
impl Distribution {
    fn add(&mut self, us: u64) {
        self.samples += 1;
        self.total_us = self.total_us.saturating_add(us);
        self.min_us = Some(self.min_us.map_or(us, |v| v.min(us)));
        self.max_us = self.max_us.max(us);
        if self.values.len() < 240_000 {
            self.values.push(us);
        }
    }
    fn json(&mut self) -> serde_json::Value {
        self.values.sort_unstable();
        let percentile = |p: usize| {
            self.values
                .get((self.values.len().saturating_sub(1) * p) / 100)
                .copied()
        };
        serde_json::json!({"samples":self.samples,"quantile_samples":self.values.len(),"quantile_sampling":"first 240000 observations, bounded memory","mean_us":if self.samples==0{None}else{Some(self.total_us as f64/self.samples as f64)},"minimum_us":self.min_us,"p50_us":percentile(50),"p95_us":percentile(95),"p99_us":percentile(99),"maximum_us":self.max_us})
    }
}
#[derive(Clone, Copy, Default, Serialize)]
struct ProcessMetrics {
    cpu_us: u64,
    working_set_bytes: u64,
    peak_working_set_bytes: u64,
    private_bytes: u64,
}
#[repr(C)]
#[derive(Default)]
struct MemoryCounters {
    size: u32,
    page_fault_count: u32,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
    private_usage: usize,
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn K32GetProcessMemoryInfo(
        process: *mut std::ffi::c_void,
        counters: *mut MemoryCounters,
        size: u32,
    ) -> i32;
}
fn process_metrics() -> Result<ProcessMetrics> {
    use windows::Win32::{
        Foundation::FILETIME,
        System::Threading::{GetCurrentProcess, GetProcessTimes},
    };
    unsafe {
        let mut creation = FILETIME::default();
        let mut exit = FILETIME::default();
        let mut kernel = FILETIME::default();
        let mut user = FILETIME::default();
        let process = GetCurrentProcess();
        GetProcessTimes(process, &mut creation, &mut exit, &mut kernel, &mut user)?;
        let filetime = |f: FILETIME| ((f.dwHighDateTime as u64) << 32) | f.dwLowDateTime as u64;
        let mut counters = MemoryCounters {
            size: std::mem::size_of::<MemoryCounters>() as u32,
            ..Default::default()
        };
        ensure!(
            K32GetProcessMemoryInfo(
                process.0,
                &mut counters,
                std::mem::size_of::<MemoryCounters>() as u32
            ) != 0,
            "GetProcessMemoryInfo failed: {}",
            std::io::Error::last_os_error()
        );
        Ok(ProcessMetrics {
            cpu_us: (filetime(kernel) + filetime(user)) / 10,
            working_set_bytes: counters.working_set_size as u64,
            peak_working_set_bytes: counters.peak_working_set_size as u64,
            private_bytes: counters.private_usage as u64,
        })
    }
}
#[derive(Clone, Copy, Default, Serialize)]
struct NetworkStats {
    sent: u64,
    received: u64,
    dropped_by_fault_injection: u64,
    sent_bytes: u64,
    received_bytes: u64,
}
struct Faults {
    state: u64,
    loss: f64,
}
impl Faults {
    fn drop_packet(&mut self) -> bool {
        self.state ^= self.state << 13;
        self.state ^= self.state >> 7;
        self.state ^= self.state << 17;
        (self.state as f64 / u64::MAX as f64) * 100. < self.loss
    }
}
struct Link {
    host: UdpSocket,
    client: UdpSocket,
    host_stats: NetworkStats,
    client_stats: NetworkStats,
    faults: Faults,
}
impl Link {
    fn pump(
        &mut self,
        host: &mut HostEndpoint,
        client: &mut ClientEndpoint,
        now: u64,
        unix: u64,
    ) -> Result<()> {
        for packet in host.take_outbox() {
            if self.faults.drop_packet() {
                self.host_stats.dropped_by_fault_injection += 1;
                continue;
            }
            let sent = self.host.send_to(&packet.bytes, packet.destination)?;
            ensure!(sent == packet.bytes.len(), "Partial UDP send");
            self.host_stats.sent += 1;
            self.host_stats.sent_bytes += sent as u64;
        }
        for packet in client.take_outbox() {
            if self.faults.drop_packet() {
                self.client_stats.dropped_by_fault_injection += 1;
                continue;
            }
            let sent = self.client.send_to(&packet.bytes, packet.destination)?;
            ensure!(sent == packet.bytes.len(), "Partial UDP send");
            self.client_stats.sent += 1;
            self.client_stats.sent_bytes += sent as u64;
        }
        let mut bytes = [0; 9000];
        for _ in 0..8192 {
            match self.host.recv_from(&mut bytes) {
                Ok((size, source)) => {
                    self.host_stats.received += 1;
                    self.host_stats.received_bytes += size as u64;
                    host.receive(&bytes[..size], source, now, unix);
                }
                Err(e) if e.kind() == ErrorKind::WouldBlock => break,
                Err(e) => return Err(e.into()),
            }
        }
        for _ in 0..8192 {
            match self.client.recv_from(&mut bytes) {
                Ok((size, source)) => {
                    self.client_stats.received += 1;
                    self.client_stats.received_bytes += size as u64;
                    client.receive(&bytes[..size], source, now, unix);
                }
                Err(e) if e.kind() == ErrorKind::WouldBlock => break,
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    }
}
struct Options {
    seconds: f64,
    loss: f64,
    seed: u64,
    no_decode: bool,
}
impl Options {
    fn parse(args: &[String]) -> Result<Option<Self>> {
        let mut value = Self {
            seconds: 10.,
            loss: 0.,
            seed: 0x003c_3ea1_3ab1,
            no_decode: false,
        };
        let mut index = 0;
        while index < args.len() {
            match args[index].as_str() {
                "--seconds" => {
                    index += 1;
                    value.seconds = args
                        .get(index)
                        .context("--seconds needs a number")?
                        .parse()?;
                }
                "--loss" => {
                    index += 1;
                    value.loss = args
                        .get(index)
                        .context("--loss needs a percentage")?
                        .parse()?;
                }
                "--seed" => {
                    index += 1;
                    value.seed = args
                        .get(index)
                        .context("--seed needs an integer")?
                        .parse()?;
                }
                "--no-decode" => value.no_decode = true,
                "--help" | "-h" => {
                    println!("Lightray native validation\n  --seconds N   pattern duration (default 10, 600 for acceptance)\n  --loss P      seeded packet loss in both directions, percent (default 0)\n  --seed N      reproducible packet-loss seed\n  --no-decode   validate NVENC and transport only; decoder/presentation unvalidated");
                    return Ok(None);
                }
                other => bail!("Unknown validation argument: {other}"),
            };
            index += 1;
        }
        ensure!(
            value.seconds.is_finite() && (0.1..=3600.).contains(&value.seconds),
            "--seconds must be between 0.1 and 3600"
        );
        ensure!(
            value.loss.is_finite() && (0.0..=100.0).contains(&value.loss),
            "--loss must be between 0 and 100"
        );
        ensure!(value.seed != 0, "--seed must be nonzero");
        Ok(Some(value))
    }
}

/// Run actual hardware and UDP validation. No fallback substitutes software codec output.
pub fn run(args: &[String]) -> Result<()> {
    let Some(options) = Options::parse(args)? else {
        return Ok(());
    };
    let width = 1920;
    let height = 1080;
    let fps = 60;
    let bitrate = 20_000_000;
    let initialize = Instant::now();
    let mut encoder = CaptureEncoder::synthetic(width, height, fps, bitrate)
        .context("Creating NVIDIA synthetic capture/encoder")?;
    let encoder_initialization_us = initialize.elapsed().as_micros() as u64;
    let initialize = Instant::now();
    let mut decoder = if options.no_decode {
        None
    } else {
        Some(DecoderRenderer::new(width,height).context("Creating hardware HEVC decoder; use --no-decode only to validate encoding and transport separately")?)
    };
    let decoder_initialization_us = if options.no_decode {
        None
    } else {
        Some(initialize.elapsed().as_micros() as u64)
    };
    let host_socket = UdpSocket::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
    let client_socket = UdpSocket::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
    for socket in [&host_socket, &client_socket] {
        socket2::SockRef::from(socket).set_recv_buffer_size(8 << 20)?;
        socket2::SockRef::from(socket).set_send_buffer_size(2 << 20)?;
    }
    host_socket.set_nonblocking(true)?;
    client_socket.set_nonblocking(true)?;
    let host_address = host_socket.local_addr()?;
    let pairing = Pairing::generate();
    let mut host = HostEndpoint::new(
        HostConfig::default(),
        [0xa8; 32],
        HashMap::from([(pairing.id, pairing.psk)]),
    );
    let mut config = ClientConfig::new(pairing.id, pairing.psk, host_address);
    config.video_stream_count = 1;
    let mut client = ClientEndpoint::new(config);
    let mut link = Link {
        host: host_socket,
        client: client_socket,
        host_stats: Default::default(),
        client_stats: Default::default(),
        faults: Faults {
            state: options.seed,
            loss: options.loss,
        },
    };
    let initial_metrics = process_metrics()?;
    let mut memory_samples = vec![initial_metrics];
    let clock = Instant::now();
    let unix = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    client.start(0, unix);
    let mut connected_at = None;
    let mut sessions = 0u64;
    let mut disconnects = Vec::new();
    let mut force_idr = true;
    let mut encode_count = 0u64;
    let mut delivered = 0u64;
    let mut decoded = 0u64;
    let mut decoder_buffered = 0u64;
    let mut decoder_failures = 0u64;
    let mut last_delivered = None;
    let mut latest_config: Option<VideoConfig> = None;
    let mut generation = Distribution::default();
    let mut capture_stage = Distribution::default();
    let mut encode_stage = Distribution::default();
    let mut transport = Distribution::default();
    let mut decode_present = Distribution::default();
    let mut decode_stage = Distribution::default();
    let mut present_stage = Distribution::default();
    let mut freshness = Distribution::default();
    let mut encoded_bytes = 0u64;
    let mut delivered_bytes = 0u64;
    let mut frame_attempts = 0u64;
    let mut schedule_late = Distribution::default();
    let duration = Duration::from_secs_f64(options.seconds);
    let mut streaming_start = None;
    let mut next_frame = Duration::ZERO;
    let mut last_memory_sample = Instant::now();
    let mut peak_core_bytes = 0usize;
    let mut final_core_bytes = 0usize;
    let mut fec_repaired = 0u64;
    let mut retransmissions = 0u64;
    loop {
        let now = clock.elapsed();
        let now_us = now.as_micros() as u64;
        let wall = unix + now.as_secs();
        if connected_at.is_none() && now > Duration::from_secs(20) {
            bail!(
                "No authenticated loopback session after 20 seconds (loss {}%)",
                options.loss
            );
        }
        let pipeline_done = streaming_start.is_some_and(|start: Duration| now >= start + duration);
        if !pipeline_done && client.is_connected() {
            let start = *streaming_start.get_or_insert(now);
            if next_frame < start {
                next_frame = start;
            }
            if now >= next_frame {
                schedule_late.add(now.saturating_sub(next_frame).as_micros() as u64);
                frame_attempts += 1;
                let begin = Instant::now();
                let frame = encoder
                    .frame(force_idr, now_us)
                    .context("Native synthetic capture/conversion/NVENC")?;
                generation.add(begin.elapsed().as_micros() as u64);
                if let Some(frame) = frame {
                    let stages = encoder.last_timings();
                    capture_stage.add((stages.capture_ms.max(0.) * 1000.) as u64);
                    encode_stage.add((stages.encode_ms.max(0.) * 1000.) as u64);
                    force_idr = false;
                    encode_count += 1;
                    encoded_bytes += frame.data.len() as u64;
                    let config = frame.config.map(|c| CodecConfig {
                        vps: c.vps,
                        sps: c.sps,
                        pps: c.pps,
                    });
                    let begin = Instant::now();
                    host.submit(
                        EncodedFrame {
                            is_keyframe: frame.keyframe,
                            payload: frame.data,
                            codec_config: config,
                            capture_time_micros: frame.timestamp,
                            host_timings: None,
                        },
                        1,
                        clock.elapsed().as_micros() as u64,
                    );
                    transport.add(begin.elapsed().as_micros() as u64);
                }
                next_frame += Duration::from_nanos(1_000_000_000 / fps as u64);
                if next_frame + Duration::from_millis(50) < now {
                    next_frame = now + Duration::from_nanos(1_000_000_000 / fps as u64);
                }
            }
        }
        // Refresh after the blocking native encoder; capture and delivery must use
        // actual instants rather than the same loop-start timestamp.
        let transport_now = clock.elapsed().as_micros() as u64;
        let begin = Instant::now();
        host.tick(transport_now, wall);
        client.tick(transport_now, wall);
        link.pump(&mut host, &mut client, transport_now, wall)?;
        link.pump(&mut host, &mut client, transport_now, wall)?;
        transport.add(begin.elapsed().as_micros() as u64);
        for event in host.take_events() {
            match event {
                HostEvent::KeyframeNeeded { stream: 1 } => force_idr = true,
                HostEvent::SessionEnded { reason, .. } => {
                    disconnects.push(format!("host: {reason}"))
                }
                _ => {}
            }
        }
        for event in client.take_events() {
            match event {
                ClientEvent::Connected { .. } => {
                    connected_at.get_or_insert(now_us);
                    sessions += 1;
                    force_idr = true;
                }
                ClientEvent::Disconnected { reason } => {
                    disconnects.push(format!("client: {reason}"))
                }
                ClientEvent::Frame { stream, frame } => {
                    let delivered_now = clock.elapsed().as_micros() as u64;
                    delivered += 1;
                    delivered_bytes += frame.payload().len() as u64;
                    last_delivered = Some(delivered_now);
                    let elapsed =
                        (delivered_now as u32).wrapping_sub(frame.header.capture_time_micros);
                    if elapsed < 1 << 31 {
                        freshness.add(elapsed as u64);
                    }
                    let keyframe = frame.header.frame_type == lightray_core::media::FrameType::Idr;
                    if let Some(config) = frame.header.codec_config {
                        latest_config = Some(
                            VideoConfig::from_parameter_sets(config.vps, config.sps, config.pps)
                                .context("Parsing native HEVC SPS from authenticated frame")?,
                        );
                    }
                    if let Some(decoder) = &mut decoder {
                        let payload = frame.bytes[frame.payload_offset..].to_vec();
                        let native = NativeFrame {
                            data: payload,
                            config: if keyframe {
                                latest_config.clone()
                            } else {
                                None
                            },
                            keyframe,
                            timestamp: frame.header.capture_time_micros as u64,
                        };
                        let begin = Instant::now();
                        let result = decoder.decode(&native);
                        decode_present.add(begin.elapsed().as_micros() as u64);
                        let stages = decoder.last_timings();
                        decode_stage.add((stages.decode_ms.max(0.) * 1000.) as u64);
                        if stages.present_ms > 0. {
                            present_stage.add((stages.present_ms * 1000.) as u64);
                        }
                        match result {
                            Ok(true) => {
                                decoded += 1;
                                client.decoded(stream, frame.frame_id, keyframe);
                            }
                            Ok(false) => {
                                decoder_buffered += 1;
                            }
                            Err(error) => {
                                decoder_failures += 1;
                                eprintln!(
                                    "Frame {} hardware decoder error: {error:#}",
                                    frame.frame_id
                                );
                                client.decoder_failed(stream, frame.frame_id);
                                decoder.reset()?;
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        if let Some(s) = &client.session {
            let current = s.connection.memory_budget.used_bytes();
            peak_core_bytes = peak_core_bytes.max(s.connection.memory_budget.peak_bytes());
            final_core_bytes = current;
            fec_repaired = s.videos.values().map(|v| v.stats.fec_repaired).sum();
        }
        if let Some(s) = &host.session {
            retransmissions = s.videos.values().map(|v| v.stats.retransmissions).sum();
        }
        if last_memory_sample.elapsed() >= Duration::from_secs(1) {
            memory_samples.push(process_metrics()?);
            last_memory_sample = Instant::now();
        }
        if pipeline_done && now >= streaming_start.unwrap() + duration + Duration::from_millis(300)
        {
            break;
        }
        let wake_frame = if pipeline_done {
            now + Duration::from_millis(1)
        } else {
            next_frame
        };
        let wake = host
            .next_deadline(now_us)
            .into_iter()
            .chain(client.next_deadline(now_us))
            .min()
            .map(Duration::from_micros)
            .unwrap_or(now + Duration::from_millis(1))
            .min(wake_frame);
        let sleep = wake
            .saturating_sub(clock.elapsed())
            .min(Duration::from_millis(1));
        if !sleep.is_zero() {
            std::thread::sleep(sleep);
        } else {
            std::thread::yield_now();
        }
    }
    let final_metrics = process_metrics()?;
    memory_samples.push(final_metrics);
    let elapsed_us = clock.elapsed().as_micros() as u64;
    let streaming_start = streaming_start.context("No authenticated session established")?;
    client.close(elapsed_us);
    link.pump(
        &mut host,
        &mut client,
        elapsed_us,
        unix + elapsed_us / 1_000_000,
    )?;
    let cpu_us = final_metrics.cpu_us.saturating_sub(initial_metrics.cpu_us);
    let peak_memory = memory_samples
        .iter()
        .map(|s| s.working_set_bytes)
        .max()
        .unwrap_or(0);
    let first_half = &memory_samples[..memory_samples.len() / 2];
    let last_half = &memory_samples[memory_samples.len() / 2..];
    let mean = |samples: &[ProcessMetrics]| {
        if samples.is_empty() {
            0.
        } else {
            samples.iter().map(|s| s.private_bytes as f64).sum::<f64>() / samples.len() as f64
        }
    };
    let start_mean = mean(first_half);
    let end_mean = mean(last_half);
    let tail_fresh_us = last_delivered.map(|last| elapsed_us.saturating_sub(last));
    let report = serde_json::json!({
        "kind":"lightray_native_udp_validation","video":{"width":width,"height":height,"fps_target":fps,"bitrate_target":bitrate,"codec":"HEVC Main SDR","capture_source":"GPU generated moving pattern","transport":"authenticated Lightray v1 over real IPv4 UDP loopback"},
        "configuration":{"seconds":options.seconds,"loss_percent_each_direction":options.loss,"loss_seed":options.seed,"decode_enabled":!options.no_decode},
        "initialization":{"nvenc_us":encoder_initialization_us,"decoder_and_renderer_us":decoder_initialization_us,"authenticated_handshake_us":connected_at},
        "frames":{"attempts":frame_attempts,"encoded":encode_count,"delivered":delivered,"decoded_and_presented":if options.no_decode{None}else{Some(decoded)},"decoder_buffered":if options.no_decode{None}else{Some(decoder_buffered)},"decoder_failures":if options.no_decode{None}else{Some(decoder_failures)},"encoded_bytes":encoded_bytes,"delivered_bytes":delivered_bytes,"encoded_fps":encode_count as f64/options.seconds,"delivered_fps":delivered as f64/options.seconds,"decoded_fps":if options.no_decode{None}else{Some(decoded as f64/options.seconds)},"fec_repaired_fragments":fec_repaired,"retransmitted_fragments":retransmissions,"last_delivery_age_us":tail_fresh_us},
        "sessions":{"established":sessions,"disconnects":disconnects},
        "timing":{"capture_and_color_conversion_cpu_stage":capture_stage.json(),"nvenc_cpu_stage":encode_stage.json(),"mf_decode_cpu_stage":if options.no_decode{serde_json::Value::Null}else{decode_stage.json()},"gpu_convert_and_present_cpu_stage":if options.no_decode{serde_json::Value::Null}else{present_stage.json()},"synthetic_capture_convert_encode_cpu_call":generation.json(),"core_and_udp_cpu_call":transport.json(),"decode_convert_present_cpu_call":if options.no_decode{serde_json::Value::Null}else{decode_present.json()},"capture_to_delivered_frame":freshness.json(),"frame_schedule_lateness":schedule_late.json(),"separate_gpu_capture_us":null,"separate_gpu_encode_us":null,"separate_gpu_decode_us":null,"separate_gpu_present_us":null},
        "network":{"host":link.host_stats,"client":link.client_stats},
        "memory":{"initial":initial_metrics,"final":final_metrics,"observed_peak_working_set_bytes":peak_memory,"first_half_mean_private_bytes":start_mean,"last_half_mean_private_bytes":end_mean,"half_to_half_private_bytes_change":end_mean-start_mean,"peak_retained_protocol_bytes":peak_core_bytes,"final_retained_protocol_bytes":final_core_bytes,"note":"Process samples are real measurements; memory stability requires inspection over a sufficiently long run."},
        "cpu":{"process_cpu_us":cpu_us,"elapsed_wall_us":elapsed_us,"equivalent_busy_cores":cpu_us as f64/elapsed_us.max(1)as f64},
        "validation":{"native_encoding":encode_count>0,"encrypted_udp_streaming":delivered>0,"hardware_decoding_and_gpu_presentation":if options.no_decode{serde_json::Value::String("UNVALIDATED (--no-decode)".into())}else{serde_json::Value::Bool(decoded>0&&decoder_failures==0)},"ten_minute_duration":options.seconds>=600.,"apple_interoperability":"PENDING MacBook validation","desktop_capture":"UNVALIDATED (synthetic source)","timing_note":"CPU call durations include GPU synchronization where the platform blocks; separate GPU stages are not measured."},
        "streaming_started_us":streaming_start.as_micros()as u64,
    });
    println!("{}", serde_json::to_string_pretty(&report)?);
    ensure!(encode_count > 0, "No hardware-encoded frames produced");
    ensure!(delivered > 0, "No authenticated frame delivered");
    ensure!(
        disconnects.is_empty(),
        "Unexpected session disconnects during validation"
    );
    if !options.no_decode {
        ensure!(decoded > 0, "No hardware-decoded frame presented");
        ensure!(
            decoder_failures == 0,
            "Hardware decoder failed {decoder_failures} time(s)"
        );
    }
    Ok(())
}

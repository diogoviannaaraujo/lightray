use anyhow::{Context, Result};
use lightray_windows::{CaptureEncoder, DecoderRenderer};
use std::time::{Duration, Instant};
fn main() -> Result<()> {
    let frames = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "120".into())
        .parse::<u64>()?;
    println!("displays={:?}", lightray_windows::enumerate_displays()?);
    let mut encoder = if std::env::args().any(|v| v == "--capture") {
        CaptureEncoder::new(
            lightray_windows::enumerate_displays()?
                .first()
                .context("No NVIDIA display")?
                .id,
            1920,
            1080,
            60,
            18_000_000,
        )?
    } else {
        CaptureEncoder::synthetic(1920, 1080, 60, 18_000_000)?
    };
    let mut decoder = if std::env::args().any(|v| v == "--encode-only") {
        None
    } else {
        Some(DecoderRenderer::new(1920, 1080)?)
    };
    let start = Instant::now();
    let mut encoded = 0u64;
    let mut decoded = 0u64;
    let mut encode_ms = Vec::new();
    let mut decode_ms = Vec::new();
    let mut capture_ms = Vec::new();
    let mut present_ms = Vec::new();
    let mut bytes = 0;
    for i in 0..frames {
        let tick = Instant::now();
        if let Some(frame) = encoder.frame(i % 300 == 0, i * 16667 + 1)? {
            let _elapsed = tick.elapsed();
            let stages = encoder.last_timings();
            capture_ms.push(stages.capture_ms);
            encode_ms.push(stages.encode_ms);
            bytes += frame.data.len();
            encoded += 1;
            let tick = Instant::now();
            if let Some(config) = &frame.config {
                assert_eq!(
                    lightray_windows::VideoConfig::from_parameter_sets(
                        config.vps.clone(),
                        config.sps.clone(),
                        config.pps.clone()
                    )?,
                    *config
                );
            }
            if decoder
                .as_mut()
                .is_some_and(|d| d.decode(&frame).expect("Decode frame"))
            {
                decoded += 1;
            }
            let _elapsed = tick.elapsed();
            if let Some(decoder) = &decoder {
                let stages = decoder.last_timings();
                decode_ms.push(stages.decode_ms);
                present_ms.push(stages.present_ms);
            }
        }
        let target = start + Duration::from_secs_f64((i + 1) as f64 / 60.);
        if let Some(wait) = target.checked_duration_since(Instant::now()) {
            std::thread::sleep(wait);
        }
        if i % 600 == 599 {
            println!(
                "progress frames={} decoded={} wall={:.1}s",
                encoded,
                decoded,
                start.elapsed().as_secs_f64()
            );
        }
    }
    let pct = |mut values: Vec<f64>, p: f64| {
        if values.is_empty() {
            return 0.;
        }
        values.sort_by(f64::total_cmp);
        values[((values.len() - 1) as f64 * p) as usize]
    };
    anyhow::ensure!(
        encoded > 0 && (decoded > 0 || decoder.is_none()),
        "No encoded/decoded frames"
    );
    println!("{{\"status\":\"passed\",\"width\":1920,\"height\":1080,\"encoded\":{encoded},\"decoded\":{decoded},\"seconds\":{},\"bytes\":{bytes},\"capture_p95_ms\":{},\"encode_p95_ms\":{},\"decode_p95_ms\":{},\"present_p95_ms\":{}}}",start.elapsed().as_secs_f64(),pct(capture_ms,0.95),pct(encode_ms,0.95),pct(decode_ms,0.95),pct(present_ms,0.95));
    Ok(())
}

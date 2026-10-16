use super::{
    gpu::{self, Converter, Gpu},
    nvenc::Nvenc,
    EncodedFrame,
};
use anyhow::{ensure, Context, Result};
use std::time::{Duration, Instant};
use windows::{
    core::Interface,
    Graphics::{
        Capture::*,
        DirectX::{Direct3D11::IDirect3DDevice, DirectXPixelFormat},
    },
    Win32::{
        Graphics::{
            Direct3D11::*,
            Dxgi::{Common::*, IDXGIDevice},
        },
        System::WinRT::{
            Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess},
            Graphics::Capture::IGraphicsCaptureItemInterop,
            RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED,
        },
    },
};
struct Apartment(std::marker::PhantomData<std::rc::Rc<()>>);
impl Apartment {
    fn new() -> Result<Self> {
        unsafe {
            RoInitialize(RO_INIT_MULTITHREADED)?;
        }
        Ok(Self(std::marker::PhantomData))
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe { RoUninitialize() }
    }
}
struct Capture {
    session: GraphicsCaptureSession,
    pool: Direct3D11CaptureFramePool,
    width: u32,
    height: u32,
}
impl Capture {
    fn new(gpu: &Gpu, monitor: windows::Win32::Graphics::Gdi::HMONITOR) -> Result<Self> {
        unsafe {
            ensure!(
                GraphicsCaptureSession::IsSupported()?,
                "Windows Graphics Capture unavailable"
            );
            let dxgi: IDXGIDevice = gpu.device.cast()?;
            let projected: IDirect3DDevice = CreateDirect3D11DeviceFromDXGIDevice(&dxgi)?.cast()?;
            let interop: IGraphicsCaptureItemInterop =
                windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
            let item: GraphicsCaptureItem = interop.CreateForMonitor(monitor)?;
            let size = item.Size()?;
            let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
                &projected,
                DirectXPixelFormat::B8G8R8A8UIntNormalized,
                2,
                size,
            )?;
            let session = pool.CreateCaptureSession(&item)?;
            session.SetIsCursorCaptureEnabled(true)?;
            session.StartCapture()?;
            Ok(Self {
                session,
                pool,
                width: size.Width as u32,
                height: size.Height as u32,
            })
        }
    }
    fn next(&self) -> Result<Option<(Direct3D11CaptureFrame, ID3D11Texture2D)>> {
        unsafe {
            let frame = match self.pool.TryGetNextFrame() {
                Ok(f) => f,
                Err(e) if e.code().0 == 0x80004003u32 as i32 => return Ok(None),
                Err(e) => return Err(e.into()),
            };
            let mut frame = frame;
            if let Ok(newer) = self.pool.TryGetNextFrame() {
                frame.Close()?;
                frame = newer;
            }
            let size = frame.ContentSize()?;
            ensure!(
                size.Width as u32 == self.width && size.Height as u32 == self.height,
                "Display geometry changed; recreate capture"
            );
            let access: IDirect3DDxgiInterfaceAccess = frame.Surface()?.cast()?;
            let texture: ID3D11Texture2D = access.GetInterface()?;
            Ok(Some((frame, texture)))
        }
    }
}
impl Drop for Capture {
    fn drop(&mut self) {
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}
/// Own on a dedicated MTA worker; serialize capture, video conversion and NVENC calls.
pub struct CaptureEncoder {
    encoder: Nvenc,
    converter: Converter,
    output: ID3D11Texture2D,
    capture: Option<Capture>,
    synthetic: Option<(ID3D11Texture2D, ID3D11RenderTargetView)>,
    gpu: Gpu,
    width: u32,
    height: u32,
    source_width: u32,
    source_height: u32,
    first: bool,
    frame_index: u64,
    has_image: bool,
    last_encoded: Option<Instant>,
    display_id: u32,
    last_recovery: Option<Instant>,
    recovery_started: Option<Instant>,
    last_timings: super::MediaTimings,
    _apartment: Apartment,
}
impl CaptureEncoder {
    pub fn new(display_id: u32, width: u32, height: u32, fps: u32, bitrate: u32) -> Result<Self> {
        gpu::validate(width, height, fps, bitrate)?;
        let apartment = Apartment::new()?;
        let output = crate::display::outputs()?
            .into_iter()
            .find(|o| o.display.id == display_id)
            .context("Selected NVIDIA display unavailable")?;
        let gpu = Gpu::new(Some(&output.adapter))?;
        let capture = Capture::new(&gpu, output.monitor)?;
        let source_width = capture.width;
        let source_height = capture.height;
        let encoder = Nvenc::new(&gpu.device, width, height, fps, bitrate)?;
        let converter = Converter::new(&gpu, source_width, source_height, width, height)?;
        let target = gpu::texture(
            &gpu.device,
            width,
            height,
            DXGI_FORMAT_NV12,
            D3D11_BIND_RENDER_TARGET.0 as u32,
        )?;
        Ok(Self {
            encoder,
            converter,
            output: target,
            capture: Some(capture),
            synthetic: None,
            gpu,
            width,
            height,
            source_width,
            source_height,
            first: true,
            frame_index: 0,
            has_image: false,
            last_encoded: None,
            display_id,
            last_recovery: None,
            recovery_started: None,
            last_timings: Default::default(),
            _apartment: apartment,
        })
    }
    pub fn synthetic(width: u32, height: u32, fps: u32, bitrate: u32) -> Result<Self> {
        gpu::validate(width, height, fps, bitrate)?;
        let apartment = Apartment::new()?;
        let outputs = crate::display::outputs()?;
        let gpu = Gpu::new(outputs.first().map(|o| &o.adapter))?;
        let encoder = Nvenc::new(&gpu.device, width, height, fps, bitrate)?;
        let converter = Converter::new(&gpu, width, height, width, height)?;
        let output = gpu::texture(
            &gpu.device,
            width,
            height,
            DXGI_FORMAT_NV12,
            D3D11_BIND_RENDER_TARGET.0 as u32,
        )?;
        let input = gpu::texture(
            &gpu.device,
            width,
            height,
            DXGI_FORMAT_B8G8R8A8_UNORM,
            D3D11_BIND_RENDER_TARGET.0 as u32,
        )?;
        let mut view = None;
        unsafe {
            gpu.device
                .CreateRenderTargetView(&input, None, Some(&mut view))?;
        }
        Ok(Self {
            encoder,
            converter,
            output,
            capture: None,
            synthetic: Some((input, view.context("Synthetic target missing")?)),
            gpu,
            width,
            height,
            source_width: width,
            source_height: height,
            first: true,
            frame_index: 0,
            has_image: false,
            last_encoded: None,
            display_id: 0,
            last_recovery: None,
            recovery_started: None,
            last_timings: Default::default(),
            _apartment: apartment,
        })
    }
    pub fn width(&self) -> u32 {
        self.width
    }
    pub fn height(&self) -> u32 {
        self.height
    }
    pub fn last_timings(&self) -> super::MediaTimings {
        self.last_timings
    }
    pub fn frame(&mut self, force_idr: bool, timestamp: u64) -> Result<Option<EncodedFrame>> {
        unsafe {
            let capture_start = Instant::now();
            self.gpu.device.GetDeviceRemovedReason()?;
            if let Some((input, view)) = &self.synthetic {
                self.gpu
                    .context
                    .ClearRenderTargetView(view, &[0.12, 0.12, 0.12, 1.]);
                let context: ID3D11DeviceContext1 = self.gpu.context.cast()?;
                let position =
                    ((self.frame_index * 8) % self.width.saturating_sub(64).max(1) as u64) as i32;
                let bar = windows::Win32::Foundation::RECT {
                    left: position,
                    top: 0,
                    right: position + 64,
                    bottom: self.height as i32,
                };
                context.ClearView(view, &[0.2, 0.6, 0.3, 1.], Some(&[bar]));
                self.converter.convert(
                    input,
                    0,
                    &self.output,
                    gpu::rect(self.width, self.height),
                    gpu::rect(self.width, self.height),
                )?;
            } else {
                if self.capture.is_none() {
                    let now = Instant::now();
                    let start = *self.recovery_started.get_or_insert(now);
                    ensure!(
                        now.duration_since(start) < Duration::from_secs(10),
                        "Capture recovery exceeded ten seconds"
                    );
                    if self
                        .last_recovery
                        .is_some_and(|last| now.duration_since(last) < Duration::from_millis(250))
                    {
                        return Ok(None);
                    }
                    self.last_recovery = Some(now);
                    if let Some(output) = crate::display::outputs()?
                        .into_iter()
                        .find(|o| o.display.id == self.display_id)
                    {
                        if let Ok(capture) = Capture::new(&self.gpu, output.monitor) {
                            self.source_width = capture.width;
                            self.source_height = capture.height;
                            self.converter = Converter::new(
                                &self.gpu,
                                capture.width,
                                capture.height,
                                self.width,
                                self.height,
                            )?;
                            self.capture = Some(capture);
                            self.first = true;
                            self.recovery_started = None;
                        }
                    }
                    return Ok(None);
                }
                let next = self.capture.as_ref().expect("capture state checked").next();
                match next {
                    Ok(Some((frame, input))) => {
                        let converted = self.converter.convert(
                            &input,
                            0,
                            &self.output,
                            gpu::rect(self.source_width, self.source_height),
                            gpu::rect(self.width, self.height),
                        );
                        let _ = frame.Close();
                        converted?;
                        self.has_image = true;
                    }
                    Ok(None) => {
                        if !self.has_image
                            || (!force_idr
                                && self
                                    .last_encoded
                                    .is_some_and(|last| last.elapsed() < Duration::from_secs(1)))
                        {
                            return Ok(None);
                        }
                    }
                    Err(_) => {
                        self.capture = None;
                        self.has_image = false;
                        self.recovery_started = Some(Instant::now());
                        return Ok(None);
                    }
                }
            }
            self.last_timings.capture_ms = capture_start.elapsed().as_secs_f64() * 1000.;
            let encode_start = Instant::now();
            let frame = self
                .encoder
                .encode(&self.output, force_idr || self.first, timestamp)?;
            self.last_timings.encode_ms = encode_start.elapsed().as_secs_f64() * 1000.;
            self.first = false;
            self.frame_index += 1;
            self.last_encoded = Some(Instant::now());
            Ok(Some(frame))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "Requires an unlocked interactive NVIDIA display"]
    fn wgc_recovers_after_real_pool_invalidation() {
        let display = crate::enumerate_displays()
            .unwrap()
            .into_iter()
            .next()
            .unwrap();
        let mut encoder = CaptureEncoder::new(display.id, 1920, 1080, 60, 18_000_000).unwrap();
        let origin = Instant::now();
        let mut received = false;
        while origin.elapsed() < Duration::from_secs(3) {
            if encoder
                .frame(true, origin.elapsed().as_micros() as u64 + 1)
                .unwrap()
                .is_some()
            {
                received = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(16));
        }
        assert!(received, "Initial WGC frame unavailable");
        encoder.capture.as_ref().unwrap().pool.Close().unwrap();
        let start = Instant::now();
        let mut recovered = false;
        while start.elapsed() < Duration::from_secs(5) {
            if let Some(frame) = encoder
                .frame(true, origin.elapsed().as_micros() as u64 + 1)
                .unwrap()
            {
                assert!(frame.keyframe);
                recovered = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(16));
        }
        assert!(recovered, "WGC pool did not recover within five seconds");
    }
}

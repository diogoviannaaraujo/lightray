use super::{
    gpu::{self, Converter, Gpu},
    EncodedFrame, VideoConfig,
};
use anyhow::{bail, ensure, Context, Result};
use std::{ffi::c_void, mem::ManuallyDrop};
use windows::{
    core::Interface,
    Win32::{
        Graphics::{
            Direct3D11::*,
            Dxgi::{Common::*, *},
        },
        Media::MediaFoundation::*,
        System::{
            Com::{CoCreateInstance, CLSCTX_INPROC_SERVER},
            WinRT::{RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED},
        },
    },
};
struct Runtime(std::marker::PhantomData<std::rc::Rc<()>>);
impl Runtime {
    fn new() -> Result<Self> {
        unsafe {
            RoInitialize(RO_INIT_MULTITHREADED)?;
            if let Err(error) = MFStartup(MF_VERSION, MFSTARTUP_FULL) {
                RoUninitialize();
                return Err(error.into());
            }
        }
        Ok(Self(std::marker::PhantomData))
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        unsafe {
            let _ = MFShutdown();
            RoUninitialize();
        }
    }
}
/// Hardware-only HEVC decoder and GPU video processor. No uncompressed CPU buffer path.
pub struct DecoderRenderer {
    transform: IMFTransform,
    _manager: IMFDXGIDeviceManager,
    chain: IDXGISwapChain1,
    gpu: Gpu,
    converter: Option<Converter>,
    config: Option<VideoConfig>,
    width: u32,
    height: u32,
    needs_keyframe: bool,
    last_timings: super::MediaTimings,
    _runtime: Runtime,
}
impl DecoderRenderer {
    pub fn new(width: u32, height: u32) -> Result<Self> {
        unsafe {
            ensure!(
                width > 0 && height > 0 && width <= 7680 && height <= 4320,
                "Invalid renderer size"
            );
            let runtime = Runtime::new()?;
            let gpu = Gpu::new(None)?;
            let video: ID3D11VideoDevice = gpu.device.cast()?;
            let count = video.GetVideoDecoderProfileCount();
            let mut hevc = false;
            for i in 0..count {
                let profile = video.GetVideoDecoderProfile(i)?;
                if profile == D3D11_DECODER_PROFILE_HEVC_VLD_MAIN {
                    hevc = true;
                    break;
                }
            }
            ensure!(hevc, "GPU does not support HEVC Main hardware decoding");
            let transform = discover_hevc_transform()?;
            let attributes = transform.GetAttributes()?;
            ensure!(
                attributes.GetUINT32(&MF_SA_D3D11_AWARE).unwrap_or(0) != 0,
                "Installed HEVC decoder has no D3D11 hardware path"
            );
            attributes.SetUINT32(&MF_LOW_LATENCY, 1)?;
            let mut token = 0;
            let mut manager = None;
            MFCreateDXGIDeviceManager(&mut token, &mut manager)?;
            let manager = manager.context("DXGI device manager missing")?;
            manager.ResetDevice(&gpu.device, token)?;
            transform.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, manager.as_raw() as usize)?;
            let factory: IDXGIFactory2 = CreateDXGIFactory1()?;
            let desc = DXGI_SWAP_CHAIN_DESC1 {
                Width: width,
                Height: height,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC {
                    Count: 1,
                    Quality: 0,
                },
                BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
                BufferCount: 2,
                Scaling: DXGI_SCALING_STRETCH,
                SwapEffect: DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
                AlphaMode: DXGI_ALPHA_MODE_IGNORE,
                ..Default::default()
            };
            let chain = factory.CreateSwapChainForComposition(&gpu.device, &desc, None)?;
            Ok(Self {
                transform,
                _manager: manager,
                chain,
                gpu,
                converter: None,
                config: None,
                width,
                height,
                needs_keyframe: true,
                last_timings: Default::default(),
                _runtime: runtime,
            })
        }
    }
    /// Returns a COM reference owned by the caller. Release after attaching to SwapChainPanel.
    pub fn swap_chain(&self) -> *mut c_void {
        self.chain.clone().into_raw()
    }
    pub fn resize(&mut self, width: u32, height: u32) -> Result<()> {
        ensure!(
            width > 0 && height > 0 && width <= 7680 && height <= 4320,
            "Invalid renderer size"
        );
        unsafe {
            self.gpu.context.ClearState();
            self.chain.ResizeBuffers(
                2,
                width,
                height,
                DXGI_FORMAT_B8G8R8A8_UNORM,
                DXGI_SWAP_CHAIN_FLAG(0),
            )?;
        }
        self.width = width;
        self.height = height;
        self.converter = None;
        Ok(())
    }
    pub fn is_device_lost(&self) -> bool {
        unsafe { self.gpu.device.GetDeviceRemovedReason().is_err() }
    }
    pub fn reset(&mut self) -> Result<()> {
        unsafe {
            self.transform
                .ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0)?;
        }
        self.needs_keyframe = true;
        Ok(())
    }
    fn configure(&mut self, config: &VideoConfig) -> Result<()> {
        unsafe {
            ensure!(
                config.width > 0
                    && config.height > 0
                    && config.width <= 7680
                    && config.height <= 4320,
                "Invalid coded video dimensions"
            );
            if self.config.as_ref() == Some(config) {
                return Ok(());
            }
            self.transform
                .ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0)?;
            let input = MFCreateMediaType()?;
            input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            input.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_HEVC)?;
            input.SetUINT64(
                &MF_MT_FRAME_SIZE,
                ((config.width as u64) << 32) | config.height as u64,
            )?;
            input.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            self.transform.SetInputType(0, &input, 0)?;
            self.select_output()?;
            self.transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
            self.transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
            self.config = Some(config.clone());
            self.converter = None;
            self.needs_keyframe = true;
            Ok(())
        }
    }
    fn select_output(&mut self) -> Result<()> {
        unsafe {
            for index in 0..64 {
                let kind = match self.transform.GetOutputAvailableType(0, index) {
                    Ok(t) => t,
                    Err(e) if e.code() == MF_E_NO_MORE_TYPES => break,
                    Err(e) => return Err(e.into()),
                };
                if kind.GetGUID(&MF_MT_SUBTYPE)? == MFVideoFormat_NV12 {
                    self.transform.SetOutputType(0, &kind, 0)?;
                    let info = self.transform.GetOutputStreamInfo(0)?;
                    ensure!(
                        info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32 != 0,
                        "HEVC decoder did not provide GPU surfaces; software fallback disabled"
                    );
                    return Ok(());
                }
            }
            bail!("HEVC decoder cannot negotiate NV12 GPU output")
        }
    }
    pub fn last_timings(&self) -> super::MediaTimings {
        self.last_timings
    }
    pub fn decode(&mut self, frame: &EncodedFrame) -> Result<bool> {
        unsafe {
            self.last_timings = Default::default();
            let decode_start = std::time::Instant::now();
            if let Some(config) = &frame.config {
                self.configure(config)?;
            }
            if self.config.is_none() || self.needs_keyframe && !frame.keyframe {
                return Ok(false);
            }
            let mut bytes = Vec::new();
            if frame.keyframe {
                let config = self.config.as_ref().context("HEVC configuration missing")?;
                for nal in [&config.vps, &config.sps, &config.pps] {
                    ensure!(
                        nal.len() >= 2 && nal.len() <= 65535,
                        "Invalid HEVC parameter set"
                    );
                    bytes.extend_from_slice(&[0, 0, 0, 1]);
                    bytes.extend_from_slice(nal);
                }
            }
            bytes.extend_from_slice(&length_prefixed_to_annex_b(&frame.data)?);
            ensure!(
                bytes.len() <= 4 * 1024 * 1024,
                "Video access unit too large"
            );
            let sample = MFCreateSample()?;
            let buffer = MFCreateMemoryBuffer(bytes.len() as u32)?;
            let mut data = std::ptr::null_mut();
            buffer.Lock(&mut data, None, None)?;
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), data, bytes.len());
            buffer.Unlock()?;
            buffer.SetCurrentLength(bytes.len() as u32)?;
            sample.AddBuffer(&buffer)?;
            sample.SetSampleTime(frame.timestamp.min(i64::MAX as u64 / 10) as i64 * 10)?;
            sample.SetSampleDuration(166667)?;
            sample.SetUINT32(&MFSampleExtension_CleanPoint, frame.keyframe as u32)?;
            let mut rendered = false;
            match self.transform.ProcessInput(0, &sample, 0) {
                Ok(()) => (),
                Err(e) if e.code() == MF_E_NOTACCEPTING => {
                    rendered |= self.drain()?;
                    self.transform.ProcessInput(0, &sample, 0)?;
                }
                Err(e) => return Err(e.into()),
            };
            self.needs_keyframe = false;
            rendered |= self.drain()?;
            self.last_timings.decode_ms = (decode_start.elapsed().as_secs_f64() * 1000.
                - self.last_timings.present_ms)
                .max(0.);
            Ok(rendered)
        }
    }
    fn drain(&mut self) -> Result<bool> {
        unsafe {
            let mut rendered = false;
            for _ in 0..8 {
                let mut output = MFT_OUTPUT_DATA_BUFFER::default();
                let mut status = 0;
                let result =
                    self.transform
                        .ProcessOutput(0, std::slice::from_mut(&mut output), &mut status);
                // MFT_OUTPUT_DATA_BUFFER's raw COM fields are manually dropped by generated bindings.
                let sample = ManuallyDrop::take(&mut output.pSample);
                ManuallyDrop::drop(&mut output.pEvents);
                match result {
                    Ok(()) => {
                        if let Some(sample) = sample {
                            self.render(&sample)?;
                            rendered = true;
                        }
                    }
                    Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(rendered),
                    Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                        self.select_output()?;
                        self.converter = None;
                    }
                    Err(e) => {
                        self.needs_keyframe = true;
                        return Err(e.into());
                    }
                }
            }
            bail!("HEVC decoder exceeded bounded eight-sample output queue")
        }
    }
    fn render(&mut self, sample: &IMFSample) -> Result<()> {
        unsafe {
            let present_start = std::time::Instant::now();
            let buffer = sample.GetBufferByIndex(0)?;
            let dxgi: IMFDXGIBuffer = buffer
                .cast()
                .context("HEVC decoder returned CPU pixels; hardware-only decoding required")?;
            let mut ptr = std::ptr::null_mut();
            dxgi.GetResource(&ID3D11Texture2D::IID, &mut ptr)?;
            let texture = ID3D11Texture2D::from_raw(ptr);
            let subresource = dxgi.GetSubresourceIndex()?;
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            texture.GetDesc(&mut desc);
            ensure!(
                desc.Format == DXGI_FORMAT_NV12,
                "HEVC decoder returned unsupported GPU format"
            );
            let kind = self.transform.GetOutputCurrentType(0)?;
            let packed = kind.GetUINT64(&MF_MT_FRAME_SIZE)?;
            let coded_width = (packed >> 32) as u32;
            let coded_height = packed as u32;
            let mut source = gpu::rect(coded_width, coded_height);
            let mut area = MFVideoArea::default();
            let mut actual = 0;
            let bytes = std::slice::from_raw_parts_mut(
                (&mut area as *mut MFVideoArea).cast::<u8>(),
                std::mem::size_of::<MFVideoArea>(),
            );
            if kind
                .GetBlob(&MF_MT_MINIMUM_DISPLAY_APERTURE, bytes, Some(&mut actual))
                .is_ok()
                || kind
                    .GetBlob(&MF_MT_GEOMETRIC_APERTURE, bytes, Some(&mut actual))
                    .is_ok()
            {
                ensure!(
                    actual as usize == std::mem::size_of::<MFVideoArea>()
                        && area.OffsetX.fract == 0
                        && area.OffsetY.fract == 0
                        && area.OffsetX.value >= 0
                        && area.OffsetY.value >= 0
                        && area.Area.cx > 0
                        && area.Area.cy > 0,
                    "Unsupported decoder display aperture"
                );
                source.left = area.OffsetX.value as i32;
                source.top = area.OffsetY.value as i32;
                source.right = source.left + area.Area.cx;
                source.bottom = source.top + area.Area.cy;
            }
            ensure!(
                source.right <= desc.Width as i32 && source.bottom <= desc.Height as i32,
                "Decoder aperture exceeds GPU surface"
            );
            if self.converter.is_none() {
                self.converter = Some(Converter::new(
                    &self.gpu,
                    desc.Width,
                    desc.Height,
                    self.width,
                    self.height,
                )?);
            }
            let backbuffer: ID3D11Texture2D = self.chain.GetBuffer(0)?;
            let mut target = None;
            self.gpu
                .device
                .CreateRenderTargetView(&backbuffer, None, Some(&mut target))?;
            self.gpu.context.ClearRenderTargetView(
                target.as_ref().context("Swap chain target missing")?,
                &[0., 0., 0., 1.],
            );
            let ratio = (self.width as f64 / (source.right - source.left) as f64)
                .min(self.height as f64 / (source.bottom - source.top) as f64);
            let width = ((source.right - source.left) as f64 * ratio)
                .round()
                .max(1.) as i32;
            let height = ((source.bottom - source.top) as f64 * ratio)
                .round()
                .max(1.) as i32;
            let left = (self.width as i32 - width) / 2;
            let top = (self.height as i32 - height) / 2;
            let destination = windows::Win32::Foundation::RECT {
                left,
                top,
                right: left + width,
                bottom: top + height,
            };
            self.converter
                .as_ref()
                .context("GPU converter missing")?
                .convert(
                    &texture,
                    subresource / desc.MipLevels,
                    &backbuffer,
                    source,
                    destination,
                )?;
            self.chain.Present(0, DXGI_PRESENT(0)).ok()?;
            self.gpu.device.GetDeviceRemovedReason()?;
            self.last_timings.present_ms += present_start.elapsed().as_secs_f64() * 1000.;
            Ok(())
        }
    }
}
impl Drop for DecoderRenderer {
    fn drop(&mut self) {
        unsafe {
            let _ = self
                .transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            let _ = self.transform.ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        }
    }
}
fn length_prefixed_to_annex_b(bytes: &[u8]) -> Result<Vec<u8>> {
    let mut output = Vec::with_capacity(bytes.len());
    let mut position = 0;
    while position < bytes.len() {
        ensure!(bytes.len() - position >= 4, "Truncated HEVC NAL length");
        let length = u32::from_be_bytes(bytes[position..position + 4].try_into()?) as usize;
        position += 4;
        ensure!(
            length >= 2 && length <= bytes.len() - position,
            "Invalid HEVC NAL length"
        );
        output.extend_from_slice(&[0, 0, 0, 1]);
        output.extend_from_slice(&bytes[position..position + length]);
        position += length;
    }
    ensure!(!output.is_empty(), "Empty HEVC access unit");
    Ok(output)
}
fn discover_hevc_transform() -> Result<IMFTransform> {
    use windows::Win32::System::Com::CoTaskMemFree;
    unsafe {
        let input = MFT_REGISTER_TYPE_INFO {
            guidMajorType: MFMediaType_Video,
            guidSubtype: MFVideoFormat_HEVC,
        };
        let output = MFT_REGISTER_TYPE_INFO {
            guidMajorType: MFMediaType_Video,
            guidSubtype: MFVideoFormat_NV12,
        };
        let mut array = std::ptr::null_mut();
        let mut count = 0;
        MFTEnumEx(
            MFT_CATEGORY_VIDEO_DECODER,
            MFT_ENUM_FLAG_ALL | MFT_ENUM_FLAG_SORTANDFILTER,
            Some(&input),
            Some(&output),
            &mut array,
            &mut count,
        )?;
        let mut candidates = Vec::new();
        if !array.is_null() {
            for index in 0..count {
                if let Some(activate) = std::ptr::read(array.add(index as usize)) {
                    candidates.push(activate);
                }
            }
            CoTaskMemFree(Some(array.cast()));
        }
        let mut errors = Vec::new();
        for activate in candidates {
            match activate.ActivateObject::<IMFTransform>() {
                Ok(transform) => {
                    let attributes = match transform.GetAttributes() {
                        Ok(value) => value,
                        Err(error) => {
                            errors.push(format!("Decoder attributes unavailable: {error}"));
                            continue;
                        }
                    };
                    if attributes.GetUINT32(&MF_SA_D3D11_AWARE).unwrap_or(0) == 0 {
                        errors.push("Decoder lacks D3D11 hardware support".to_owned());
                        continue;
                    }
                    if attributes.GetUINT32(&MF_TRANSFORM_ASYNC).unwrap_or(0) != 0 {
                        errors.push("Decoder requires asynchronous MFT scheduling".to_owned());
                        continue;
                    }
                    return Ok(transform);
                }
                Err(error) => errors.push(format!("Activation failed: {error}")),
            }
        }
        if let Ok(transform) =
            CoCreateInstance::<_, IMFTransform>(&CLSID_MSH265DecoderMFT, None, CLSCTX_INPROC_SERVER)
        {
            return Ok(transform);
        }
        bail!("No usable HEVC D3D11 decoder found ({count} registered transforms; {}). Install or repair Microsoft HEVC Video Extensions and update the graphics driver.",errors.join("; "))
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn framing_validation() {
        assert_eq!(
            super::length_prefixed_to_annex_b(&[0, 0, 0, 2, 38, 1]).unwrap(),
            [0, 0, 0, 1, 38, 1]
        );
        for bytes in [&[][..], &[0, 0, 0][..], &[0, 0, 0, 255, 1, 2][..]] {
            assert!(super::length_prefixed_to_annex_b(bytes).is_err());
        }
    }
}

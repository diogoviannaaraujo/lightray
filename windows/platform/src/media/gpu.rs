use anyhow::{ensure, Context, Result};
use std::mem::ManuallyDrop;
use windows::{
    core::Interface,
    Win32::{
        Foundation::{HMODULE, RECT},
        Graphics::{
            Direct3D::D3D_DRIVER_TYPE_UNKNOWN,
            Direct3D10::ID3D10Multithread,
            Direct3D11::*,
            Dxgi::{Common::*, *},
        },
    },
};
pub(super) struct Gpu {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
}
impl Gpu {
    pub fn new(adapter: Option<&IDXGIAdapter1>) -> Result<Self> {
        unsafe {
            let owned;
            if let Some(value) = adapter {
                owned = value.clone();
            } else {
                let factory: IDXGIFactory1 = CreateDXGIFactory1()?;
                let mut index = 0;
                loop {
                    let value = factory
                        .EnumAdapters1(index)
                        .context("No hardware GPU available")?;
                    index += 1;
                    let desc = value.GetDesc1()?;
                    if desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32 == 0 {
                        owned = value;
                        break;
                    }
                }
            }
            let mut device = None;
            let mut context = None;
            D3D11CreateDevice(
                &owned,
                D3D_DRIVER_TYPE_UNKNOWN,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )?;
            let device = device.context("D3D11 device missing")?;
            let context = context.context("D3D11 context missing")?;
            let dxgi: IDXGIDevice1 = device.cast()?;
            dxgi.SetMaximumFrameLatency(1)?;
            let lock: ID3D10Multithread = device.cast()?;
            let _ = lock.SetMultithreadProtected(true);
            Ok(Self { device, context })
        }
    }
}
pub(super) fn texture(
    device: &ID3D11Device,
    width: u32,
    height: u32,
    format: DXGI_FORMAT,
    bind: u32,
) -> Result<ID3D11Texture2D> {
    unsafe {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: width,
            Height: height,
            MipLevels: 1,
            ArraySize: 1,
            Format: format,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: bind,
            ..Default::default()
        };
        let mut value = None;
        device.CreateTexture2D(&desc, None, Some(&mut value))?;
        value.context("GPU texture missing")
    }
}
pub(super) struct Converter {
    video: ID3D11VideoDevice,
    context: ID3D11VideoContext,
    enumerator: ID3D11VideoProcessorEnumerator,
    processor: ID3D11VideoProcessor,
}
impl Converter {
    pub fn new(
        gpu: &Gpu,
        input_width: u32,
        input_height: u32,
        width: u32,
        height: u32,
    ) -> Result<Self> {
        unsafe {
            let video: ID3D11VideoDevice = gpu.device.cast()?;
            let context: ID3D11VideoContext = gpu.context.cast()?;
            let desc = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
                InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
                InputWidth: input_width,
                InputHeight: input_height,
                OutputWidth: width,
                OutputHeight: height,
                InputFrameRate: DXGI_RATIONAL {
                    Numerator: 60,
                    Denominator: 1,
                },
                OutputFrameRate: DXGI_RATIONAL {
                    Numerator: 60,
                    Denominator: 1,
                },
                Usage: D3D11_VIDEO_USAGE_PLAYBACK_NORMAL,
            };
            let enumerator = video.CreateVideoProcessorEnumerator(&desc)?;
            let processor = video.CreateVideoProcessor(&enumerator, 0)?;
            context.VideoProcessorSetStreamFrameFormat(
                &processor,
                0,
                D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
            );
            context.VideoProcessorSetStreamAutoProcessingMode(&processor, 0, false);
            Ok(Self {
                video,
                context,
                enumerator,
                processor,
            })
        }
    }
    pub fn convert(
        &self,
        input: &ID3D11Texture2D,
        array_slice: u32,
        output: &ID3D11Texture2D,
        source: RECT,
        destination: RECT,
    ) -> Result<()> {
        unsafe {
            let input_desc = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
                ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
                Anonymous: D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 {
                    Texture2D: D3D11_TEX2D_VPIV {
                        MipSlice: 0,
                        ArraySlice: array_slice,
                    },
                },
                ..Default::default()
            };
            let output_desc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
                ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
                ..Default::default()
            };
            let mut input_view = None;
            let mut output_view = None;
            self.video.CreateVideoProcessorInputView(
                input,
                &self.enumerator,
                &input_desc,
                Some(&mut input_view),
            )?;
            self.video.CreateVideoProcessorOutputView(
                output,
                &self.enumerator,
                &output_desc,
                Some(&mut output_view),
            )?;
            self.context
                .VideoProcessorSetStreamSourceRect(&self.processor, 0, true, Some(&source));
            self.context.VideoProcessorSetStreamDestRect(
                &self.processor,
                0,
                true,
                Some(&destination),
            );
            self.context.VideoProcessorSetOutputTargetRect(
                &self.processor,
                true,
                Some(&destination),
            );
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            input.GetDesc(&mut desc);
            let mut input_color = D3D11_VIDEO_PROCESSOR_COLOR_SPACE::default();
            let mut output_color = D3D11_VIDEO_PROCESSOR_COLOR_SPACE::default();
            // Bit layout: usage0, RGB range1, matrix2, xvYCC3, nominal range4..5.
            if desc.Format == DXGI_FORMAT_NV12 {
                input_color._bitfield = 4 | (1 << 4);
                output_color._bitfield = 4 | (2 << 4);
            } else {
                input_color._bitfield = 4 | (2 << 4);
                output_color._bitfield = 4 | (1 << 4);
            }
            self.context
                .VideoProcessorSetStreamColorSpace(&self.processor, 0, &input_color);
            self.context
                .VideoProcessorSetOutputColorSpace(&self.processor, &output_color);
            let view = input_view.context("Video input view missing")?;
            let mut stream = D3D11_VIDEO_PROCESSOR_STREAM {
                Enable: true.into(),
                pInputSurface: ManuallyDrop::new(Some(view)),
                ..Default::default()
            };
            let result = self.context.VideoProcessorBlt(
                &self.processor,
                output_view.as_ref().context("Video output view missing")?,
                0,
                std::slice::from_ref(&stream),
            );
            ManuallyDrop::drop(&mut stream.pInputSurface);
            result?;
            Ok(())
        }
    }
}
pub(super) fn validate(width: u32, height: u32, fps: u32, bitrate: u32) -> Result<()> {
    ensure!(
        (64..=7680).contains(&width)
            && (64..=4320).contains(&height)
            && width.is_multiple_of(2)
            && height.is_multiple_of(2),
        "Streaming dimensions must be even and between 64x64 and 7680x4320"
    );
    ensure!(
        (1..=240).contains(&fps) && (1_000_000..=200_000_000).contains(&bitrate),
        "Invalid stream frame rate or bitrate"
    );
    Ok(())
}
pub(super) fn rect(width: u32, height: u32) -> RECT {
    RECT {
        left: 0,
        top: 0,
        right: width as i32,
        bottom: height as i32,
    }
}

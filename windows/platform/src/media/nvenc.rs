use super::{EncodedFrame, VideoConfig};
use anyhow::{bail, ensure, Context, Result};
use libloading::Library;
use moq_nvenc::sys::nvEncodeAPI::*;
use std::{ffi::c_void, ptr};
use windows::{core::Interface, Win32::Graphics::Direct3D11::*};
fn nv(status: NVENCSTATUS, operation: &str) -> Result<()> {
    ensure!(
        status == NVENCSTATUS::NV_ENC_SUCCESS,
        "{operation}: NVIDIA status {status:?}"
    );
    Ok(())
}
/// Serialized native NVENC session; D3D11 input never leaves GPU memory.
pub(super) struct Nvenc {
    api: NV_ENCODE_API_FUNCTION_LIST,
    session: *mut c_void,
    registered: *mut c_void,
    bitstream: *mut c_void,
    texture: ID3D11Texture2D,
    context: ID3D11DeviceContext,
    width: u32,
    height: u32,
    _library: Library,
}
impl Nvenc {
    pub(super) fn new(
        device: &ID3D11Device,
        width: u32,
        height: u32,
        fps: u32,
        bitrate: u32,
    ) -> Result<Self> {
        unsafe {
            let system = std::env::var_os("SystemRoot").context("Windows directory unavailable")?;
            let library =
                Library::new(std::path::PathBuf::from(system).join("System32/nvEncodeAPI64.dll"))
                    .context("NVIDIA NVENC driver unavailable")?;
            let create: libloading::Symbol<
                unsafe extern "C" fn(*mut NV_ENCODE_API_FUNCTION_LIST) -> NVENCSTATUS,
            > = library.get(b"NvEncodeAPICreateInstance\0")?;
            let mut api: NV_ENCODE_API_FUNCTION_LIST = std::mem::zeroed();
            api.version = NV_ENCODE_API_FUNCTION_LIST_VER;
            nv(create(&mut api), "Create native NVENC API")?;
            let texture = super::gpu::texture(
                device,
                width,
                height,
                windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_NV12,
                0,
            )?;
            let mut state = Self {
                api,
                session: ptr::null_mut(),
                registered: ptr::null_mut(),
                bitstream: ptr::null_mut(),
                texture,
                context: device.GetImmediateContext()?,
                width,
                height,
                _library: library,
            };
            let mut open: NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS = std::mem::zeroed();
            open.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
            open.apiVersion = NVENCAPI_VERSION;
            open.deviceType = NV_ENC_DEVICE_TYPE::NV_ENC_DEVICE_TYPE_DIRECTX;
            open.device = device.as_raw();
            nv(
                state
                    .api
                    .nvEncOpenEncodeSessionEx
                    .context("NVENC open entry missing")?(
                    &mut open, &mut state.session
                ),
                "Open native NVENC D3D11 session",
            )?;
            let mut storage = std::mem::MaybeUninit::<NV_ENC_PRESET_CONFIG>::zeroed();
            std::ptr::addr_of_mut!((*storage.as_mut_ptr()).presetCfg.frameFieldMode)
                .write(NV_ENC_PARAMS_FRAME_FIELD_MODE::NV_ENC_PARAMS_FRAME_FIELD_MODE_FRAME);
            let mut preset = storage.assume_init();
            preset.version = NV_ENC_PRESET_CONFIG_VER;
            preset.presetCfg.version = NV_ENC_CONFIG_VER;
            nv(
                state
                    .api
                    .nvEncGetEncodePresetConfigEx
                    .context("NVENC preset entry missing")?(
                    state.session,
                    NV_ENC_CODEC_HEVC_GUID,
                    NV_ENC_PRESET_P1_GUID,
                    NV_ENC_TUNING_INFO::NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY,
                    &mut preset,
                ),
                "Read HEVC low latency preset",
            )?;
            let mut config = preset.presetCfg;
            config.profileGUID = NV_ENC_HEVC_PROFILE_MAIN_GUID;
            config.gopLength = NVENC_INFINITE_GOPLENGTH;
            config.frameIntervalP = 1;
            config.rcParams.rateControlMode = NV_ENC_PARAMS_RC_MODE::NV_ENC_PARAMS_RC_CBR;
            config.rcParams.averageBitRate = bitrate;
            config.rcParams.maxBitRate = bitrate;
            config.rcParams.vbvBufferSize = bitrate / fps;
            config.rcParams.vbvInitialDelay = bitrate / fps;
            config.rcParams.set_enableLookahead(0);
            config.rcParams.set_zeroReorderDelay(1);
            config.rcParams.lookaheadDepth = 0;
            let hevc = &mut config.encodeCodecConfig.hevcConfig;
            hevc.idrPeriod = NVENC_INFINITE_GOPLENGTH;
            hevc.set_repeatSPSPPS(1);
            hevc.set_chromaFormatIDC(1);
            hevc.hevcVUIParameters.videoSignalTypePresentFlag = 1;
            hevc.hevcVUIParameters.videoFormat =
                NV_ENC_VUI_VIDEO_FORMAT::NV_ENC_VUI_VIDEO_FORMAT_UNSPECIFIED;
            hevc.hevcVUIParameters.videoFullRangeFlag = 0;
            hevc.hevcVUIParameters.colourDescriptionPresentFlag = 1;
            hevc.hevcVUIParameters.colourPrimaries =
                NV_ENC_VUI_COLOR_PRIMARIES::NV_ENC_VUI_COLOR_PRIMARIES_BT709;
            hevc.hevcVUIParameters.transferCharacteristics =
                NV_ENC_VUI_TRANSFER_CHARACTERISTIC::NV_ENC_VUI_TRANSFER_CHARACTERISTIC_BT709;
            hevc.hevcVUIParameters.colourMatrix =
                NV_ENC_VUI_MATRIX_COEFFS::NV_ENC_VUI_MATRIX_COEFFS_BT709;
            let mut init: NV_ENC_INITIALIZE_PARAMS = std::mem::zeroed();
            init.version = NV_ENC_INITIALIZE_PARAMS_VER;
            init.encodeGUID = NV_ENC_CODEC_HEVC_GUID;
            init.presetGUID = NV_ENC_PRESET_P1_GUID;
            init.tuningInfo = NV_ENC_TUNING_INFO::NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
            init.encodeWidth = width;
            init.darWidth = width;
            init.encodeHeight = height;
            init.darHeight = height;
            init.frameRateNum = fps;
            init.frameRateDen = 1;
            init.enablePTD = 1;
            init.encodeConfig = &mut config;
            nv(
                state
                    .api
                    .nvEncInitializeEncoder
                    .context("NVENC initialize entry missing")?(
                    state.session, &mut init
                ),
                "Initialize HEVC Main encoder",
            )?;
            let mut resource: NV_ENC_REGISTER_RESOURCE = std::mem::zeroed();
            resource.version = NV_ENC_REGISTER_RESOURCE_VER;
            resource.resourceType = NV_ENC_INPUT_RESOURCE_TYPE::NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX;
            resource.resourceToRegister = state.texture.as_raw();
            resource.width = width;
            resource.height = height;
            resource.bufferFormat = NV_ENC_BUFFER_FORMAT::NV_ENC_BUFFER_FORMAT_NV12;
            resource.bufferUsage = NV_ENC_BUFFER_USAGE::NV_ENC_INPUT_IMAGE;
            nv(
                state
                    .api
                    .nvEncRegisterResource
                    .context("NVENC register entry missing")?(
                    state.session, &mut resource
                ),
                "Register NV12 GPU texture",
            )?;
            state.registered = resource.registeredResource;
            let mut out: NV_ENC_CREATE_BITSTREAM_BUFFER = std::mem::zeroed();
            out.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
            nv(
                state
                    .api
                    .nvEncCreateBitstreamBuffer
                    .context("NVENC bitstream entry missing")?(
                    state.session, &mut out
                ),
                "Create NVENC bitstream",
            )?;
            state.bitstream = out.bitstreamBuffer;
            Ok(state)
        }
    }
    pub(super) fn encode(
        &mut self,
        texture: &ID3D11Texture2D,
        idr: bool,
        timestamp: u64,
    ) -> Result<EncodedFrame> {
        unsafe {
            self.context.CopyResource(&self.texture, texture);
            let mut map: NV_ENC_MAP_INPUT_RESOURCE = std::mem::zeroed();
            map.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
            map.registeredResource = self.registered;
            nv(
                (self.api.nvEncMapInputResource.context("Missing map API")?)(
                    self.session,
                    &mut map,
                ),
                "Map NVENC input",
            )?;
            let result = (|| -> Result<EncodedFrame> {
                let mut storage = std::mem::MaybeUninit::<NV_ENC_PIC_PARAMS>::zeroed();
                std::ptr::addr_of_mut!((*storage.as_mut_ptr()).pictureStruct)
                    .write(NV_ENC_PIC_STRUCT::NV_ENC_PIC_STRUCT_FRAME);
                let mut picture = storage.assume_init();
                picture.version = NV_ENC_PIC_PARAMS_VER;
                picture.inputBuffer = map.mappedResource;
                picture.bufferFmt = NV_ENC_BUFFER_FORMAT::NV_ENC_BUFFER_FORMAT_NV12;
                picture.inputWidth = self.width;
                picture.inputHeight = self.height;
                picture.outputBitstream = self.bitstream;
                picture.pictureStruct = NV_ENC_PIC_STRUCT::NV_ENC_PIC_STRUCT_FRAME;
                picture.inputTimeStamp = timestamp;
                picture.inputDuration = 1;
                if idr {
                    picture.encodePicFlags = NV_ENC_PIC_FLAGS::NV_ENC_PIC_FLAG_FORCEIDR as u32
                        | NV_ENC_PIC_FLAGS::NV_ENC_PIC_FLAG_OUTPUT_SPSPPS as u32;
                }
                nv(
                    (self.api.nvEncEncodePicture.context("Missing encode API")?)(
                        self.session,
                        &mut picture,
                    ),
                    "Encode HEVC frame",
                )?;
                let mut storage = std::mem::MaybeUninit::<NV_ENC_LOCK_BITSTREAM>::zeroed();
                std::ptr::addr_of_mut!((*storage.as_mut_ptr()).pictureStruct)
                    .write(NV_ENC_PIC_STRUCT::NV_ENC_PIC_STRUCT_FRAME);
                let mut lock = storage.assume_init();
                lock.version = NV_ENC_LOCK_BITSTREAM_VER;
                lock.outputBitstream = self.bitstream;
                nv(
                    (self.api.nvEncLockBitstream.context("Missing lock API")?)(
                        self.session,
                        &mut lock,
                    ),
                    "Wait for native HEVC bitstream",
                )?;
                let output = if lock.bitstreamBufferPtr.is_null()
                    || lock.bitstreamSizeInBytes == 0
                    || lock.bitstreamSizeInBytes > 4 * 1024 * 1024
                {
                    Err(anyhow::anyhow!("Invalid native encoder output"))
                } else {
                    parse_annex_b(
                        std::slice::from_raw_parts(
                            lock.bitstreamBufferPtr as *const u8,
                            lock.bitstreamSizeInBytes as usize,
                        ),
                        self.width,
                        self.height,
                        timestamp,
                    )
                };
                let unlocked = nv(
                    (self
                        .api
                        .nvEncUnlockBitstream
                        .context("Missing unlock API")?)(
                        self.session, self.bitstream
                    ),
                    "Unlock native bitstream",
                );
                unlocked?;
                output
            })();
            nv(
                (self
                    .api
                    .nvEncUnmapInputResource
                    .context("Missing unmap API")?)(
                    self.session, map.mappedResource
                ),
                "Unmap NVENC input",
            )?;
            result
        }
    }
}
impl Drop for Nvenc {
    fn drop(&mut self) {
        unsafe {
            if !self.session.is_null() {
                if !self.registered.is_null() {
                    if let Some(f) = self.api.nvEncUnregisterResource {
                        let _ = f(self.session, self.registered);
                    }
                }
                if !self.bitstream.is_null() {
                    if let Some(f) = self.api.nvEncDestroyBitstreamBuffer {
                        let _ = f(self.session, self.bitstream);
                    }
                }
                if let Some(f) = self.api.nvEncDestroyEncoder {
                    let _ = f(self.session);
                }
            }
        }
    }
}
pub(super) fn parse_annex_b(
    bytes: &[u8],
    width: u32,
    height: u32,
    timestamp: u64,
) -> Result<EncodedFrame> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= bytes.len() {
        if bytes[i..].starts_with(&[0, 0, 0, 1]) {
            starts.push((i, i + 4));
            i += 4;
        } else if bytes[i..].starts_with(&[0, 0, 1]) {
            starts.push((i, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    ensure!(!starts.is_empty(), "HEVC output contains no start codes");
    let mut config = VideoConfig {
        width,
        height,
        vps: vec![],
        sps: vec![],
        pps: vec![],
    };
    let mut data = Vec::new();
    let mut keyframe = false;
    for (index, &(_, start)) in starts.iter().enumerate() {
        let end = starts.get(index + 1).map(|x| x.0).unwrap_or(bytes.len());
        let mut nal = &bytes[start..end];
        while nal.last() == Some(&0) {
            nal = &nal[..nal.len() - 1];
        }
        if nal.len() < 2 {
            bail!("Truncated HEVC NAL");
        }
        let ty = (nal[0] >> 1) & 63;
        match ty {
            32 => config.vps = nal.to_vec(),
            33 => config.sps = nal.to_vec(),
            34 => config.pps = nal.to_vec(),
            _ => {
                if (16..=21).contains(&ty) {
                    keyframe = true;
                }
                data.extend_from_slice(&(nal.len() as u32).to_be_bytes());
                data.extend_from_slice(nal);
            }
        }
    }
    let has_config = !config.vps.is_empty() && !config.sps.is_empty() && !config.pps.is_empty();
    ensure!(!keyframe || has_config, "IDR missing parameter sets");
    Ok(EncodedFrame {
        data,
        config: has_config.then_some(config),
        keyframe,
        timestamp,
    })
}

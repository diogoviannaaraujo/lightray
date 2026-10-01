#define NOMINMAX
#include "nvenc_encoder.hpp"
#include <windows.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include "../vendor/nv-codec-headers/nvEncodeAPI.h"
#include <chrono>
#include <iostream>
#include <limits>
#include <string>

namespace lightray {
using Microsoft::WRL::ComPtr;
using Clock = std::chrono::steady_clock;
static void hr(HRESULT status, const char* action) {
    if (FAILED(status)) throw std::runtime_error(std::string(action) + " HRESULT " + std::to_string(status));
}
static void nv(NVENCSTATUS status, const char* action) {
    if (status != NV_ENC_SUCCESS) throw std::runtime_error(std::string(action) + " NVENC status " + std::to_string(status));
}
static void validate(EncoderSettings settings) {
    if (settings.width < 64 || settings.width > 3840 || settings.height < 64 || settings.height > 2160 || settings.width % 2 || settings.height % 2 || settings.bitrate < 1000000 || settings.bitrate > 200000000 || !settings.fps || settings.fps > 240) throw std::invalid_argument("Invalid encoder settings");
}
static HMODULE driver_module() {
    // Keep one driver module loaded for process lifetime; sessions/resources still close explicitly.
    static const auto module = [] {
        const auto handle = LoadLibraryExW(L"nvEncodeAPI64.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!handle) throw std::runtime_error("NVIDIA encoder driver library unavailable");
        return handle;
    }();
    return module;
}
struct NvencEncoder::Impl {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11Texture2D> texture;
    NV_ENCODE_API_FUNCTION_LIST api{};
    void* session = nullptr;
    NV_ENC_REGISTERED_PTR registered = nullptr;
    NV_ENC_INPUT_PTR mapped = nullptr;
    NV_ENC_OUTPUT_PTR bitstream = nullptr;
    bool locked = false;
    std::uint32_t driver_api = 0;
    EncoderSettings settings;
    bool has_timestamp = false;
    std::uint64_t last_timestamp = 0;
    explicit Impl(ID3D11Device* value, EncoderSettings options) : device(value), settings(options) {}
    void initialize() {
        const auto width = settings.width, height = settings.height;
        device->GetImmediateContext(&context);
        ComPtr<IDXGIDevice> dxgi;
        hr(device.As(&dxgi), "Query DXGI device");
        ComPtr<IDXGIAdapter> adapter;
        hr(dxgi->GetAdapter(&adapter), "Query device adapter");
        DXGI_ADAPTER_DESC desc{};
        hr(adapter->GetDesc(&desc), "Query adapter description");
        if (desc.VendorId != 0x10de) throw std::runtime_error("NVENC requires an NVIDIA device");
        const auto library = driver_module();
        // FARPROC conversion is the documented dynamic API loading boundary.
#pragma warning(push)
#pragma warning(disable: 4191)
        auto version_fn = reinterpret_cast<NVENCSTATUS (NVENCAPI*)(std::uint32_t*)>(GetProcAddress(library, "NvEncodeAPIGetMaxSupportedVersion"));
        auto create_fn = reinterpret_cast<NVENCSTATUS (NVENCAPI*)(NV_ENCODE_API_FUNCTION_LIST*)>(GetProcAddress(library, "NvEncodeAPICreateInstance"));
#pragma warning(pop)
        if (!version_fn || !create_fn) throw std::runtime_error("Missing NVIDIA encoder entry points");

        nv(version_fn(&driver_api), "Query driver API");
        if (driver_api < ((NVENCAPI_MAJOR_VERSION << 4) | NVENCAPI_MINOR_VERSION)) throw std::runtime_error("Driver does not support pinned NVENC API");
        api.version = NV_ENCODE_API_FUNCTION_LIST_VER;
        nv(create_fn(&api), "Create NVENC API table");
        NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS open{};
        open.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
        open.apiVersion = NVENCAPI_VERSION;
        open.deviceType = NV_ENC_DEVICE_TYPE_DIRECTX;
        open.device = device.Get();
        nv(api.nvEncOpenEncodeSessionEx(&open, &session), "Open D3D11 NVENC session");
        NV_ENC_PRESET_CONFIG preset{};
        preset.version = NV_ENC_PRESET_CONFIG_VER;
        preset.presetCfg.version = NV_ENC_CONFIG_VER;
        nv(api.nvEncGetEncodePresetConfigEx(session, NV_ENC_CODEC_HEVC_GUID, NV_ENC_PRESET_P1_GUID, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &preset), "Get HEVC P1 ULL preset");
        auto config = preset.presetCfg;
        config.profileGUID = NV_ENC_HEVC_PROFILE_MAIN_GUID;
        config.gopLength = NVENC_INFINITE_GOPLENGTH;
        config.frameIntervalP = 1;
        config.rcParams.rateControlMode = NV_ENC_PARAMS_RC_CBR;
        config.rcParams.averageBitRate = settings.bitrate;
        config.rcParams.maxBitRate = config.rcParams.averageBitRate;
        config.rcParams.vbvBufferSize = config.rcParams.averageBitRate / settings.fps;
        config.rcParams.vbvInitialDelay = config.rcParams.vbvBufferSize;
        config.rcParams.enableLookahead = 0;
        config.rcParams.lookaheadDepth = 0;
        config.rcParams.zeroReorderDelay = 1;
        config.encodeCodecConfig.hevcConfig.idrPeriod = NVENC_INFINITE_GOPLENGTH;
        config.encodeCodecConfig.hevcConfig.repeatSPSPPS = 1;
        config.encodeCodecConfig.hevcConfig.chromaFormatIDC = 1;
        config.encodeCodecConfig.hevcConfig.inputBitDepth = NV_ENC_BIT_DEPTH_8;
        config.encodeCodecConfig.hevcConfig.outputBitDepth = NV_ENC_BIT_DEPTH_8;
        if (settings.bt709_limited) {
            auto& vui=config.encodeCodecConfig.hevcConfig.hevcVUIParameters;
            vui.videoSignalTypePresentFlag = 1;
            vui.videoFormat = NV_ENC_VUI_VIDEO_FORMAT_UNSPECIFIED;
            vui.videoFullRangeFlag = 0;
            vui.colourDescriptionPresentFlag = 1;
            vui.colourPrimaries = NV_ENC_VUI_COLOR_PRIMARIES_BT709;
            vui.transferCharacteristics = NV_ENC_VUI_TRANSFER_CHARACTERISTIC_BT709;
            vui.colourMatrix = NV_ENC_VUI_MATRIX_COEFFS_BT709;
        }
        NV_ENC_INITIALIZE_PARAMS init{};
        init.version = NV_ENC_INITIALIZE_PARAMS_VER;
        init.encodeGUID = NV_ENC_CODEC_HEVC_GUID;
        init.presetGUID = NV_ENC_PRESET_P1_GUID;
        init.tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
        init.encodeWidth = init.darWidth = width;
        init.encodeHeight = init.darHeight = height;
        init.frameRateNum = settings.fps;
        init.frameRateDen = 1;
        init.enablePTD = 1;
        init.enableEncodeAsync = 0;
        init.encodeConfig = &config;
        nv(api.nvEncInitializeEncoder(session, &init), "Initialize native HEVC encoder");
        D3D11_TEXTURE2D_DESC texture_desc{};
        texture_desc.Width = width;
        texture_desc.Height = height;
        texture_desc.MipLevels = texture_desc.ArraySize = 1;
        texture_desc.Format = DXGI_FORMAT_NV12;
        texture_desc.SampleDesc.Count = 1;
        texture_desc.Usage = D3D11_USAGE_DEFAULT;
        hr(device->CreateTexture2D(&texture_desc, nullptr, &texture), "Create owned NV12 texture");
        NV_ENC_REGISTER_RESOURCE resource{};
        resource.version = NV_ENC_REGISTER_RESOURCE_VER;
        resource.resourceType = NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX;
        resource.resourceToRegister = texture.Get();
        resource.width = width;
        resource.height = height;
        resource.bufferFormat = NV_ENC_BUFFER_FORMAT_NV12;
        resource.bufferUsage = NV_ENC_INPUT_IMAGE;
        nv(api.nvEncRegisterResource(session, &resource), "Register GPU input texture");
        registered = resource.registeredResource;
        NV_ENC_CREATE_BITSTREAM_BUFFER create{};
        create.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
        nv(api.nvEncCreateBitstreamBuffer(session, &create), "Create output bitstream buffer");
        bitstream = create.bitstreamBuffer;
    }
    bool close() noexcept {
        bool ok = true;
        auto check = [&](NVENCSTATUS code) { if (code != NV_ENC_SUCCESS) { std::cerr << "NVENC cleanup status " << code << '\n'; ok = false; } };
        if (locked) { check(api.nvEncUnlockBitstream(session, bitstream)); locked = false; }
        if (mapped) { check(api.nvEncUnmapInputResource(session, mapped)); mapped = nullptr; }
        if (registered) { check(api.nvEncUnregisterResource(session, registered)); registered = nullptr; }
        if (bitstream) { check(api.nvEncDestroyBitstreamBuffer(session, bitstream)); bitstream = nullptr; }
        if (session) { check(api.nvEncDestroyEncoder(session)); session = nullptr; }
        return ok;
    }
    void drain() {
        NV_ENC_PIC_PARAMS eos{};
        eos.version = NV_ENC_PIC_PARAMS_VER;
        eos.encodePicFlags = NV_ENC_PIC_FLAG_EOS;
        nv(api.nvEncEncodePicture(session, &eos), "Flush encoder");
    }
    ~Impl() { if (!close()) std::cerr << "NVENC cleanup failed\n"; }
};
NvencEncoder::NvencEncoder(ID3D11Device* device, EncoderSettings settings) {
    validate(settings);
    if (!device) throw std::invalid_argument("Missing D3D11 device");
    impl_ = std::make_unique<Impl>(device, settings);
    impl_->initialize();
}
NvencEncoder::~NvencEncoder() { if (!close()) std::cerr << "NVENC component teardown failed\n"; }
void NvencEncoder::advance_generation() {
    if (generation_ == std::numeric_limits<std::uint64_t>::max()) throw std::runtime_error("Encoder generation exhausted");
    ++generation_;
}
bool NvencEncoder::active() const noexcept { return impl_ != nullptr && !paused_; }
std::uint32_t NvencEncoder::driver_api() const {
    if (!impl_) throw std::logic_error("Encoder closed");
    return impl_->driver_api;
}
void NvencEncoder::request_idr() {
    if (!impl_) throw std::logic_error("Encoder closed");
    force_idr_ = true;
}
void NvencEncoder::pause() {
    if (!impl_) throw std::logic_error("Encoder closed");
    if (!paused_) { advance_generation(); paused_ = true; force_idr_ = true; }
}
void NvencEncoder::resume() {
    if (!impl_) throw std::logic_error("Encoder closed");
    paused_ = false;
}
bool NvencEncoder::close() noexcept {
    if (!impl_) return true;
    bool ok = true;
    try { impl_->drain(); } catch (const std::exception& error) { std::cerr << error.what() << '\n'; ok = false; }
    if (!impl_->close()) ok = false;
    impl_.reset();
    paused_ = false;
    if (generation_ < std::numeric_limits<std::uint64_t>::max()) ++generation_;
    return ok;
}
void NvencEncoder::reconfigure(EncoderSettings settings) {
    validate(settings);
    if (!impl_) throw std::logic_error("Encoder closed");
    if (generation_ == std::numeric_limits<std::uint64_t>::max()) throw std::runtime_error("Encoder generation exhausted");
    auto device = impl_->device;
    const bool was_paused = paused_;
    if (!close()) throw std::runtime_error("Reconfiguration teardown failed");
    // Recreate deliberately: no unsupported in-place resolution assumptions or double sessions.
    auto next = std::make_unique<Impl>(device.Get(), settings);
    next->initialize();
    impl_ = std::move(next);
    paused_ = was_paused;
    force_idr_ = true;
}
NvencFrame NvencEncoder::encode(ID3D11Texture2D* input, std::uint64_t timestamp, std::uint64_t generation) {
    if (!active() || generation != generation_) throw std::logic_error("Closed, paused or stale encoder generation");
    if (!input) throw std::invalid_argument("Missing input surface");
    auto& state = *impl_;
    D3D11_TEXTURE2D_DESC desc{};
    input->GetDesc(&desc);
    ComPtr<ID3D11Device> input_device;
    input->GetDevice(&input_device);
    if (input_device.Get() != state.device.Get() || desc.Width != state.settings.width || desc.Height != state.settings.height || desc.Format != DXGI_FORMAT_NV12 || desc.MipLevels != 1 || desc.ArraySize != 1 || desc.SampleDesc.Count != 1) throw std::invalid_argument("Input surface does not match encoder device or configuration");
    if (state.has_timestamp && timestamp <= state.last_timestamp) throw std::invalid_argument("Input timestamps must increase");
    try {
        state.context->CopyResource(state.texture.Get(), input);
        hr(state.device->GetDeviceRemovedReason(), "Validate D3D11 device");
        NV_ENC_MAP_INPUT_RESOURCE map{};
        map.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
        map.registeredResource = state.registered;
        nv(state.api.nvEncMapInputResource(state.session, &map), "Map GPU input");
        state.mapped = map.mappedResource;
        NV_ENC_PIC_PARAMS picture{};
        picture.version = NV_ENC_PIC_PARAMS_VER;
        picture.inputBuffer = state.mapped;
        picture.bufferFmt = NV_ENC_BUFFER_FORMAT_NV12;
        picture.inputWidth = state.settings.width;
        picture.inputHeight = state.settings.height;
        picture.outputBitstream = state.bitstream;
        picture.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
        picture.inputTimeStamp = timestamp;
        picture.inputDuration = 1;
        if (force_idr_) picture.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS;
        const auto before = Clock::now();
        nv(state.api.nvEncEncodePicture(state.session, &picture), "Encode frame");
        NV_ENC_LOCK_BITSTREAM lock{};
        lock.version = NV_ENC_LOCK_BITSTREAM_VER;
        lock.outputBitstream = state.bitstream;
        nv(state.api.nvEncLockBitstream(state.session, &lock), "Wait for encoded frame");
        state.locked = true;
        const auto elapsed = std::chrono::duration<double, std::milli>(Clock::now() - before).count();
        if (lock.outputTimeStamp != timestamp || !lock.bitstreamBufferPtr || !lock.bitstreamSizeInBytes || lock.bitstreamSizeInBytes > 4 * 1024 * 1024 || (lock.pictureType != NV_ENC_PIC_TYPE_IDR && lock.pictureType != NV_ENC_PIC_TYPE_P)) throw std::runtime_error("Invalid or delayed encoder output");
        NvencFrame result;
        const auto* bytes = static_cast<const std::uint8_t*>(lock.bitstreamBufferPtr);
        result.annex_b.assign(bytes, bytes + lock.bitstreamSizeInBytes);
        result.unit = from_annex_b(result.annex_b);
        if ((force_idr_ && !result.unit.idr) || result.unit.idr != (lock.pictureType == NV_ENC_PIC_TYPE_IDR) || result.unit.payload.size() > 4 * 1024 * 1024) throw std::runtime_error("Unexpected encoder picture or payload size");
        result.generation = generation_;
        result.timestamp = timestamp;
        result.encode_and_lock_ms = elapsed;
        result.hardware_status_raw = lock.hwEncodeStatus;
        nv(state.api.nvEncUnlockBitstream(state.session, state.bitstream), "Unlock bitstream");
        state.locked = false;
        nv(state.api.nvEncUnmapInputResource(state.session, state.mapped), "Unmap input");
        state.mapped = nullptr;
        state.last_timestamp = timestamp;
        state.has_timestamp = true;
        force_idr_ = false;
        return result;
    } catch (...) {
        // Driver/output errors are terminal. Destruction releases any mapped or locked resource.
        if (!state.close()) std::cerr << "NVENC failed-session cleanup failed\n";
        impl_.reset();
        if (generation_ < std::numeric_limits<std::uint64_t>::max()) ++generation_;
        throw;
    }
}
}

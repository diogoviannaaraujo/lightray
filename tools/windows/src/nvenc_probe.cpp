// NVENC recovery scenarios, driven through the CUDA driver API so that nothing but the NVIDIA
// driver is needed at run time (nv-codec-headers loads nvcuda and nvEncodeAPI dynamically).
//
//   idr            frame 46 is a forced IDR
//   rfi            before frame 46, frames 40..45 are invalidated (nvEncInvalidateRefFrames)
//   ltr            frame 30 is marked long-term; frame 46 may use only that long-term reference
//   intra-refresh  frame 46 starts a 30-frame intra refresh wave instead of an IDR
#include <ffnvcodec/dynlink_loader.h>

#include <chrono>
#include <cstring>
#include <functional>
#include <memory>

#include "common.h"

namespace probe {

namespace {

const char* statusName(NVENCSTATUS s) {
    switch (s) {
    case NV_ENC_SUCCESS: return "NV_ENC_SUCCESS";
    case NV_ENC_ERR_UNSUPPORTED_PARAM: return "NV_ENC_ERR_UNSUPPORTED_PARAM";
    case NV_ENC_ERR_INVALID_PARAM: return "NV_ENC_ERR_INVALID_PARAM";
    case NV_ENC_ERR_INVALID_VERSION: return "NV_ENC_ERR_INVALID_VERSION";
    case NV_ENC_ERR_UNSUPPORTED_DEVICE: return "NV_ENC_ERR_UNSUPPORTED_DEVICE";
    case NV_ENC_ERR_NO_ENCODE_DEVICE: return "NV_ENC_ERR_NO_ENCODE_DEVICE";
    case NV_ENC_ERR_OUT_OF_MEMORY: return "NV_ENC_ERR_OUT_OF_MEMORY";
    default: return "NVENC error";
    }
}

class Nvenc {
public:
    ~Nvenc() { close(); }

    bool open(std::string& err) {
        if (cuda_load_functions(&cu_, nullptr) < 0) { err = "cannot load the CUDA driver (nvcuda)"; return false; }
        if (nvenc_load_functions(&nvf_, nullptr) < 0) { err = "cannot load nvEncodeAPI"; return false; }
        uint32_t maxVersion = 0;
        nvf_->NvEncodeAPIGetMaxSupportedVersion(&maxVersion);
        const uint32_t built = (NVENCAPI_MAJOR_VERSION << 4) | NVENCAPI_MINOR_VERSION;
        if (built > maxVersion) {
            err = "the driver supports NVENC API " + std::to_string(maxVersion >> 4) + "." + std::to_string(maxVersion & 0xf) +
                  ", this probe needs " + std::to_string(NVENCAPI_MAJOR_VERSION) + "." + std::to_string(NVENCAPI_MINOR_VERSION);
            return false;
        }
        CUdevice dev = 0;
        char name[256] = {};
        if (cu_->cuInit(0) != CUDA_SUCCESS || cu_->cuDeviceGet(&dev, 0) != CUDA_SUCCESS) { err = "no CUDA device"; return false; }
        cu_->cuDeviceGetName(name, sizeof name, dev);
        device = name;
        if (cu_->cuCtxCreate(&ctx_, 0, dev) != CUDA_SUCCESS) { err = "cannot create a CUDA context"; return false; }
        fn_.version = NV_ENCODE_API_FUNCTION_LIST_VER;
        if (nvf_->NvEncodeAPICreateInstance(&fn_) != NV_ENC_SUCCESS) { err = "NvEncodeAPICreateInstance failed"; return false; }
        return true;
    }

    // Runs one scenario on a fresh encoder session.
    bool run(const Settings& s, const std::string& scenario, Result& r, std::string& err) {
        r.encoder = "nvenc";
        r.device = device;
        r.scenario = scenario;
        const bool ltr = scenario == "ltr", rfi = scenario == "rfi", ir = scenario == "intra-refresh";

        NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS op = {};
        op.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
        op.device = ctx_;
        op.deviceType = NV_ENC_DEVICE_TYPE_CUDA;
        op.apiVersion = NVENCAPI_VERSION;
        void* enc = nullptr;
        NVENCSTATUS st = fn_.nvEncOpenEncodeSessionEx(&op, &enc);
        if (st != NV_ENC_SUCCESS) { err = std::string("nvEncOpenEncodeSessionEx: ") + statusName(st); return false; }
        std::unique_ptr<void, std::function<void(void*)>> guard(enc, [this](void* e) { fn_.nvEncDestroyEncoder(e); });

        NV_ENC_PRESET_CONFIG pc = {};
        pc.version = NV_ENC_PRESET_CONFIG_VER;
        pc.presetCfg.version = NV_ENC_CONFIG_VER;
        st = fn_.nvEncGetEncodePresetConfigEx(enc, NV_ENC_CODEC_HEVC_GUID, NV_ENC_PRESET_P4_GUID, NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &pc);
        if (st != NV_ENC_SUCCESS) { err = std::string("nvEncGetEncodePresetConfigEx: ") + statusName(st); return false; }
        NV_ENC_CONFIG cfg = pc.presetCfg;
        cfg.gopLength = NVENC_INFINITE_GOPLENGTH;
        cfg.frameIntervalP = 1;
        cfg.rcParams.rateControlMode = NV_ENC_PARAMS_RC_CBR;
        cfg.rcParams.averageBitRate = static_cast<uint32_t>(s.bitrate);
        cfg.rcParams.maxBitRate = static_cast<uint32_t>(s.bitrate);
        cfg.rcParams.vbvBufferSize = static_cast<uint32_t>(s.bitrate / s.fps);
        cfg.rcParams.vbvInitialDelay = cfg.rcParams.vbvBufferSize;
        NV_ENC_CONFIG_HEVC& hevc = cfg.encodeCodecConfig.hevcConfig;
        hevc.idrPeriod = NVENC_INFINITE_GOPLENGTH;
        hevc.repeatSPSPPS = 1;
        hevc.maxNumRefFramesInDPB = 8;  // invalidation needs an older reference still in the DPB
        if (ltr) {
            hevc.enableLTR = 1;
            hevc.ltrTrustMode = 0;  // per-picture marking
            hevc.ltrNumFrames = 2;
        }
        if (ir) {
            hevc.enableIntraRefresh = 1;
            hevc.intraRefreshPeriod = 100000;  // no periodic waves; one is forced on demand at frame 46
            hevc.intraRefreshCnt = 30;
            hevc.outputRecoveryPointSEI = 1;
        }

        NV_ENC_INITIALIZE_PARAMS ip = {};
        ip.version = NV_ENC_INITIALIZE_PARAMS_VER;
        ip.encodeGUID = NV_ENC_CODEC_HEVC_GUID;
        ip.presetGUID = NV_ENC_PRESET_P4_GUID;
        ip.tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
        ip.encodeWidth = ip.darWidth = ip.maxEncodeWidth = static_cast<uint32_t>(s.width);
        ip.encodeHeight = ip.darHeight = ip.maxEncodeHeight = static_cast<uint32_t>(s.height);
        ip.frameRateNum = static_cast<uint32_t>(s.fps);
        ip.frameRateDen = 1;
        ip.enablePTD = 1;
        ip.encodeConfig = &cfg;
        st = fn_.nvEncInitializeEncoder(enc, &ip);
        if (st != NV_ENC_SUCCESS) { err = std::string("nvEncInitializeEncoder: ") + statusName(st); return false; }

        NV_ENC_CREATE_INPUT_BUFFER ib = {};
        ib.version = NV_ENC_CREATE_INPUT_BUFFER_VER;
        ib.width = static_cast<uint32_t>(s.width);
        ib.height = static_cast<uint32_t>(s.height);
        ib.bufferFmt = NV_ENC_BUFFER_FORMAT_NV12;
        st = fn_.nvEncCreateInputBuffer(enc, &ib);
        if (st != NV_ENC_SUCCESS) { err = std::string("nvEncCreateInputBuffer: ") + statusName(st); return false; }
        NV_ENC_CREATE_BITSTREAM_BUFFER bb = {};
        bb.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
        st = fn_.nvEncCreateBitstreamBuffer(enc, &bb);
        if (st != NV_ENC_SUCCESS) { err = std::string("nvEncCreateBitstreamBuffer: ") + statusName(st); return false; }

        DesktopFrames frames(s.width, s.height);
        double encodeMs = 0;
        for (int i = 0; i < kFrames; ++i) {
            const Nv12& f = frames.frame(i);
            NV_ENC_LOCK_INPUT_BUFFER li = {};
            li.version = NV_ENC_LOCK_INPUT_BUFFER_VER;
            li.inputBuffer = ib.inputBuffer;
            if ((st = fn_.nvEncLockInputBuffer(enc, &li)) != NV_ENC_SUCCESS) { err = std::string("nvEncLockInputBuffer: ") + statusName(st); return false; }
            auto* dst = static_cast<uint8_t*>(li.bufferDataPtr);
            for (int y = 0; y < s.height; ++y) std::memcpy(dst + static_cast<size_t>(y) * li.pitch, &f.y[static_cast<size_t>(y) * s.width], s.width);
            uint8_t* uvDst = dst + static_cast<size_t>(li.pitch) * s.height;
            for (int y = 0; y < s.height / 2; ++y) std::memcpy(uvDst + static_cast<size_t>(y) * li.pitch, &f.uv[static_cast<size_t>(y) * s.width], s.width);
            fn_.nvEncUnlockInputBuffer(enc, ib.inputBuffer);

            NV_ENC_PIC_PARAMS pp = {};
            pp.version = NV_ENC_PIC_PARAMS_VER;
            pp.inputBuffer = ib.inputBuffer;
            pp.bufferFmt = NV_ENC_BUFFER_FORMAT_NV12;
            pp.inputWidth = static_cast<uint32_t>(s.width);
            pp.inputHeight = static_cast<uint32_t>(s.height);
            pp.inputPitch = li.pitch;
            pp.outputBitstream = bb.bitstreamBuffer;
            pp.inputTimeStamp = static_cast<uint64_t>(i);
            pp.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
            NV_ENC_PIC_PARAMS_HEVC& hp = pp.codecPicParams.hevcPicParams;
            if (i == 0 || (scenario == "idr" && i == kRecovery)) pp.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS;
            if (ltr && i == kLtrFrame) { hp.ltrMarkFrame = 1; hp.ltrMarkFrameIdx = 0; }
            if (ltr && i == kRecovery) { hp.ltrUseFrames = 1; hp.ltrUseFrameBitmap = 1; }
            if (ir && i == kRecovery) hp.forceIntraRefreshWithFrameCnt = 30;
            if (rfi && i == kRecovery) {
                for (int t = kLostFirst; t <= kLostLast; ++t) {
                    NVENCSTATUS inv = fn_.nvEncInvalidateRefFrames(enc, static_cast<uint64_t>(t));
                    if (inv != NV_ENC_SUCCESS) r.notes += "nvEncInvalidateRefFrames(" + std::to_string(t) + "): " + statusName(inv) + "; ";
                }
            }
            const auto t0 = std::chrono::steady_clock::now();
            st = fn_.nvEncEncodePicture(enc, &pp);
            if (st != NV_ENC_SUCCESS) { err = "nvEncEncodePicture(" + std::to_string(i) + "): " + statusName(st); return false; }
            NV_ENC_LOCK_BITSTREAM lb = {};
            lb.version = NV_ENC_LOCK_BITSTREAM_VER;
            lb.outputBitstream = bb.bitstreamBuffer;
            if ((st = fn_.nvEncLockBitstream(enc, &lb)) != NV_ENC_SUCCESS) { err = std::string("nvEncLockBitstream: ") + statusName(st); return false; }
            encodeMs += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
            EncodedFrame out;
            const auto* p = static_cast<const uint8_t*>(lb.bitstreamBufferPtr);
            out.annexB.assign(p, p + lb.bitstreamSizeInBytes);
            out.keyframe = lb.pictureType == NV_ENC_PIC_TYPE_IDR || lb.pictureType == NV_ENC_PIC_TYPE_I;
            r.frames.push_back(std::move(out));
            fn_.nvEncUnlockBitstream(enc, bb.bitstreamBuffer);
        }
        fn_.nvEncDestroyInputBuffer(enc, ib.inputBuffer);
        fn_.nvEncDestroyBitstreamBuffer(enc, bb.bitstreamBuffer);
        r.notes += "HEVC P4 ultra-low-latency CBR, DPB 8; mean encode+lock " + std::to_string(encodeMs / kFrames) + " ms";
        return true;
    }

    std::string device;

private:
    void close() {
        if (ctx_ && cu_) cu_->cuCtxDestroy(ctx_);
        ctx_ = nullptr;
        if (nvf_) nvenc_free_functions(&nvf_);
        if (cu_) cuda_free_functions(&cu_);
    }

    CudaFunctions* cu_ = nullptr;
    NvencFunctions* nvf_ = nullptr;
    CUcontext ctx_ = nullptr;
    NV_ENCODE_API_FUNCTION_LIST fn_ = {};
};

}  // namespace

std::vector<std::string> nvencScenarios() { return {"idr", "rfi", "ltr", "intra-refresh"}; }

bool runNvenc(const Settings& s, const std::vector<std::string>& scenarios, std::string& err) {
    Nvenc nv;
    if (!nv.open(err)) return false;
    std::printf("NVENC on %s\n", nv.device.c_str());
    for (const auto& sc : scenarios) {
        Result r;
        std::string e;
        if (!nv.run(s, sc, r, e)) { std::printf("  %-14s FAILED: %s\n", sc.c_str(), e.c_str()); continue; }
        if (!writeResult(s, r, e)) { std::printf("  %-14s %s\n", sc.c_str(), e.c_str()); continue; }
        std::printf("  %-14s frame 46: %zu bytes, %s\n", sc.c_str(), r.frames[kRecovery].annexB.size(), r.frames[kRecovery].keyframe ? "keyframe" : "predicted");
    }
    return true;
}

}  // namespace probe

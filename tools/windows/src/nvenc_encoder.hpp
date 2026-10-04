#pragma once
#include <d3d11.h>
#include <cstdint>
#include <memory>
#include "hevc_annexb.hpp"

namespace lightray {
struct EncoderSettings {
    unsigned width = 1920;
    unsigned height = 1080;
    unsigned bitrate = 20000000;
    unsigned fps = 60;
    bool bt709_limited = false;
};
struct NvencFrame {
    AccessUnit unit;
    Bytes annex_b;
    std::uint64_t generation = 0;
    std::uint64_t timestamp = 0;
    double encode_and_lock_ms = 0;
    std::uint32_t hardware_status_raw = 0;
};
// Single-owner synchronous component. Serialize calls and immediate-context work externally.
// Input must be an NV12 texture on the same device. A GPU copy isolates its lifetime.
// One registered input and one bitstream buffer; no callbacks or pending output on return.
class NvencEncoder {
public:
    NvencEncoder(ID3D11Device* device, EncoderSettings settings);
    ~NvencEncoder();
    NvencEncoder(const NvencEncoder&) = delete;
    NvencEncoder& operator=(const NvencEncoder&) = delete;
    NvencFrame encode(ID3D11Texture2D* input, std::uint64_t timestamp, std::uint64_t generation);
    void request_idr();
    void pause();
    void resume();
    void reconfigure(EncoderSettings settings);
    bool close() noexcept;
    std::uint64_t generation() const noexcept { return generation_; }
    std::uint32_t driver_api() const;
    bool active() const noexcept;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    std::uint64_t generation_ = 1;
    bool paused_ = false;
    bool force_idr_ = true;
    void advance_generation();
};
}

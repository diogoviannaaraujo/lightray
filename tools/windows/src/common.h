// Shared pieces of the Windows recovery probe: the scenario every encoder runs, the synthetic
// desktop frames it encodes, and the manifest format the Mac verifier reads
// (tools/probes/apple/verify at commit 3cf4c28).
#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace probe {

// Frames 40..45 never reach the receiver; frame 46 is the encoder's answer. Matches the
// VideoToolbox reference streams written by `verify-recovery generate`.
constexpr int kFrames = 120;
constexpr int kLostFirst = 40;
constexpr int kLostLast = 45;
constexpr int kRecovery = 46;
constexpr int kLtrFrame = 30;  // the long-term reference the receiver has decoded and acknowledged

struct Settings {
    int width = 1920;
    int height = 1080;
    int fps = 60;
    int bitrate = 20'000'000;
    std::string outDir = "recovery";
};

struct EncodedFrame {
    std::vector<uint8_t> annexB;  // HEVC Annex B, as the encoder produced it
    bool keyframe = false;
};

struct Result {
    std::string encoder;   // "nvenc" or "qsv"
    std::string device;    // GPU name
    std::string scenario;  // "idr", "rfi", "ltr", "reject", "intra-refresh"
    std::vector<EncodedFrame> frames;
    std::string notes;     // anything the encoder reported that a reader should see
};

// One NV12 frame: Y plane then interleaved UV, tightly packed (pitch == width).
struct Nv12 {
    int width = 0, height = 0;
    std::vector<uint8_t> y, uv;
};

// A desktop with a code editor, a document window and a dock, on which a window is dragged and a
// line of text grows, so every predicted frame carries real motion.
class DesktopFrames {
public:
    DesktopFrames(int width, int height);
    const Nv12& frame(int index);

private:
    Nv12 base_, current_;
    void fillRect(Nv12& f, int x, int y, int w, int h, uint8_t Y, uint8_t U, uint8_t V);
};

// Writes <out>/<encoder>-<scenario>.hevc and .json. Returns false and fills err on failure.
bool writeResult(const Settings& s, const Result& r, std::string& err);

}  // namespace probe

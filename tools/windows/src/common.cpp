#include "common.h"

#include <algorithm>
#include <filesystem>
#include <fstream>

namespace probe {

namespace {

struct Rng {
    uint64_t s;
    uint32_t next() {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return static_cast<uint32_t>(s >> 11);
    }
};

std::string jsonEscape(const std::string& in) {
    std::string out;
    for (char c : in) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof buf, "\\u%04x", c);
                out += buf;
            } else {
                out += c;
            }
        }
    }
    return out;
}

}  // namespace

DesktopFrames::DesktopFrames(int width, int height) {
    base_.width = width;
    base_.height = height;
    base_.y.assign(static_cast<size_t>(width) * height, 0);
    base_.uv.assign(static_cast<size_t>(width) * height / 2, 128);
    // Wallpaper: a luma gradient with a blue-magenta tint.
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) base_.y[static_cast<size_t>(y) * width + x] = static_cast<uint8_t>(50 + (x + y) * 70 / (width + height));
    }
    for (int y = 0; y < height / 2; ++y) {
        for (int x = 0; x < width / 2; ++x) {
            base_.uv[static_cast<size_t>(y) * width + 2 * x] = static_cast<uint8_t>(150 - x * 20 / (width / 2));
            base_.uv[static_cast<size_t>(y) * width + 2 * x + 1] = static_cast<uint8_t>(118 + y * 30 / (height / 2));
        }
    }
    const double sc = width / 1920.0;
    auto px = [sc](int v) { return static_cast<int>(v * sc); };
    Rng rng{0x9E3779B97F4A7C15ull};
    // A dark code editor and a light document, each with a title bar and rows of glyphs.
    struct Win { int x, y, w, h; bool dark; int rowGap; };
    for (const Win& w : {Win{px(60), px(120), px(1000), px(820), true, px(17)}, Win{px(1000), px(200), px(860), px(700), false, px(20)}}) {
        fillRect(base_, w.x, w.y, w.w, w.h, w.dark ? 30 : 235, 128, 128);
        fillRect(base_, w.x, w.y, w.w, px(28), 205, 128, 128);
        for (int ry = w.y + px(40); ry + px(12) < w.y + w.h; ry += w.rowGap) {
            int x = w.x + px(12) + static_cast<int>(rng.next() % 4) * px(24);
            const int glyphs = 12 + static_cast<int>(rng.next() % 48);
            for (int g = 0; g < glyphs && x + px(9) < w.x + w.w - px(12); ++g) {
                if (rng.next() % 6 == 0) { x += px(9); continue; }  // a space
                const uint8_t luma = w.dark ? static_cast<uint8_t>(150 + rng.next() % 90) : static_cast<uint8_t>(20 + rng.next() % 40);
                const uint8_t u = w.dark ? static_cast<uint8_t>(100 + rng.next() % 60) : 128;
                fillRect(base_, x, ry, px(7), px(11), luma, u, static_cast<uint8_t>(256 - u));
                x += px(9);
            }
        }
    }
    // Menu bar and dock.
    fillRect(base_, 0, 0, width, px(30), 225, 128, 128);
    for (int i = 0; i < 16; ++i) {
        fillRect(base_, width / 4 + px(12 + i * 60), height - px(78), px(52), px(52),
                 static_cast<uint8_t>(60 + rng.next() % 160), static_cast<uint8_t>(rng.next() % 256), static_cast<uint8_t>(rng.next() % 256));
    }
    current_ = base_;
}

void DesktopFrames::fillRect(Nv12& f, int x, int y, int w, int h, uint8_t Y, uint8_t U, uint8_t V) {
    const int x0 = std::max(0, x), y0 = std::max(0, y);
    const int x1 = std::min(f.width, x + w), y1 = std::min(f.height, y + h);
    for (int r = y0; r < y1; ++r) std::fill_n(&f.y[static_cast<size_t>(r) * f.width + x0], std::max(0, x1 - x0), Y);
    for (int r = y0 / 2; r < (y1 + 1) / 2; ++r) {
        for (int c = x0 / 2; c < (x1 + 1) / 2; ++c) {
            f.uv[static_cast<size_t>(r) * f.width + 2 * c] = U;
            f.uv[static_cast<size_t>(r) * f.width + 2 * c + 1] = V;
        }
    }
}

const Nv12& DesktopFrames::frame(int i) {
    current_.y = base_.y;
    current_.uv = base_.uv;
    const double sc = base_.width / 1920.0;
    auto px = [sc](int v) { return static_cast<int>(v * sc); };
    const int wx = px(120 + 11 * i), wy = px(380 + 3 * i);
    fillRect(current_, wx, wy, px(420), px(260), 242, 128, 128);    // the dragged window
    fillRect(current_, wx, wy, px(420), px(28), 110, 180, 105);     // its blue title bar
    for (int k = 0; k < i % 40; ++k) {                              // text being typed into it
        fillRect(current_, wx + px(20 + (k % 20) * 19), wy + px(44 + (k / 20) * 22), px(12), px(16), 25, 128, 128);
    }
    return current_;
}

bool writeResult(const Settings& s, const Result& r, std::string& err) {
    namespace fs = std::filesystem;
    std::error_code ec;
    fs::create_directories(s.outDir, ec);
    const fs::path stem = fs::path(s.outDir) / (r.encoder + "-" + r.scenario);
    std::ofstream hevc(stem.string() + ".hevc", std::ios::binary);
    if (!hevc) { err = "cannot write " + stem.string() + ".hevc"; return false; }
    for (const auto& f : r.frames) hevc.write(reinterpret_cast<const char*>(f.annexB.data()), static_cast<std::streamsize>(f.annexB.size()));

    std::ofstream json(stem.string() + ".json");
    if (!json) { err = "cannot write " + stem.string() + ".json"; return false; }
    json << "{\n  \"encoder\" : \"" << jsonEscape(r.encoder) << "\",\n  \"device\" : \"" << jsonEscape(r.device) << "\",\n"
         << "  \"scenario\" : \"" << jsonEscape(r.scenario) << "\",\n  \"width\" : " << s.width << ",\n  \"height\" : " << s.height
         << ",\n  \"fps\" : " << s.fps << ",\n  \"lost\" : [";
    for (int i = kLostFirst; i <= kLostLast; ++i) json << (i > kLostFirst ? ", " : "") << i;
    json << "],\n  \"recovery\" : " << kRecovery << ",\n  \"notes\" : \"" << jsonEscape(r.notes) << "\",\n  \"frames\" : [\n";
    for (size_t i = 0; i < r.frames.size(); ++i) {
        json << "    { \"index\" : " << i << ", \"bytes\" : " << r.frames[i].annexB.size() << ", \"keyframe\" : "
             << (r.frames[i].keyframe ? "true" : "false") << " }" << (i + 1 < r.frames.size() ? "," : "") << "\n";
    }
    json << "  ]\n}\n";
    return true;
}

}  // namespace probe

#pragma once
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace lightray {
inline std::uint32_t refresh_millihertz(std::uint32_t numerator, std::uint32_t denominator) {
    if (!denominator) return 0;
    const auto value = (std::uint64_t(numerator) * 1000 + denominator / 2) / denominator;
    if (value > std::numeric_limits<std::uint32_t>::max()) throw std::runtime_error("Display refresh exceeds wire range");
    return static_cast<std::uint32_t>(value);
}

struct WindowsDisplay {
    std::uint32_t id = 1;
    bool primary = false;
    std::uint32_t width = 0, height = 0, refresh_mhz = 0;
    std::int32_t x = 0, y = 0;
    std::string name = "Windows desktop (NVENC)";
};

inline std::vector<std::uint8_t> display_control(const WindowsDisplay &display) {
    if (!display.id || !display.width || !display.height || display.width > 65535 || display.height > 65535 || display.name.size() > 64)
        throw std::runtime_error("Invalid display metadata");
    std::vector<std::uint8_t> value;
    auto u16 = [&](std::uint32_t v) { value.push_back(static_cast<std::uint8_t>(v >> 8)); value.push_back(static_cast<std::uint8_t>(v)); };
    auto u32 = [&](std::uint32_t v) { u16(v >> 16); u16(v & 65535); };
    u32(display.id);
    value.push_back(display.primary ? 1 : 0);
    u16(display.width); u16(display.height); u32(display.refresh_mhz);
    u32(static_cast<std::uint32_t>(display.x)); u32(static_cast<std::uint32_t>(display.y));
    u32(display.width); u32(display.height);
    value.insert(value.end(), display.name.begin(), display.name.end());
    std::vector<std::uint8_t> control{0xf0, 0, 0, 0, 0, 0, 0xf1, static_cast<std::uint8_t>(value.size() >> 8), static_cast<std::uint8_t>(value.size())};
    control.insert(control.end(), value.begin(), value.end());
    return control;
}
} // namespace lightray

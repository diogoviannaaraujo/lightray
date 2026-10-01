#include "windows_display.hpp"
#include <iostream>
#include <stdexcept>
using lightray::WindowsDisplay;
static void check(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
static std::uint32_t u32(const std::vector<std::uint8_t> &bytes, unsigned offset) {
    return std::uint32_t(bytes.at(offset)) << 24 | std::uint32_t(bytes.at(offset + 1)) << 16 | std::uint32_t(bytes.at(offset + 2)) << 8 | bytes.at(offset + 3);
}
int main() {
    try {
        check(lightray::refresh_millihertz(160, 1) == 160000, "Actual refresh must replace fixed 30 Hz");
        check(lightray::refresh_millihertz(60000, 1001) == 59940, "Fractional display refresh");
        check(lightray::refresh_millihertz(60, 0) == 0, "Unknown refresh is not an invented default");
        bool overflow = false;
        try { (void)lightray::refresh_millihertz(UINT32_MAX, 1); } catch (const std::runtime_error &) { overflow = true; }
        check(overflow, "Refresh wire overflow");
        WindowsDisplay display;
        display.width = 3840; display.height = 2160; display.refresh_mhz = 160000;
        display.x = -3840; display.y = -100; display.primary = true;
        const auto bytes = lightray::display_control(display);
        check(bytes[0] == 0xf0 && bytes[6] == 0xf1 && bytes[13] == 1 && bytes[14] == 15 && bytes[15] == 0 && bytes[16] == 8 && bytes[17] == 112 && u32(bytes, 18) == 160000, "Display fields and physical size");
        check(u32(bytes, 22) == static_cast<std::uint32_t>(-3840) && u32(bytes, 26) == static_cast<std::uint32_t>(-100) && u32(bytes, 30) == 3840, "Signed layout offsets");
        display.width = 0;
        bool invalid = false;
        try { (void)lightray::display_control(display); } catch (const std::runtime_error &) { invalid = true; }
        check(invalid, "Zero display dimensions rejected");
        display.width = 3840; display.name.assign(65, 'x'); invalid = false;
        try { (void)lightray::display_control(display); } catch (const std::runtime_error &) { invalid = true; }
        check(invalid, "Display name wire bound");
        std::cout << "{\"status\":\"passed\",\"cases\":8}\n";
    } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}

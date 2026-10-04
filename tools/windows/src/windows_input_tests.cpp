#define NOMINMAX
#include "windows_input.hpp"
#include <iostream>
#include <vector>

namespace {
std::vector<INPUT> events;
bool accept_injections = true;
bool record(INPUT event) {
    if (accept_injections)
        events.push_back(event);
    return accept_injections;
}
void check(bool condition, const char *description) {
    if (!condition)
        throw std::runtime_error(description);
}
void deliver(lightray::WindowsInput &input, std::initializer_list<std::uint8_t> bytes) {
    input.handle(std::span(bytes.begin(), bytes.size()));
}
} // namespace

int main() {
    try {
        lightray::WindowsInput input({0, 0, 1920, 1080}, record);
        check(lightray::hid_scan(4) == 0x1e && lightray::hid_scan(29) == 0x2c, "Letter mapping");
        check(lightray::hid_scan(30) == 2 && lightray::hid_scan(39) == 0x0b, "Digit mapping");
        check(lightray::hid_scan(79) == 0x14d && lightray::hid_scan(228) == 0x11d, "Extended mapping");
        check(lightray::hid_scan(100) == MapVirtualKeyW(VK_OEM_102, MAPVK_VK_TO_VSC_EX), "ISO key matches Windows layout translation");
        check(lightray::hid_scan(101) == (0x100 | (MapVirtualKeyW(VK_APPS, MAPVK_VK_TO_VSC_EX) & 255)), "Application key matches Windows extended scan");
        for (unsigned i = 0; i < 8; ++i)
            check(lightray::hid_scan(104 + i) == MapVirtualKeyW(VK_F13 + i, MAPVK_VK_TO_VSC_EX), "F13-F20 match Windows layout translation");
        deliver(input, {1, 0, 230, 1});
        check(events.back().ki.wScan == 0x38 && (events.back().ki.dwFlags & KEYEVENTF_EXTENDEDKEY), "Right Option reaches Windows as right Alt");
        deliver(input, {1, 0, 230, 0});
        events.clear();
        deliver(input, {1, 0, 4, 1});
        check(input.held() == 1 && events.back().ki.wScan == 0x1e && events.back().ki.dwFlags == KEYEVENTF_SCANCODE, "Key down");
        deliver(input, {1, 0, 4, 3});
        check(input.held() == 1, "Repeat retains single held key");
        deliver(input, {1, 0, 4, 0});
        check(input.held() == 0 && (events.back().ki.dwFlags & KEYEVENTF_KEYUP), "Key up");
        deliver(input, {1, 0, 228, 1});
        check((events.back().ki.dwFlags & KEYEVENTF_EXTENDEDKEY) != 0, "Right control is extended");
        deliver(input, {0x11, 1, 1});
        check(input.held() == 2 && events.back().mi.dwFlags == MOUSEEVENTF_LEFTDOWN, "Button down");
        const auto before = events.size();
        input.reset();
        check(input.held() == 0 && events.size() == before + 2 && (events[before].ki.dwFlags & KEYEVENTF_KEYUP) && events.back().mi.dwFlags == MOUSEEVENTF_LEFTUP, "Disconnect releases key and button");
        input.reset();
        check(events.size() == before + 2, "Repeated reset is idempotent");
        deliver(input, {0x12, 0, 0, 0, 120, 0});
        check(events.back().mi.dwFlags == MOUSEEVENTF_WHEEL && events.back().mi.mouseData == 120, "Wheel units");
        deliver(input, {0x12, 0, 10, 0, 0, 1});
        check(events.back().mi.dwFlags == MOUSEEVENTF_HWHEEL && static_cast<LONG>(events.back().mi.mouseData) == -30, "Horizontal pixel sign and scale");
        const auto supported = events.size();
        deliver(input, {1, 255, 255, 1});
        check(input.unsupported == 1 && events.size() == supported, "Unsupported usage never injected");
        bool malformed = false;
        try {
            deliver(input, {0x11, 6, 1});
        } catch (const std::invalid_argument &) {
            malformed = true;
        }
        check(malformed && events.size() == supported, "Invalid button rejected");
        accept_injections = false;
        bool failed = false;
        try {
            deliver(input, {1, 0, 4, 1});
        } catch (const std::runtime_error &) {
            failed = true;
        }
        check(failed && input.failures == 1 && input.held() == 0, "Injection failure reported without false held state");
        accept_injections = true;
        std::cout << "{\"status\":\"passed\",\"cases\":19,\"system_input_injected\":false}\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}

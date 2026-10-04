#pragma once
#include <array>
#include <cstdint>
#include <set>
#include <span>
#include <stdexcept>
#include <windows.h>
namespace lightray {
inline std::uint16_t input_u16(std::span<const std::uint8_t> b, std::size_t at) {
    if (at + 2 > b.size())
        throw std::invalid_argument("Short input");
    return static_cast<std::uint16_t>((unsigned(b[at]) << 8) | b[at + 1]);
}
inline std::uint32_t input_u32(std::span<const std::uint8_t> b, std::size_t at) {
    return (std::uint32_t(input_u16(b, at)) << 16) | input_u16(b, at + 2);
}
inline unsigned hid_scan(unsigned usage) {
    constexpr std::array<unsigned, 26> letters = {0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1f, 0x14, 0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c};
    if (usage >= 4 && usage <= 29)
        return letters[usage - 4];
    if (usage >= 30 && usage <= 38)
        return usage - 28;
    if (usage == 39)
        return 0x0b;
    if (usage >= 58 && usage <= 67)
        return usage - 58 + 0x3b;
    if (usage == 68)
        return 0x57;
    if (usage == 69)
        return 0x58;
    // F13-F20 and the additional ISO/menu keys already emitted by the Mac key map.
    if (usage >= 104 && usage <= 111)
        return usage - 104 + 0x64;
    switch (usage) {
    case 40:
        return 0x1c;
    case 41:
        return 1;
    case 42:
        return 0x0e;
    case 43:
        return 0x0f;
    case 44:
        return 0x39;
    case 45:
        return 0x0c;
    case 46:
        return 0x0d;
    case 47:
        return 0x1a;
    case 48:
        return 0x1b;
    case 49:
        return 0x2b;
    case 51:
        return 0x27;
    case 52:
        return 0x28;
    case 53:
        return 0x29;
    case 54:
        return 0x33;
    case 55:
        return 0x34;
    case 56:
        return 0x35;
    case 57:
        return 0x3a;
    case 73:
        return 0x152;
    case 74:
        return 0x147;
    case 75:
        return 0x149;
    case 76:
        return 0x153;
    case 77:
        return 0x14f;
    case 78:
        return 0x151;
    case 79:
        return 0x14d;
    case 80:
        return 0x14b;
    case 81:
        return 0x150;
    case 82:
        return 0x148;
    case 83:
        return 0x45;
    case 84:
        return 0x135;
    case 85:
        return 0x37;
    case 86:
        return 0x4a;
    case 87:
        return 0x4e;
    case 88:
        return 0x11c;
    case 89:
        return 0x4f;
    case 90:
        return 0x50;
    case 91:
        return 0x51;
    case 92:
        return 0x4b;
    case 93:
        return 0x4c;
    case 94:
        return 0x4d;
    case 95:
        return 0x47;
    case 96:
        return 0x48;
    case 97:
        return 0x49;
    case 98:
        return 0x52;
    case 99:
        return 0x53;
    case 100:
        return 0x56;
    case 101:
        return 0x15d;
    case 224:
        return 0x1d;
    case 225:
        return 0x2a;
    case 226:
        return 0x38;
    case 227:
        return 0x15b;
    case 228:
        return 0x11d;
    case 229:
        return 0x36;
    case 230:
        return 0x138;
    case 231:
        return 0x15c;
    default:
        return 0;
    }
}
class WindowsInput {
    RECT display_{};
    std::set<unsigned> keys_, buttons_;
    static bool system_send(INPUT event) {
        return SendInput(1, &event, sizeof(event)) == 1;
    }
    bool (*send)(INPUT) = system_send;
    static INPUT key(unsigned scan, bool down) {
        INPUT e{};
        e.type = INPUT_KEYBOARD;
        e.ki.wScan = static_cast<WORD>(scan & 255);
        e.ki.dwFlags = KEYEVENTF_SCANCODE | (scan & 256 ? KEYEVENTF_EXTENDEDKEY : 0) | (down ? 0 : KEYEVENTF_KEYUP);
        return e;
    }
    static INPUT button(unsigned b, bool down) {
        INPUT e{};
        e.type = INPUT_MOUSE;
        constexpr DWORD down_flags[] = {0, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_XDOWN, MOUSEEVENTF_XDOWN};
        constexpr DWORD up_flags[] = {0, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_XUP, MOUSEEVENTF_XUP};
        e.mi.dwFlags = down ? down_flags[b] : up_flags[b];
        if (b >= 4)
            e.mi.mouseData = b == 4 ? XBUTTON1 : XBUTTON2;
        return e;
    }

  public:
    unsigned applied = 0, unsupported = 0, failures = 0;
    explicit WindowsInput(RECT display, bool (*sender)(INPUT) = system_send) : display_(display), send(sender) {
        if (!sender)
            throw std::invalid_argument("Input sender required");
    }
    ~WindowsInput() {
        reset();
    }
    unsigned held() const {
        return static_cast<unsigned>(keys_.size() + buttons_.size());
    }
    void reset() noexcept {
        for (auto scan : keys_)
            if (!send(key(scan, false)))
                ++failures;
        for (auto b : buttons_)
            if (!send(button(b, false)))
                ++failures;
        keys_.clear();
        buttons_.clear();
    }
    void handle(std::span<const std::uint8_t> bytes) {
        if (bytes.empty())
            return;
        INPUT e{};
        switch (bytes[0]) {
        case 1: {
            if (bytes.size() != 4)
                throw std::invalid_argument("Invalid key message");
            auto scan = hid_scan(input_u16(bytes, 1));
            if (!scan) {
                ++unsupported;
                return;
            }
            const bool down = (bytes[3] & 1) != 0;
            e = key(scan, down);
            if (!send(e)) {
                ++failures;
                throw std::runtime_error("SendInput key failed (desktop integrity/UIPI)");
            }
            if (down)
                keys_.insert(scan);
            else
                keys_.erase(scan);
            ++applied;
            return;
        }
        case 0x10: {
            if (bytes.size() != 9 || (input_u32(bytes, 5) != 0 && input_u32(bytes, 5) != 1))
                return;
            const auto vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN), vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
            if (vw <= 1 || vh <= 1)
                throw std::runtime_error("Invalid virtual desktop");
            const auto x = display_.left + static_cast<long long>(input_u16(bytes, 1)) * (display_.right - display_.left - 1) / 65535;
            const auto y = display_.top + static_cast<long long>(input_u16(bytes, 3)) * (display_.bottom - display_.top - 1) / 65535;
            e.type = INPUT_MOUSE;
            e.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
            e.mi.dx = static_cast<LONG>((x - vx) * 65535 / (vw - 1));
            e.mi.dy = static_cast<LONG>((y - vy) * 65535 / (vh - 1));
            break;
        }
        case 0x11: {
            if (bytes.size() != 3 || bytes[1] < 1 || bytes[1] > 5)
                throw std::invalid_argument("Invalid button message");
            const bool down = bytes[2] != 0;
            e = button(bytes[1], down);
            if (!send(e)) {
                ++failures;
                throw std::runtime_error("SendInput button failed");
            }
            if (down)
                buttons_.insert(bytes[1]);
            else
                buttons_.erase(bytes[1]);
            ++applied;
            return;
        }
        case 0x12: {
            if (bytes.size() != 6 || bytes[5] > 1)
                throw std::invalid_argument("Invalid scroll message");
            const auto dx = static_cast<std::int16_t>(input_u16(bytes, 1)), dy = static_cast<std::int16_t>(input_u16(bytes, 3));
            for (const auto horizontal : {false, true}) {
                const LONG amount = (horizontal ? -dx : dy) * (bytes[5] == 1 ? 3 : 1);
                if (!amount)
                    continue;
                e = {};
                e.type = INPUT_MOUSE;
                e.mi.dwFlags = horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
                e.mi.mouseData = static_cast<DWORD>(amount);
                if (!send(e)) {
                    ++failures;
                    throw std::runtime_error("SendInput scroll failed");
                }
                ++applied;
            }
            return;
        }
        default:
            ++unsupported;
            return;
        }
        if (!send(e)) {
            ++failures;
            throw std::runtime_error("SendInput pointer failed");
        }
        ++applied;
    }
};
} // namespace lightray

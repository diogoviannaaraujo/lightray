#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include "udp_loopback.hpp"
#include "desktop_capture.hpp"
#include "host_bridge.h"
#include "nvenc_encoder.hpp"
#include "windows_input.hpp"
#include <algorithm>
#include <atomic>
#include <bcrypt.h>
#include <chrono>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <windows.h>
#include <wrl/client.h>
using Bytes = std::vector<std::uint8_t>;
using Clock = std::chrono::steady_clock;
using Microsoft::WRL::ComPtr;
static std::atomic<bool> stopping = false;
static BOOL WINAPI stop_handler(DWORD) {
    stopping = true;
    return TRUE;
}
static void require(bool ok, const char *message) {
    if (!ok)
        throw std::runtime_error(message);
}
static std::uint64_t micros() {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(Clock::now().time_since_epoch()).count());
}
static std::uint64_t unix_seconds() {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}
static void put16(Bytes &b, unsigned v) {
    b.push_back(static_cast<std::uint8_t>(v >> 8));
    b.push_back(static_cast<std::uint8_t>(v));
}
static void put32(Bytes &b, std::uint32_t v) {
    put16(b, v >> 16);
    put16(b, v & 65535);
}
static Bytes control(unsigned type, std::uint32_t request, unsigned stream, std::uint32_t display) {
    Bytes b{static_cast<std::uint8_t>(type)};
    put32(b, request);
    b.push_back(static_cast<std::uint8_t>(stream));
    b.push_back(0xf0);
    put16(b, 4);
    put32(b, display);
    return b;
}
static Bytes displays(const lightray::DesktopCapture &capture) {
    lightray::WindowsDisplay info;
    info.primary = capture.primary;
    info.width = capture.source_width; info.height = capture.source_height;
    info.refresh_mhz = capture.source_refresh_mhz;
    info.x = capture.desktop.left; info.y = capture.desktop.top;
    return lightray::display_control(info);
}
class HostAPI {
    HMODULE module_;

  public:
#define ENTRY(name) decltype(&::name) name = nullptr
    ENTRY(lr_host_create);
    ENTRY(lr_host_destroy);
    ENTRY(lr_host_receive);
    ENTRY(lr_host_tick);
    ENTRY(lr_host_close);
    ENTRY(lr_host_generation);
    ENTRY(lr_host_next_wakeup);
    ENTRY(lr_host_pop_datagram);
    ENTRY(lr_host_pop_event);
    ENTRY(lr_host_submit);
    ENTRY(lr_host_submit_timed);
    ENTRY(lr_host_control);
#undef ENTRY
    explicit HostAPI(const wchar_t *path) : module_(LoadLibraryW(path)) {
        require(module_ != nullptr, "Cannot load host core DLL");
#pragma warning(push)
#pragma warning(disable : 4191)
#define LOAD(name)                                                           \
    name = reinterpret_cast<decltype(name)>(GetProcAddress(module_, #name)); \
    require(name != nullptr, "Missing host ABI symbol")
        LOAD(lr_host_create);
        LOAD(lr_host_destroy);
        LOAD(lr_host_receive);
        LOAD(lr_host_tick);
        LOAD(lr_host_close);
        LOAD(lr_host_generation);
        LOAD(lr_host_next_wakeup);
        LOAD(lr_host_pop_datagram);
        LOAD(lr_host_pop_event);
        LOAD(lr_host_submit);
        LOAD(lr_host_submit_timed);
        LOAD(lr_host_control);
#undef LOAD
#pragma warning(pop)
    }
    // Keep Swift runtime loaded through process termination.
};
class Network {
    SOCKET socket_ = INVALID_SOCKET;

  public:
    std::array<std::uint8_t, 4> allowed{};
    Network(const wchar_t *local, const wchar_t *peer) {
        in_addr a{};
        require(InetPtonW(AF_INET, peer, &a) == 1, "Invalid peer IPv4");
        memcpy(allowed.data(), &a, 4);
        socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        require(socket_ != INVALID_SOCKET, "Socket creation failed");
        try {
            BOOL exclusive = TRUE;
            require(setsockopt(socket_, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char *>(&exclusive), sizeof(exclusive)) == 0, "Exclusive bind failed");
            int buffer = 1 << 20;
            require(setsockopt(socket_, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char *>(&buffer), sizeof(buffer)) == 0, "Receive buffer failed");
            sockaddr_in address{};
            address.sin_family = AF_INET;
            address.sin_port = htons(37373);
            require(InetPtonW(AF_INET, local, &address.sin_addr) == 1 && address.sin_addr.s_addr != INADDR_ANY, "Explicit local IPv4 required");
            require(bind(socket_, reinterpret_cast<const sockaddr *>(&address), sizeof(address)) == 0, "Bind failed");
            u_long nonblocking = 1;
            require(ioctlsocket(socket_, FIONBIO, &nonblocking) == 0, "Nonblocking socket failed");
        } catch (...) {
            closesocket(socket_);
            throw;
        }
    }
    ~Network() {
        if (socket_ != INVALID_SOCKET)
            closesocket(socket_);
    }
    int receive(std::array<std::uint8_t, 2048> &buffer, std::uint16_t &port) {
        sockaddr_in peer{};
        int size = sizeof(peer);
        const auto n = recvfrom(socket_, reinterpret_cast<char *>(buffer.data()), static_cast<int>(buffer.size()), 0, reinterpret_cast<sockaddr *>(&peer), &size);
        if (n == SOCKET_ERROR) {
            const auto e = WSAGetLastError();
            if (e == WSAEWOULDBLOCK)
                return 0;
            if (e == WSAEMSGSIZE || e == WSAECONNRESET)
                return -1;
            throw lightray::socket_error("recvfrom");
        }
        if (n <= 0 || n > 1200 || peer.sin_family != AF_INET || memcmp(&peer.sin_addr, allowed.data(), 4) != 0)
            return -1;
        port = ntohs(peer.sin_port);
        return n;
    }
    bool send(const Bytes &packet) {
        require(packet.size() > 7 && packet[0] == 4 && std::equal(allowed.begin(), allowed.end(), packet.begin() + 1), "Unexpected output peer");
        sockaddr_in peer{};
        peer.sin_family = AF_INET;
        memcpy(&peer.sin_addr, packet.data() + 1, 4);
        peer.sin_port = htons(lightray::input_u16(packet, 5));
        const auto n = sendto(socket_, reinterpret_cast<const char *>(packet.data() + 7), static_cast<int>(packet.size() - 7), 0, reinterpret_cast<const sockaddr *>(&peer), sizeof(peer));
        if (n == SOCKET_ERROR) {
            if (WSAGetLastError() == WSAEWOULDBLOCK)
                return false;
            throw lightray::socket_error("sendto");
        }
        require(n == static_cast<int>(packet.size() - 7), "Partial send");
        return true;
    }
};
class Timer {
    HANDLE timer_ = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);

  public:
    Timer() {
        if (!timer_)
            timer_ = CreateWaitableTimerW(nullptr, FALSE, nullptr);
        require(timer_ != nullptr, "Timer creation failed");
    }
    ~Timer() {
        CloseHandle(timer_);
    }
    void wait(std::uint64_t delay) {
        LARGE_INTEGER due{};
        due.QuadPart = -static_cast<LONGLONG>(std::clamp<std::uint64_t>(delay, 100, 5000) * 10);
        require(SetWaitableTimer(timer_, &due, 0, nullptr, nullptr, FALSE) != 0, "Set timer failed");
        require(WaitForSingleObject(timer_, 20) == WAIT_OBJECT_0, "Timer wait failed");
    }
};
class DisplayActivity {
    EXECUTION_STATE previous_;
public:
    DisplayActivity() : previous_(SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED)) {
        require(previous_ != 0, "Cannot hold display active for capture");
    }
    ~DisplayActivity() {
        if (!SetThreadExecutionState(previous_ | ES_CONTINUOUS)) std::cerr << "Could not release display activity request\n";
    }
};
int wmain(int argc, wchar_t **argv) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    SetConsoleCtrlHandler(stop_handler, TRUE);
    try {
        require(argc == 7 || argc == 10 || argc == 11, "Usage: windows_host CORE_DLL BIND_IPV4 PEER_IPV4 PAIR_FILE SECONDS NEW_OUTPUT_DIRECTORY [MAX_WIDTH FPS BITRATE_MBPS [dxgi|wgc]]");
        const unsigned max_width = argc >= 10 ? static_cast<unsigned>(std::stoul(argv[7])) : 1920;
        const unsigned fps = argc >= 10 ? static_cast<unsigned>(std::stoul(argv[8])) : 30;
        const unsigned mbps = argc >= 10 ? static_cast<unsigned>(std::stoul(argv[9])) : 20;
        const std::wstring backend = argc == 11 ? argv[10] : L"dxgi";
        require(backend == L"dxgi" || backend == L"wgc", "Unsupported capture backend");
        const bool use_wgc = backend == L"wgc";
        const char *backend_name = use_wgc ? "wgc" : "dxgi";
        require((max_width == 1920 || max_width == 2560 || max_width == 3840) && fps >= 30 && fps <= 120 && mbps >= 5 && mbps <= 200, "Unsupported stream settings");
        const auto bitrate = mbps * 1000000;
        const std::uint64_t frame_interval = 1000000 / fps;
        const auto duration = std::stoul(argv[5]);
        require(duration >= 10 && duration <= 3600, "Duration must be 10..3600 seconds");
        const std::filesystem::path out(argv[6]);
        require(!std::filesystem::exists(out), "Output already exists");
        std::ifstream pairing_file(std::filesystem::path(argv[4]), std::ios::binary);
        std::string token;
        require(bool(std::getline(pairing_file, token)) && token.size() == 84 && token.starts_with("lr1-"), "Invalid pairing file");
        std::array<std::uint8_t, 40> pairing{};
        for (unsigned i = 0; i < 40; ++i) {
            const auto byte = token.substr(4 + i * 2, 2);
            require(byte.find_first_not_of("0123456789abcdefABCDEF") == std::string::npos, "Invalid pairing encoding");
            pairing[i] = static_cast<std::uint8_t>(std::stoul(byte, nullptr, 16));
        }
        SecureZeroMemory(token.data(), token.size());
        DisplayActivity display_activity;
        std::uint64_t pair_id = 0;
        for (unsigned i = 0; i < 8; ++i)
            pair_id = (pair_id << 8) | pairing[i];
        std::array<std::uint8_t, 32> reset{};
        require(BCryptGenRandom(nullptr, reset.data(), 32, BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0, "Random generator unavailable");
        lightray::WinsockRuntime runtime;
        Network network(argv[2], argv[3]);
        HostAPI api(argv[1]);
        Timer timer;
        ComPtr<IDXGIFactory1> factory;
        require(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))), "DXGI factory failed");
        ComPtr<IDXGIAdapter1> adapter;
        require(SUCCEEDED(factory->EnumAdapters1(0, &adapter)), "Adapter unavailable");
        ComPtr<ID3D11Device> device;
        ComPtr<ID3D11DeviceContext> context;
        require(SUCCEEDED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context)), "D3D11 device failed");
        lightray::DesktopCapture capture(device.Get(), context.Get(), adapter.Get(), max_width, fps, use_wgc);
        lightray::NvencEncoder encoder(device.Get(), {capture.width, capture.height, bitrate, fps, true});
        lightray::WindowsInput input(capture.desktop);
        const auto host = api.lr_host_create(pair_id, pairing.data() + 8, 32, reset.data(), 32, static_cast<std::int32_t>(bitrate), static_cast<std::int32_t>(fps), 0);
        SecureZeroMemory(pairing.data(), pairing.size());
        SecureZeroMemory(reset.data(), reset.size());
        require(host != 0, "Host creation failed");
        require(std::filesystem::create_directory(out), "Cannot create result directory");
        std::ofstream log(out / "host.log");
        log.exceptions(std::ios::badbit | std::ios::failbit);
        log << "host_ready width=" << capture.width << " height=" << capture.height << " fps_target=" << fps << " bitrate_mbps=" << mbps << " source_refresh_hz=" << capture.source_refresh_hz << " capture_backend=" << backend_name << " native_nvenc=true desktop=true input=true\n"
            << std::flush;
        std::ofstream timings(out / "frame-timings.csv");
        timings << "start_us,capture_us,encode_us,submit_us,payload_bytes,desktop_updates,cached_frames,sample_id,capture_epoch,is_idr\n";
        std::deque<Bytes> outgoing;
        std::array<std::uint8_t, 2048> buffer{};
        std::uint64_t frames = 0, keyframes = 0, tx = 0, rx = 0, generation = 0, session_count = 0, idr_requests = 0, skipped = 0;
        bool stream = false, capture_waiting = true;
        std::uint64_t capture_epoch = 0, capture_wait_started = 0, recovery_successes = 0, blocked_input = 0;
        auto next_frame = micros(), last_report = next_frame;
        const auto started = next_frame, deadline = started + duration * 1000000ULL;
        auto send_control = [&](const Bytes &bytes) { require(api.lr_host_control(host, generation, bytes.data(), static_cast<std::int32_t>(bytes.size()), micros()) == 0, "Control message failed"); };
        auto flush = [&] {
            for (unsigned budget = 0; budget < 256; ++budget) {
                std::int32_t needed = 0;
                const auto n = api.lr_host_pop_datagram(host, buffer.data(), static_cast<std::int32_t>(buffer.size()), &needed);
                require(n >= 0, "Host output failed");
                if (!n)
                    break;
                require(outgoing.size() < 256, "UDP output budget exceeded");
                outgoing.emplace_back(buffer.begin(), buffer.begin() + n);
            }
            while (!outgoing.empty()) {
                if (!network.send(outgoing.front()))
                    break;
                outgoing.pop_front();
                ++tx;
            }
        };
        try {
            while (!stopping && micros() < deadline && !std::filesystem::exists(out / "stop")) {
                for (unsigned budget = 0; budget < 128; ++budget) {
                    std::uint16_t port = 0;
                    const auto n = network.receive(buffer, port);
                    if (!n)
                        break;
                    if (n < 0)
                        continue;
                    ++rx;
                    require(api.lr_host_receive(host, buffer.data(), n, network.allowed.data(), 4, port, micros(), unix_seconds()) == 0, "Core receive failed");
                }
                require(api.lr_host_tick(host, micros()) == 0, "Core tick failed");
                for (unsigned budget = 0; budget < 64; ++budget) {
                    std::int32_t needed = 0;
                    const auto n = api.lr_host_pop_event(host, buffer.data(), static_cast<std::int32_t>(buffer.size()), &needed);
                    require(n >= 0, "Event drain failed");
                    if (!n)
                        break;
                    const auto kind = buffer[0];
                    const auto body = std::span(buffer.data() + 9, static_cast<std::size_t>(n - 9));
                    if (kind == 1) {
                        input.reset();
                        outgoing.clear();
                        generation = api.lr_host_generation(host);
                        ++session_count;
                        stream = true;
                        encoder.resume();
                        encoder.request_idr();
                        send_control(displays(capture));
                        send_control(control(3, 0, 1, 1));
                        next_frame = micros();
                        log << "session_started count=" << session_count << '\n'
                            << std::flush;
                    } else if (kind == 2) {
                        stream = false;
                        generation = 0;
                        input.reset();
                        outgoing.clear();
                        encoder.pause();
                        log << "session_ended held=" << input.held() << '\n'
                            << std::flush;
                    } else if (kind == 3) {
                        if (!body.empty() && body[0] == 1) {
                            encoder.request_idr();
                            ++idr_requests;
                        }
                    } else if (kind == 4) {
                        require(body.size() == 9, "Invalid display request");
                        const auto requested = lightray::input_u32(body, 1), request = lightray::input_u32(body, 5);
                        if (body[0] == 1 && (requested == 0 || requested == 1)) {
                            input.reset();
                            stream = requested == 1;
                            if (stream) {
                                encoder.resume();
                                encoder.request_idr();
                            } else
                                encoder.pause();
                            send_control(control(2, request, 1, requested));
                        } else
                            send_control(control(2, request, body[0], 0));
                    } else if (kind == 5) {
                        if (stream && capture.ready())
                            input.handle(body);
                        else
                            ++blocked_input;
                    } else if (kind == 6) {
                        input.reset();
                        outgoing.clear();
                        encoder.pause();
                        generation = api.lr_host_generation(host);
                    } else if (kind == 7) {
                        generation = api.lr_host_generation(host);
                        if (stream) {
                            encoder.resume();
                            encoder.request_idr();
                        }
                    }
                }
                flush();
                auto now = micros();
                if (stream && encoder.active() && now >= next_frame) {
                    const auto capture_start = micros();
                    // The laboratory hook affects this process only and never changes the display mode.
                    if (std::filesystem::exists(out / "invalidate-capture") || std::filesystem::exists(out / "hold-capture-loss")) {
                        std::filesystem::remove(out / "invalidate-capture");
                        capture.invalidate(capture_start);
                        log << "capture_fault_injected mechanism=release_capture backend=" << backend_name << '\n' << std::flush;
                    }
                    if (auto *texture = capture.acquire(capture_start)) {
                        const bool fresh_capture = capture.epoch != capture_epoch;
                        if (fresh_capture) {
                            encoder.request_idr();
                            capture_epoch = capture.epoch;
                            if (capture_waiting && capture_wait_started) ++recovery_successes;
                            log << "capture_ready epoch=" << capture_epoch << " recovery_us=" << (capture_wait_started ? capture_start - capture_wait_started : 0) << " recreations=" << capture.recreations << " source_refresh_hz=" << capture.source_refresh_hz << '\n' << std::flush;
                            capture_waiting = false;
                        }
                        const auto captured = micros();
                        const auto frame = encoder.encode(texture, frames, encoder.generation());
                        if (fresh_capture) {
                            require(frame.unit.idr && !frame.unit.config.empty(), "Recovery must start with a configured IDR");
                            log << "capture_idr epoch=" << capture_epoch << " sample=" << frames << '\n' << std::flush;
                        }
                        now = micros();
                        if (now - captured <= 100000) {
                            const auto &unit = frame.unit;
                            const auto submitted = captured - capture_start <= 1000000 && now - captured <= 1000000
                                ? api.lr_host_submit_timed(host, generation, 1, unit.payload.data(), static_cast<std::int32_t>(unit.payload.size()), unit.config.data(), static_cast<std::int32_t>(unit.config.size()), unit.idr, captured, now, static_cast<std::uint32_t>(captured - capture_start), static_cast<std::uint32_t>(now - captured), frames)
                                : api.lr_host_submit(host, generation, 1, unit.payload.data(), static_cast<std::int32_t>(unit.payload.size()), unit.config.data(), static_cast<std::int32_t>(unit.config.size()), unit.idr, captured, now);
                            require(submitted == 0, "Core frame submission failed");
                            timings << capture_start << "," << captured - capture_start << "," << now - captured << "," << micros() - now << "," << unit.payload.size() << "," << capture.desktop_updates << "," << capture.cached_frames << "," << frames << "," << capture_epoch << "," << (unit.idr ? 1 : 0) << "\n";
                            ++frames;
                            if (unit.idr)
                                ++keyframes;
                        } else {
                            ++skipped;
                            encoder.request_idr();
                            ++frames;
                        }
                        flush();
                    }
                    if (!capture.ready() && !capture_waiting) {
                        input.reset();
                        capture_waiting = true;
                        capture_wait_started = micros();
                        log << "capture_recovering held=" << input.held() << " losses=" << capture.losses << '\n' << std::flush;
                    }
                    next_frame += frame_interval;
                    if (next_frame < now) {
                        next_frame = now + frame_interval;
                        ++skipped;
                    }
                }
                now = micros();
                if (now - last_report >= 5000000) {
                    log << "frames=" << frames << " keyframes=" << keyframes << " tx=" << tx << " rx=" << rx << " input=" << input.applied << " held=" << input.held() << " queue=" << outgoing.size() << " skipped=" << skipped << " desktop_updates=" << capture.desktop_updates << " cached_frames=" << capture.cached_frames << '\n'
                        << std::flush;
                    last_report = now;
                }
                std::uint64_t wake = UINT64_MAX;
                require(api.lr_host_next_wakeup(host, micros(), &wake) == 0, "Next wakeup failed");
                now = micros();
                if (stream && encoder.active())
                    wake = std::min(wake, next_frame);
                timer.wait(wake > now ? wake - now : 100);
            }
            input.reset();
            require(api.lr_host_close(host, micros()) == 0, "Close failed");
            flush();
            require(api.lr_host_destroy(host) == 0, "Destroy failed");
            require(encoder.close(), "Encoder teardown failed");
        } catch (...) {
            input.reset();
            api.lr_host_close(host, micros());
            api.lr_host_destroy(host);
            throw;
        }
        std::ofstream result(out / "result.json");
        result.exceptions(std::ios::badbit | std::ios::failbit);
        result << "{\"status\":\"completed\",\"frames\":" << frames << ",\"keyframes\":" << keyframes << ",\"idr_requests\":" << idr_requests << ",\"sessions\":" << session_count << ",\"input_applied\":" << input.applied << ",\"input_unsupported\":" << input.unsupported << ",\"input_failures\":" << input.failures << ",\"held_at_exit\":" << input.held() << ",\"tx\":" << tx << ",\"rx\":" << rx << ",\"skipped\":" << skipped << ",\"width\":" << capture.width << ",\"height\":" << capture.height << ",\"fps_target\":" << fps << ",\"bitrate_mbps\":" << mbps << ",\"source_refresh_hz\":" << capture.source_refresh_hz << ",\"desktop_updates\":" << capture.desktop_updates << ",\"cached_frames\":" << capture.cached_frames << ",\"capture_recreations\":" << capture.recreations << ",\"capture_recoveries\":" << recovery_successes << ",\"blocked_input\":" << blocked_input << ",\"clock\":\"steady_clock\",\"desktop_capture\":true,\"native_nvenc\":true}\n";
        return input.failures ? 1 : 0;
    } catch (const winrt::hresult_error &error) {
        std::cerr << "Windows capture HRESULT " << error.code().value << '\n';
        return 1;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}

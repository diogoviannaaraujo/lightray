#define NOMINMAX
#include "udp_loopback.hpp"
#include <windows.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include "nvenc_encoder.hpp"
#include "host_bridge.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>
using Bytes = std::vector<std::uint8_t>;
static void require(bool yes, const char* why) { if (!yes) throw std::runtime_error(why); }
template<class T> T function(HMODULE module, const char* name) {
    const auto proc = GetProcAddress(module, name);
    require(proc != nullptr, name);
#pragma warning(push)
#pragma warning(disable: 4191)
    return reinterpret_cast<T>(proc);
#pragma warning(pop)
}
static std::vector<Bytes> records(const std::filesystem::path& path) {
    const auto size = std::filesystem::file_size(path);
    require(size <= 64 * 1024 * 1024, "Fixture exceeds limit");
    std::ifstream input(path, std::ios::binary);
    require(input.good(), "Fixture unavailable");
    std::vector<Bytes> result;
    while (input.peek() != EOF) {
        std::array<std::uint8_t, 4> prefix{};
        input.read(reinterpret_cast<char*>(prefix.data()), 4);
        require(input.gcount() == 4, "Truncated fixture prefix");
        const auto count = (std::uint32_t(prefix[0]) << 24) | (std::uint32_t(prefix[1]) << 16) | (std::uint32_t(prefix[2]) << 8) | prefix[3];
        require(count <= 4 * 1024 * 1024 && result.size() < 120, "Invalid fixture count or size");
        Bytes bytes(count);
        if (count) { input.read(reinterpret_cast<char*>(bytes.data()), count); require(input.gcount() == count, "Truncated fixture body"); }
        result.push_back(std::move(bytes));
    }
    require(result.size() == 120, "Expected 120 records");
    return result;
}
int wmain(int argc, wchar_t** argv) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    try {
        require(argc == 3 || (argc == 4 && std::wstring(argv[3]) == L"--live-loopback"), "Usage: host_abi_probe CORE_DLL NVENC_RUN_DIRECTORY [--live-loopback]");
        const bool live = argc == 4;
        std::unique_ptr<lightray::WinsockRuntime> winsock;
        Microsoft::WRL::ComPtr<ID3D11Device> gpu;
        Microsoft::WRL::ComPtr<ID3D11DeviceContext> context;
        if (live) {
            winsock = std::make_unique<lightray::WinsockRuntime>();
            Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
            require(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))), "DXGI unavailable");
            Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
            require(SUCCEEDED(factory->EnumAdapters1(0,&adapter)), "Adapter unavailable");
            require(SUCCEEDED(D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&gpu,nullptr,&context)), "D3D11 unavailable");
        }
        unsigned datagrams_sent = 0, datagrams_received = 0;
        const auto module = LoadLibraryW(argv[1]);
        require(module != nullptr, "Swift DLL unavailable");
#define LOAD(name) const auto name = function<decltype(&::name)>(module, #name)
        LOAD(lr_host_abi_version); LOAD(lr_host_create); LOAD(lr_host_destroy);
        LOAD(lr_host_receive); LOAD(lr_host_tick); LOAD(lr_host_close);
        LOAD(lr_host_generation); LOAD(lr_host_next_wakeup); LOAD(lr_host_pop_datagram);
        LOAD(lr_host_pop_event); LOAD(lr_host_submit);
#undef LOAD
        const auto start = function<std::int32_t (*)(std::uint64_t)>(module, "lr_probe_client_start");
        const auto step = function<std::int32_t (*)(const std::uint8_t*,std::int32_t,std::uint64_t)>(module, "lr_probe_client_step");
        const auto pop = function<std::int32_t (*)(std::int32_t,std::uint8_t*,std::int32_t)>(module, "lr_probe_client_pop");
        const auto stop = function<void (*)()>(module, "lr_probe_client_stop");
        require(lr_host_abi_version() == 1, "ABI version mismatch");
        std::array<std::uint8_t,32> key{}, reset{}; key.fill(7); reset.fill(3);
        auto create = [&] { return lr_host_create(42, key.data(), 32, reset.data(), 32, 40000000, 60, 0); };
        require(lr_host_create(42,nullptr,32,reset.data(),32,40000000,60,0) == 0, "Null key accepted");
        // Four callers repeatedly access the registry; stale handles must never alias a new host.
        std::atomic<unsigned> errors{0};
        std::vector<std::thread> threads;
        for (unsigned t = 0; t < 4; ++t) threads.emplace_back([&] {
            for (unsigned i = 0; i < 25; ++i) {
                const auto h = create();
                if (!h || lr_host_tick(h,100) != 0 || lr_host_tick(h,99) != -1 || lr_host_destroy(h) != 0 || lr_host_destroy(h) != -2 || lr_host_tick(h,100) != -2) ++errors;
            }
        });
        for (auto& thread : threads) thread.join();
        require(errors == 0, "Concurrent lifecycle/stale-handle checks failed");
        std::vector<std::uint64_t> hosts;
        for (unsigned i = 0; i < 16; ++i) { hosts.push_back(create()); require(hosts.back() != 0, "Host capacity failed early"); }
        require(create() == 0, "Host capacity unbounded");
        for (auto h : hosts) require(lr_host_destroy(h) == 0, "Host release failed");
        unsigned delivered = 0;
        for (const auto* size : {L"1920x1080",L"2560x1440",L"3840x2160"}) {
            const auto directory = std::filesystem::path(argv[2]) / size;
            const auto payloads = records(directory / "native-nvenc.payloads");
            const auto configs = records(directory / "native-nvenc.configs");
            const auto host = create(); require(host != 0, "Host creation failed");
            unsigned width = 0, height = 0;
            if (std::wstring(size) == L"1920x1080") { width=1920; height=1080; }
            else if (std::wstring(size) == L"2560x1440") { width=2560; height=1440; }
            else { width=3840; height=2160; }
            std::unique_ptr<lightray::LoopbackSocket> host_socket, client_socket;
            std::unique_ptr<lightray::NvencEncoder> encoder;
            Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
            Bytes pixels;
            std::uint16_t client_port = 50000;
            if (live) {
                // Exclusive loopback-only bind; a busy port fails instead of replacing another listener.
                host_socket=std::make_unique<lightray::LoopbackSocket>(std::uint16_t{7373});
                client_socket=std::make_unique<lightray::LoopbackSocket>(std::uint16_t{0});
                client_port=client_socket->port();
                encoder=std::make_unique<lightray::NvencEncoder>(gpu.Get(),lightray::EncoderSettings{width,height,width==3840?40000000u:20000000u,60});
                D3D11_TEXTURE2D_DESC desc{};
                desc.Width=width; desc.Height=height; desc.MipLevels=desc.ArraySize=1;
                desc.Format=DXGI_FORMAT_NV12; desc.SampleDesc.Count=1; desc.Usage=D3D11_USAGE_DEFAULT;
                require(SUCCEEDED(gpu->CreateTexture2D(&desc,nullptr,&texture)),"Input texture unavailable");
                pixels.resize(static_cast<std::size_t>(width)*height*3/2,128);
            }
            std::uint64_t now = 10000000;
            require(start(now) == 0, "Test client failed to start");
            std::array<std::uint8_t,2048> packet{}, event{};
            const std::array<std::uint8_t,4> ip{127,0,0,1};
            auto pump = [&] {
                now += 250;
                require(step(nullptr,0,now) == 0, "Client tick failed");
                for (;;) {
                    const auto n = pop(0,packet.data(),static_cast<std::int32_t>(packet.size()));
                    require(n >= 0, "Client datagram output failed"); if (!n) break;
                    if (live) { require(client_socket->send(std::span(packet.data(),n),7373),"Client socket backpressure"); ++datagrams_sent; }
                    else require(lr_host_receive(host,packet.data(),n,ip.data(),4,client_port,now,1700000000) == 0, "Host receive failed");
                }
                if (live) {
                    for (unsigned budget=0; budget<256; ++budget) {
                        std::uint16_t peer=0; const auto n=host_socket->receive(packet,peer); if (!n) break;
                        require(peer==client_port,"Unexpected client UDP port"); ++datagrams_received;
                        require(lr_host_receive(host,packet.data(),n,ip.data(),4,peer,now,1700000000)==0,"Host UDP receive failed");
                    }
                }
                require(lr_host_tick(host,now) == 0, "Host tick failed");
                for (;;) {
                    std::int32_t needed = 0;
                    const auto query = lr_host_pop_datagram(host,nullptr,0,&needed);
                    if (!query) break;
                    require(query == -3 && needed > 7 && needed <= 1207, "Output query consumed or corrupted datagram");
                    require(lr_host_pop_datagram(host,packet.data(),static_cast<std::int32_t>(packet.size()),&needed) == needed, "Datagram copy failed");
                    require(packet[0] == 4 && std::equal(ip.begin(),ip.end(),packet.begin()+1) && packet[5] == static_cast<std::uint8_t>(client_port >> 8) && packet[6] == static_cast<std::uint8_t>(client_port), "Output peer mismatch");
                    if (live) { require(host_socket->send(std::span(packet.data()+7,needed-7),client_port),"Host socket backpressure"); ++datagrams_sent; }
                    else require(step(packet.data()+7,needed-7,now) == 0, "Client authentication/reassembly failed");
                }
                if (live) {
                    for (unsigned budget=0; budget<256; ++budget) {
                        std::uint16_t peer=0; const auto n=client_socket->receive(packet,peer); if (!n) break;
                        require(peer==7373,"Unexpected host UDP port"); ++datagrams_received;
                        require(step(packet.data(),n,now)==0,"Client UDP authentication/reassembly failed");
                    }
                    std::this_thread::yield();
                }
                std::int32_t needed = 0;
                for (;;) { const auto n = lr_host_pop_event(host,event.data(),static_cast<std::int32_t>(event.size()),&needed); require(n >= 0,"Event drain failed"); if (!n) break; }
            };
            for (unsigned i = 0; i < 20; ++i) pump();
            const auto generation = lr_host_generation(host); require(generation == 1, "Authenticated handshake failed");
            Bytes decoded(4*1024*1024);
            for (unsigned i = 0; i < 120; ++i) {
                lightray::NvencFrame live_frame;
                if (live) {
                    for (unsigned y=0;y<height;++y) for (unsigned x=0;x<width;++x) pixels[static_cast<std::size_t>(y)*width+x]=static_cast<std::uint8_t>(16+((x+y+i*8)%220));
                    context->UpdateSubresource(texture.Get(),0,nullptr,pixels.data(),width,0);
                    if (i==60) encoder->request_idr();
                    live_frame=encoder->encode(texture.Get(),i,encoder->generation());
                    require(live_frame.unit.payload==payloads[i] && live_frame.unit.config==configs[i],"Live NVENC differs from validated corpus");
                }
                const auto& payload = live ? live_frame.unit.payload : payloads[i];
                const auto& config = live ? live_frame.unit.config : configs[i];
                require(lr_host_submit(host,generation,1,payload.data(),static_cast<std::int32_t>(payload.size()),config.data(),static_cast<std::int32_t>(config.size()),i == 0 || i == 60,now,now) == 0,"NVENC frame rejected by host ABI");
                std::int32_t count = 0;
                for (unsigned attempt = 0; attempt < 400 && !count; ++attempt) { pump(); count = pop(1,decoded.data(),static_cast<std::int32_t>(decoded.size())); require(count >= 0,"Received frame exceeds limit"); }
                require(count == static_cast<std::int32_t>(payload.size()) && std::equal(payload.begin(),payload.end(),decoded.begin()),"Authenticated NVENC payload mismatch or timeout");
                ++delivered;
                for (unsigned gap = 0; gap < 67; ++gap) pump();
            }
            require(lr_host_close(host,now) == 0 && lr_host_generation(host) == 0,"Close failed");
            std::uint64_t next = 0;
            require(lr_host_next_wakeup(host,now,&next) == 0 && next == UINT64_MAX,"Closed host retained timer");
            for(unsigned i=0;i<20;++i) pump();
            require(lr_host_destroy(host) == 0,"Final destroy failed");
            if (encoder) require(encoder->close(),"Live encoder cleanup failed");
            stop();
        }
        // The Swift runtime module remains loaded for the process lifetime.
        std::cout << "{\"status\":\"passed\",\"lifecycle_cycles\":100,\"concurrent_callers\":4,\"host_limit\":16,\"authenticated_handshakes\":3,\"nvenc_frames_delivered\":" << delivered << ",\"udp_sockets\":" << (live ? "true" : "false") << ",\"live_nvenc\":" << (live ? "true" : "false") << ",\"datagrams_sent\":" << datagrams_sent << ",\"datagrams_received\":" << datagrams_received << ",\"clock\":\"simulated\",\"desktop_captured\":false}\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

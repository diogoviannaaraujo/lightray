#define NOMINMAX
#include <windows.h>
#include <dxgi1_4.h>
#include <psapi.h>
#include <wrl/client.h>
#include "nvenc_encoder.hpp"
#include <array>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
using Microsoft::WRL::ComPtr;
using Clock = std::chrono::steady_clock;
static void check(bool value, const char* why) { if (!value) throw std::runtime_error(why); }
static void hr(HRESULT value, const char* why) { check(SUCCEEDED(value), why); }
template<class F> static void rejects(F operation) {
    bool rejected = false;
    try { operation(); } catch (const std::logic_error&) { rejected = true; }
    check(rejected, "Invalid lifecycle operation was accepted");
}
struct Sample {
    SIZE_T private_bytes = 0, working_set = 0;
    UINT64 gpu_local = 0, gpu_nonlocal = 0;
    DWORD handles = 0;
};
static Sample sample(IDXGIAdapter3* adapter) {
    PROCESS_MEMORY_COUNTERS_EX memory{};
    memory.cb = sizeof(memory);
    hr(GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory), sizeof(memory)) ? S_OK : E_FAIL, "Process memory query failed");
    DXGI_QUERY_VIDEO_MEMORY_INFO local{}, nonlocal{};
    hr(adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &local), "Local GPU memory query failed");
    hr(adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &nonlocal), "Nonlocal GPU memory query failed");
    DWORD handles=0;
    check(GetProcessHandleCount(GetCurrentProcess(), &handles) != 0, "Handle count query failed");
    return {memory.PrivateUsage, memory.WorkingSetSize, local.CurrentUsage, nonlocal.CurrentUsage, handles};
}
static ComPtr<ID3D11Texture2D> surface(ID3D11Device* device, unsigned width, unsigned height, DXGI_FORMAT format = DXGI_FORMAT_NV12) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width; desc.Height = height; desc.MipLevels = desc.ArraySize = 1;
    desc.SampleDesc.Count = 1; desc.Format = format; desc.Usage = D3D11_USAGE_DEFAULT;
    ComPtr<ID3D11Texture2D> result;
    hr(device->CreateTexture2D(&desc, nullptr, &result), "Surface creation failed");
    return result;
}
int wmain(int argc, wchar_t** argv) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    try {
        check(argc == 2, "Usage: nvenc_lifecycle_probe NEW_OUTPUT_DIRECTORY");
        const std::filesystem::path out(argv[1]);
        check(!std::filesystem::exists(out), "Output already exists");
        ComPtr<IDXGIFactory1> factory; hr(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "Factory failed");
        ComPtr<IDXGIAdapter1> adapter; hr(factory->EnumAdapters1(0, &adapter), "Adapter unavailable");
        DXGI_ADAPTER_DESC1 description{}; hr(adapter->GetDesc1(&description), "Description failed");
        check(description.VendorId == 0x10de && !(description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE), "NVIDIA hardware required");
        ComPtr<IDXGIAdapter3> memory_adapter; hr(adapter.As(&memory_adapter), "Memory counters unavailable");
        ComPtr<ID3D11Device> device; ComPtr<ID3D11DeviceContext> context;
        hr(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context), "Device creation failed");
        const std::array<lightray::EncoderSettings,3> settings{{{1920,1080,20000000,60},{2560,1440,20000000,60},{3840,2160,40000000,60}}};
        std::array<ComPtr<ID3D11Texture2D>,3> inputs;
        for (unsigned i = 0; i < settings.size(); ++i) {
            const auto config = settings[i];
            inputs[i] = surface(device.Get(), config.width, config.height);
            lightray::Bytes pixels(static_cast<std::size_t>(config.width) * config.height * 3 / 2, 128);
            for (unsigned y = 0; y < config.height; ++y) for (unsigned x = 0; x < config.width; ++x) pixels[static_cast<std::size_t>(y) * config.width + x] = static_cast<std::uint8_t>(16 + ((x + y) % 220));
            context->UpdateSubresource(inputs[i].Get(), 0, nullptr, pixels.data(), config.width, 0);
        }
        const auto wrong_format = surface(device.Get(),1920,1080,DXGI_FORMAT_B8G8R8A8_UNORM);
        ComPtr<ID3D11Device> other_device;
        hr(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &other_device, nullptr, nullptr), "Other device failed");
        const auto foreign_input = surface(other_device.Get(),1920,1080);
        rejects([&] { lightray::NvencEncoder invalid(nullptr,settings[0]); });
        ComPtr<ID3D11Device> software_device;
        hr(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&software_device,nullptr,nullptr),"Negative-test device failed");
        bool vendor_rejected=false;
        try { lightray::NvencEncoder invalid(software_device.Get(),settings[0]); }
        catch(const std::runtime_error& error) { vendor_rejected=std::string(error.what())=="NVENC requires an NVIDIA device"; }
        check(vendor_rejected,"Non-NVIDIA device was not rejected");
        software_device.Reset();
        check(std::filesystem::create_directory(out),"Cannot create output directory");
        std::ofstream csv(out/"frames.csv"), memory(out/"resources.csv"), video(out/"lifecycle.hevc",std::ios::binary);
        for (auto* file : {&csv,&memory,&video}) file->exceptions(std::ios::failbit | std::ios::badbit);
        csv << "frame,cycle,width,height,generation,timestamp,idr,encode_and_lock_ms\n";
        memory << "cycle,private_bytes,working_set_bytes,gpu_local_bytes,gpu_nonlocal_bytes,handles\n";
        auto snapshot = [&](int cycle) { const auto s=sample(memory_adapter.Get()); memory << cycle << ',' << s.private_bytes << ',' << s.working_set << ',' << s.gpu_local << ',' << s.gpu_nonlocal << ',' << s.handles << '\n'; };
        snapshot(-31);
        const auto start = Clock::now();
        unsigned frames = 0;
        for (unsigned iteration = 0; iteration < 130; ++iteration) {
            const bool measured = iteration >= 30;
            const unsigned cycle = measured ? iteration - 30 : iteration;
            check(Clock::now()-start < std::chrono::seconds(150),"Lifecycle time budget exceeded");
            const auto first=cycle%3, next=(first+1)%3;
            lightray::NvencEncoder encoder(device.Get(),settings[first]);
            const auto epoch=encoder.generation();
            auto encode = [&](unsigned input, unsigned timestamp, bool idr) {
                const auto result=encoder.encode(inputs[input].Get(),timestamp,encoder.generation());
                check(result.unit.idr==idr && result.generation==encoder.generation() && result.timestamp==timestamp,"Lifecycle frame metadata mismatch");
                check(idr ? !result.unit.config.empty() : result.unit.config.empty(),"Lifecycle parameter sets mismatch");
                if (!measured) return;
                video.write(reinterpret_cast<const char*>(result.annex_b.data()),static_cast<std::streamsize>(result.annex_b.size()));
                csv << frames++ << ',' << cycle << ',' << settings[input].width << ',' << settings[input].height << ',' << result.generation << ',' << timestamp << ',' << idr << ',' << result.encode_and_lock_ms << '\n';
            };
            rejects([&] { encoder.encode(nullptr,0,epoch); });
            if (first==0) {
                rejects([&] { encoder.encode(wrong_format.Get(),0,epoch); });
                rejects([&] { encoder.encode(foreign_input.Get(),0,epoch); });
            }
            encode(first,0,true); encode(first,1,false);
            rejects([&] { encoder.encode(inputs[first].Get(),1,epoch); });
            encoder.request_idr(); encode(first,2,true);
            encoder.pause(); encoder.pause();
            check(!encoder.active() && encoder.generation()==epoch+1,"Pause generation mismatch");
            rejects([&] { encoder.encode(inputs[first].Get(),3,encoder.generation()); });
            encoder.resume();
            rejects([&] { encoder.encode(inputs[first].Get(),3,epoch); });
            encode(first,3,true);
            auto invalid=settings[first]; invalid.width=1919;
            rejects([&] { encoder.reconfigure(invalid); });
            check(encoder.active() && encoder.generation()==epoch+1,"Invalid settings damaged live session");
            if(cycle%2==0) encoder.pause();
            const auto before_reconfigure=encoder.generation();
            encoder.reconfigure(settings[next]);
            check(encoder.generation()==before_reconfigure+1,"Reconfigure generation mismatch");
            if(cycle%2==0) { check(!encoder.active(),"Reconfigure lost pause state"); encoder.resume(); }
            rejects([&] { encoder.encode(inputs[first].Get(),4,encoder.generation()); });
            rejects([&] { encoder.encode(inputs[next].Get(),4,before_reconfigure); });
            encode(next,4,true); encode(next,5,false);
            check(encoder.close() && encoder.close() && !encoder.active(),"Close failed or was not idempotent");
            rejects([&] { encoder.encode(inputs[next].Get(),6,encoder.generation()); });
            snapshot(measured ? static_cast<int>(cycle) : static_cast<int>(iteration) - 30);
        }
        for(auto* file : {&csv,&memory,&video}) file->close();
        std::ofstream result(out/"result.json"); result.exceptions(std::ios::failbit | std::ios::badbit);
        result << "{\"status\":\"passed\",\"cycles\":100,\"reconfigurations\":100,\"warmup_cycles\":30,\"warmup_sessions\":60,\"frames\":" << frames << ",\"wall_seconds\":" << std::chrono::duration<double>(Clock::now()-start).count() << ",\"desktop_captured\":false,\"gpu_input\":\"synthetic_nv12\",\"resource_samples\":131}\n";
        result.close();
        std::cout << "NVENC lifecycle passed: 100 cycles, 100 resolution changes, 600 frames\n";
        return 0;
    } catch(const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

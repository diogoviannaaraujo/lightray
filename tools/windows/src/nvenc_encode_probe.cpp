#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <cstdint>
#include "nvenc_encoder.hpp"
#include "../vendor/nv-codec-headers/nvEncodeAPI.h"
#include "hevc_annexb.hpp"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;
using Clock = std::chrono::steady_clock;
static void hr(HRESULT status, const char* action) {
    if (FAILED(status)) throw std::runtime_error(std::string(action) + " HRESULT " + std::to_string(status));
}
static void write_bytes(std::ofstream& stream, std::span<const std::uint8_t> bytes) {
    stream.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
}
static void record(std::ofstream& stream, const lightray::Bytes& bytes) {
    lightray::Bytes length;
    lightray::append_length(length, bytes.size());
    write_bytes(stream, length);
    write_bytes(stream, bytes);
}
static unsigned number(const wchar_t* value) {
    const std::wstring input(value);
    if (input.empty() || input.find_first_not_of(L"0123456789") != std::wstring::npos) throw std::runtime_error("Invalid numeric argument");
    std::size_t end = 0;
    const auto parsed = std::stoul(input, &end);
    if (end != input.size() || parsed > 100000) throw std::runtime_error("Numeric argument out of range");
    return static_cast<unsigned>(parsed);
}
int wmain(int argc, wchar_t** argv) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    try {
        if (argc != 5) throw std::runtime_error("Usage: nvenc_encode_probe WIDTH HEIGHT ADAPTER NEW_OUTPUT_DIRECTORY");
        const unsigned width = number(argv[1]), height = number(argv[2]), index = number(argv[3]);
        if (!((width == 1920 && height == 1080) || (width == 2560 && height == 1440) || (width == 3840 && height == 2160)) || index > 15) throw std::runtime_error("Unsupported probe dimensions or adapter");
        const std::filesystem::path out(argv[4]);
        if (std::filesystem::exists(out)) throw std::runtime_error("Output directory already exists");
        ComPtr<IDXGIFactory1> factory;
        hr(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "Create DXGI factory");
        ComPtr<IDXGIAdapter1> adapter;
        hr(factory->EnumAdapters1(index, &adapter), "Select adapter");
        DXGI_ADAPTER_DESC1 desc{};
        hr(adapter->GetDesc1(&desc), "Describe adapter");
        if (desc.VendorId != 0x10de || (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) throw std::runtime_error("NVENC requires a hardware NVIDIA adapter");
        ComPtr<ID3D11Device> device;
        ComPtr<ID3D11DeviceContext> context;
        ComPtr<ID3D11Texture2D> texture;
        hr(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context), "Create D3D11 device");
        const unsigned bitrate = width == 3840 ? 40000000 : 20000000;
        lightray::NvencEncoder encoder(device.Get(), {width, height, bitrate, 60});
        const auto driver_api = encoder.driver_api();
        D3D11_TEXTURE2D_DESC texture_desc{};
        texture_desc.Width = width; texture_desc.Height = height;
        texture_desc.MipLevels = texture_desc.ArraySize = 1;
        texture_desc.Format = DXGI_FORMAT_NV12; texture_desc.SampleDesc.Count = 1;
        texture_desc.Usage = D3D11_USAGE_DEFAULT;
        hr(device->CreateTexture2D(&texture_desc, nullptr, &texture), "Create synthetic NV12 texture");
        if (!std::filesystem::create_directory(out)) throw std::runtime_error("Cannot create output directory");
        std::ofstream video(out / "native-nvenc.hevc", std::ios::binary), payloads(out / "native-nvenc.payloads", std::ios::binary), configs(out / "native-nvenc.configs", std::ios::binary), csv(out / "frames.csv");
        for (auto* stream : {&video, &payloads, &configs, &csv}) stream->exceptions(std::ios::failbit | std::ios::badbit);
        csv << "frame,output_timestamp,idr,annexb_bytes,payload_bytes,config_bytes,encode_and_lock_ms,hw_status_raw\n";
        lightray::Bytes pixels(static_cast<std::size_t>(width) * height * 3 / 2, 128);
        const auto started = Clock::now();
        unsigned idrs = 0;
        for (unsigned frame = 0; frame < 120; ++frame) {
            if (Clock::now() - started > std::chrono::seconds(30)) throw std::runtime_error("Encoder budget exceeded");
            for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; ++x) pixels[static_cast<std::size_t>(y) * width + x] = static_cast<std::uint8_t>(16 + ((x + y + frame * 8) % 220));
            context->UpdateSubresource(texture.Get(), 0, nullptr, pixels.data(), width, 0);
            if (frame == 60) encoder.request_idr();
            const auto output = encoder.encode(texture.Get(), frame, encoder.generation());
            const auto& unit = output.unit;
            const auto& bytes = output.annex_b;
            if (unit.idr != (frame == 0 || frame == 60)) throw std::runtime_error("Unexpected IDR placement");
            idrs += unit.idr ? 1u : 0u;
            write_bytes(video, bytes);
            record(payloads, unit.payload);
            record(configs, unit.config);
            csv << frame << ',' << output.timestamp << ',' << unit.idr << ',' << bytes.size() << ',' << unit.payload.size() << ',' << unit.config.size() << ',' << output.encode_and_lock_ms << ',' << output.hardware_status_raw << '\n';
        }
        const auto wall = std::chrono::duration<double>(Clock::now() - started).count();
        for (auto* stream : {&video, &payloads, &configs, &csv}) stream->close();
        if (!encoder.close()) throw std::runtime_error("Encoder cleanup failed");
        std::ofstream result(out / "result.json");
        result.exceptions(std::ios::failbit | std::ios::badbit);
        result << "{\"schema_version\":1,\"status\":\"passed\",\"backend\":\"native-nvenc-d3d11\",\"driver_api\":" << driver_api << ",\"header_api_major\":" << NVENCAPI_MAJOR_VERSION << ",\"adapter_index\":" << index << ",\"vendor_id\":" << desc.VendorId << ",\"device_id\":" << desc.DeviceId << ",\"width\":" << width << ",\"height\":" << height << ",\"fps\":60,\"frames\":120,\"idr_frames\":" << idrs << ",\"bitrate\":" << bitrate << ",\"wall_seconds\":" << wall << ",\"capture\":\"synthetic_cpu_nv12_upload\",\"software_encoder_fallback\":false,\"desktop_captured\":false,\"limits\":[\"Synchronous synthetic encode only; no network or desktop capture\",\"Encode/lock span includes waits; not end-to-end latency or displayed FPS\"]}\n";
        result.close();
        std::cout << "Native NVENC encode passed: 120 frames, two forced IDRs, no B frames\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

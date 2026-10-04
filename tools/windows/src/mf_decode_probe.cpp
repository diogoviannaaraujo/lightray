#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <d3d10_1.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <mfreadwrite.h>
#include <wrl/client.h>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

static void check(HRESULT result, const char* operation) {
    if (FAILED(result)) throw std::runtime_error(std::string(operation) + " HRESULT=" + std::to_string(result));
}

struct Runtime {
    Runtime() {
        check(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "CoInitializeEx");
        const HRESULT media = MFStartup(MF_VERSION);
        if (FAILED(media)) { CoUninitialize(); check(media, "MFStartup"); }
    }
    ~Runtime() { MFShutdown(); CoUninitialize(); }
};

struct Hash {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    Hash() { if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) throw std::runtime_error("SHA256 unavailable"); }
    ~Hash() { BCryptCloseAlgorithmProvider(algorithm, 0); }
    void write(std::ofstream& output, std::vector<uint8_t>& pixels) const {
        uint8_t digest[32]{};
        if (pixels.size() > ULONG_MAX || BCryptHash(algorithm, nullptr, 0, pixels.data(), static_cast<ULONG>(pixels.size()), digest, sizeof(digest)) < 0) throw std::runtime_error("SHA256 failed");
        for (const auto byte : digest) output << std::hex << std::setw(2) << std::setfill('0') << static_cast<unsigned int>(byte);
        output << std::dec;
    }
};

static double percentile(std::vector<double> values, double fraction) {
    if (values.empty()) return 0;
    std::sort(values.begin(), values.end());
    return values[static_cast<size_t>(static_cast<double>(values.size() - 1) * fraction)];
}

struct Geometry {
    UINT32 coded_width = 0, coded_height = 0;
    UINT32 width = 0, height = 0, x = 0, y = 0;
};

static Geometry geometry(IMFMediaType* type) {
    Geometry value;
    check(MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &value.coded_width, &value.coded_height), "Get frame size");
    value.width = value.coded_width;
    value.height = value.coded_height;
    MFVideoArea area{};
    UINT32 size = 0;
    HRESULT aperture = type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8*>(&area), sizeof(area), &size);
    if (aperture == MF_E_ATTRIBUTENOTFOUND) aperture = type->GetBlob(MF_MT_GEOMETRIC_APERTURE, reinterpret_cast<UINT8*>(&area), sizeof(area), &size);
    if (aperture != MF_E_ATTRIBUTENOTFOUND) {
        check(aperture, "Get display aperture");
        if (size != sizeof(area) || area.Area.cx <= 0 || area.Area.cy <= 0 || area.OffsetX.value < 0 || area.OffsetY.value < 0 || area.OffsetX.fract || area.OffsetY.fract) throw std::runtime_error("Unsupported display aperture");
        value.width = static_cast<UINT32>(area.Area.cx);
        value.height = static_cast<UINT32>(area.Area.cy);
        value.x = static_cast<UINT32>(area.OffsetX.value);
        value.y = static_cast<UINT32>(area.OffsetY.value);
    }
    if (!value.width || !value.height || value.coded_width > 8192 || value.coded_height > 8192 || value.x > value.coded_width || value.y > value.coded_height || value.width > value.coded_width - value.x || value.height > value.coded_height - value.y || value.width % 2 || value.height % 2 || value.x % 2 || value.y % 2) throw std::runtime_error("Unsupported NV12 geometry");
    return value;
}

static void test_geometry() {
    Runtime runtime;
    ComPtr<IMFMediaType> type;
    check(MFCreateMediaType(&type), "Create test media type");
    check(MFSetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, 1920, 1088), "Set test size");
    if (geometry(type.Get()).height != 1088) throw std::runtime_error("Uncropped geometry regression");
    MFVideoArea area{};
    area.Area.cx = 1920;
    area.Area.cy = 1080;
    auto set_area = [&](const MFVideoArea& value) { check(type->SetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<const UINT8*>(&value), sizeof(value)), "Set test aperture"); };
    set_area(area);
    if (geometry(type.Get()).height != 1080) throw std::runtime_error("Display aperture regression");
    std::vector<MFVideoArea> invalid(6, area);
    invalid[0].Area.cx = 0;
    invalid[1].Area.cy = 1090;
    invalid[2].OffsetX.value = 1;
    invalid[3].OffsetY.value = 10;
    invalid[4].OffsetY.fract = 1;
    invalid[5].OffsetX.value = -1;
    for (const auto& value : invalid) {
        set_area(value);
        bool rejected = false;
        try { static_cast<void>(geometry(type.Get())); } catch (const std::runtime_error&) { rejected = true; }
        if (!rejected) throw std::runtime_error("Invalid aperture accepted");
    }
    std::cout << "{\"status\":\"passed\",\"geometry_cases\":8}\n";
}

int wmain(int argc, wchar_t** argv) {
    if (argc == 2 && std::wstring(argv[1]) == L"--self-test") {
        try { test_geometry(); return 0; } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
    }
    if (argc != 3) { std::cerr << "Usage: mf_decode_probe input.mp4 output.framehash\n"; return 2; }
    try {
        Runtime runtime;
        Hash hash;
        ComPtr<IDXGIFactory1> factory;
        check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "CreateDXGIFactory1");
        ComPtr<IDXGIAdapter1> adapter;
        check(factory->EnumAdapters1(0, &adapter), "EnumAdapters1");
        ComPtr<ID3D11Device> device;
        ComPtr<ID3D11DeviceContext> context;
        check(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context), "D3D11CreateDevice");
        ComPtr<ID3D10Multithread> multithread;
        check(device.As(&multithread), "ID3D10Multithread");
        multithread->SetMultithreadProtected(TRUE);
        UINT token = 0;
        ComPtr<IMFDXGIDeviceManager> manager;
        check(MFCreateDXGIDeviceManager(&token, &manager), "MFCreateDXGIDeviceManager");
        check(manager->ResetDevice(device.Get(), token), "ResetDevice");
        ComPtr<IMFAttributes> attributes;
        check(MFCreateAttributes(&attributes, 3), "MFCreateAttributes");
        check(attributes->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, manager.Get()), "Set D3D manager");
        check(attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE), "Enable hardware transforms");
        ComPtr<IMFSourceReader> reader;
        check(MFCreateSourceReaderFromURL(argv[1], attributes.Get(), &reader), "MFCreateSourceReaderFromURL");
        check(reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE), "Deselect streams");
        check(reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), TRUE), "Select video");
        ComPtr<IMFMediaType> output_type;
        check(MFCreateMediaType(&output_type), "MFCreateMediaType");
        check(output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video), "Set video type");
        check(output_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12), "Set NV12 type");
        check(reader->SetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr, output_type.Get()), "SetCurrentMediaType");
        check(reader->GetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), &output_type), "GetCurrentMediaType");
        auto layout = geometry(output_type.Get());
        UINT32 width = layout.width, height = layout.height;
        if (std::filesystem::exists(argv[2])) throw std::runtime_error("Output already exists");
        std::ofstream output{std::filesystem::path(argv[2])};
        if (!output) throw std::runtime_error("Cannot open output");
        output << "# SHA256 of yuv420p converted from native Media Foundation NV12 GPU surfaces\n";
        size_t count = 0;
        std::vector<double> read_ms;
        for (size_t iteration = 0; iteration < 10000; ++iteration) {
            DWORD flags = 0;
            LONGLONG timestamp = 0;
            ComPtr<IMFSample> sample;
            const auto start = std::chrono::steady_clock::now();
            check(reader->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, nullptr, &flags, &timestamp, &sample), "ReadSample");
            const double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
            if (flags & MF_SOURCE_READERF_ERROR) throw std::runtime_error("Reader error");
            if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
                ComPtr<IMFMediaType> current;
                check(reader->GetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), &current), "Read changed type");
                const auto changed = geometry(current.Get());
                GUID subtype{};
                check(current->GetGUID(MF_MT_SUBTYPE, &subtype), "Read changed format");
                if (!IsEqualGUID(subtype, MFVideoFormat_NV12) || (count && (changed.width != width || changed.height != height))) throw std::runtime_error("Unexpected output format change");
                layout = changed;
                width = layout.width;
                height = layout.height;
            }
            if (sample) {
                read_ms.push_back(elapsed);
                ComPtr<IMFMediaBuffer> buffer;
                check(sample->GetBufferByIndex(0, &buffer), "GetBufferByIndex");
                ComPtr<IMFDXGIBuffer> gpu;
                check(buffer.As(&gpu), "Expected a GPU-backed sample");
                ComPtr<ID3D11Texture2D> texture;
                check(gpu->GetResource(IID_PPV_ARGS(&texture)), "GetResource");
                UINT subresource = 0;
                check(gpu->GetSubresourceIndex(&subresource), "GetSubresourceIndex");
                D3D11_TEXTURE2D_DESC desc{};
                texture->GetDesc(&desc);
                if (desc.Format != DXGI_FORMAT_NV12 || desc.Width < layout.coded_width || desc.Height < layout.coded_height) throw std::runtime_error("Unsupported GPU surface");
                desc.Usage = D3D11_USAGE_STAGING;
                desc.BindFlags = 0;
                desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                desc.MiscFlags = 0;
                desc.ArraySize = 1;
                desc.MipLevels = 1;
                ComPtr<ID3D11Texture2D> staging;
                check(device->CreateTexture2D(&desc, nullptr, &staging), "Create staging texture");
                context->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, texture.Get(), subresource, nullptr);
                const size_t luma = static_cast<size_t>(width) * height;
                std::vector<uint8_t> pixels(luma * 3 / 2);
                D3D11_MAPPED_SUBRESOURCE mapped{};
                check(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped), "Map staging texture");
                const auto* base = static_cast<const uint8_t*>(mapped.pData);
                for (UINT32 y = 0; y < height; ++y) std::copy_n(base + static_cast<size_t>(y + layout.y) * mapped.RowPitch + layout.x, width, pixels.data() + static_cast<size_t>(y) * width);
                const auto* chroma = base + static_cast<size_t>(desc.Height) * mapped.RowPitch;
                for (UINT32 y = 0; y < height / 2; ++y) {
                    for (UINT32 x = 0; x < width / 2; ++x) {
                        pixels[luma + static_cast<size_t>(y) * (width / 2) + x] = chroma[static_cast<size_t>(y + layout.y / 2) * mapped.RowPitch + layout.x + 2 * x];
                        pixels[luma + luma / 4 + static_cast<size_t>(y) * (width / 2) + x] = chroma[static_cast<size_t>(y + layout.y / 2) * mapped.RowPitch + layout.x + 2 * x + 1];
                    }
                }
                context->Unmap(staging.Get(), 0);
                output << "0, " << count << ", " << count << ", 1, " << pixels.size() << ", ";
                hash.write(output, pixels);
                output << '\n';
                ++count;
            }
            if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
            if (iteration == 9999) throw std::runtime_error("Reader iteration limit exceeded");
        }
        output.flush();
        if (!output || !count) throw std::runtime_error("Empty or incomplete output");
        std::cout << "{\"schema_version\":1,\"backend\":\"media-foundation-d3d11\",\"adapter_index\":0,\"width\":" << width << ",\"height\":" << height << ",\"gpu_frames\":" << count << ",\"read_sample_p50_ms\":" << percentile(read_ms, .50) << ",\"read_sample_p95_ms\":" << percentile(read_ms, .95) << ",\"read_sample_p99_ms\":" << percentile(read_ms, .99) << ",\"limits\":[\"ReadSample timing includes demux and decoder waits; excludes GPU download and hashing\",\"Staging allocation and readback per frame are for correctness only\",\"No presentation or input-to-photon measurement\"]}\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
    return 0;
}

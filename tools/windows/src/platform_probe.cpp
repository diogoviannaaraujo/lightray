#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wrl/client.h>
#include <iostream>
#include <string>

using Microsoft::WRL::ComPtr;

static std::string json_string(const wchar_t* value) {
    const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
    if (size <= 0) return "null";
    std::string utf8(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value, -1, utf8.data(), size, nullptr, nullptr);
    utf8.pop_back();
    std::string escaped = "\"";
    for (const unsigned char byte : utf8) {
        if (byte == '\\' || byte == '"') escaped += '\\';
        if (byte >= 32) escaped += static_cast<char>(byte);
    }
    return escaped + '"';
}

static void adapters() {
    ComPtr<IDXGIFactory1> factory;
    const HRESULT created = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    std::cout << "\"dxgi_hresult\":" << created << ",\"adapters\":[";
    if (SUCCEEDED(created)) {
        bool first = true;
        for (UINT index = 0; index < 16; ++index) {
            ComPtr<IDXGIAdapter1> adapter;
            const HRESULT enumerated = factory->EnumAdapters1(index, &adapter);
            if (enumerated == DXGI_ERROR_NOT_FOUND) break;
            if (FAILED(enumerated)) break;
            DXGI_ADAPTER_DESC1 desc{};
            if (FAILED(adapter->GetDesc1(&desc))) continue;
            if (!first) std::cout << ',';
            first = false;
            std::cout << "{\"index\":" << index << ",\"name\":" << json_string(desc.Description) << ",\"vendor_id\":" << desc.VendorId << ",\"software\":" << ((desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) ? "true" : "false") << ",\"dedicated_video_bytes\":" << desc.DedicatedVideoMemory;
            ComPtr<ID3D11Device> device;
            ComPtr<ID3D11DeviceContext> context;
            D3D_FEATURE_LEVEL level{};
            const HRESULT result = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, &level, &context);
            std::cout << ",\"device_hresult\":" << result << ",\"feature_level\":" << static_cast<unsigned int>(level);
            ComPtr<ID3D11VideoDevice> video;
            const HRESULT query = SUCCEEDED(result) ? device.As(&video) : result;
            bool hevc = false;
            if (SUCCEEDED(query)) {
                for (UINT i = 0; i < video->GetVideoDecoderProfileCount(); ++i) {
                    GUID profile{};
                    if (SUCCEEDED(video->GetVideoDecoderProfile(i, &profile)) && IsEqualGUID(profile, D3D11_DECODER_PROFILE_HEVC_VLD_MAIN)) hevc = true;
                }
            }
            std::cout << ",\"video_interface_hresult\":" << query << ",\"hevc_main_profile\":" << (hevc ? "true" : "false") << ",\"configurations\":[";
            if (hevc) {
                for (UINT i = 0; i < 3; ++i) {
                    const UINT widths[] = {1920, 2560, 3840};
                    const UINT heights[] = {1080, 1440, 2160};
                    D3D11_VIDEO_DECODER_DESC decoder{D3D11_DECODER_PROFILE_HEVC_VLD_MAIN, widths[i], heights[i], DXGI_FORMAT_NV12};
                    UINT count = 0;
                    const HRESULT config = video->GetVideoDecoderConfigCount(&decoder, &count);
                    if (i) std::cout << ',';
                    std::cout << "{\"width\":" << widths[i] << ",\"height\":" << heights[i] << ",\"hresult\":" << config << ",\"count\":" << count << '}';
                }
            }
            std::cout << "]}";
        }
    }
    std::cout << ']';
}

static void transforms() {
    const MFT_REGISTER_TYPE_INFO input{MFMediaType_Video, MFVideoFormat_HEVC};
    IMFActivate** activations = nullptr;
    UINT32 count = 0;
    const HRESULT result = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, MFT_ENUM_FLAG_ALL | MFT_ENUM_FLAG_SORTANDFILTER, &input, nullptr, &activations, &count);
    std::cout << ",\"hevc_mft_enumeration_hresult\":" << result << ",\"hevc_mfts\":[";
    for (UINT32 i = 0; i < count; ++i) {
        WCHAR* name = nullptr;
        UINT32 length = 0;
        activations[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &name, &length);
        ComPtr<IMFTransform> transform;
        const HRESULT activated = activations[i]->ActivateObject(IID_PPV_ARGS(&transform));
        UINT32 aware = 0;
        ComPtr<IMFAttributes> attributes;
        if (SUCCEEDED(activated) && SUCCEEDED(transform->GetAttributes(&attributes))) attributes->GetUINT32(MF_SA_D3D11_AWARE, &aware);
        if (i) std::cout << ',';
        std::cout << "{\"name\":" << (name ? json_string(name) : "null") << ",\"activation_hresult\":" << activated << ",\"d3d11_aware\":" << (aware ? "true" : "false") << '}';
        CoTaskMemFree(name);
        transform.Reset();
        activations[i]->ShutdownObject();
        activations[i]->Release();
    }
    CoTaskMemFree(activations);
    std::cout << ']';
}

int main() {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com)) { std::cerr << "COM initialization failed: " << com << '\n'; return 1; }
    const HRESULT media = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (FAILED(media)) { CoUninitialize(); std::cerr << "Media Foundation initialization failed: " << media << '\n'; return 1; }
    std::cout << "{\"schema_version\":1,\"probe\":\"windows-platform\",\"msvc\":" << _MSC_FULL_VER << ',';
    adapters();
    transforms();
    std::cout << ",\"limits\":[\"Capability discovery only; actual decode is a separate test\",\"No window, swapchain or input injection\"]}\n";
    MFShutdown();
    CoUninitialize();
    return 0;
}

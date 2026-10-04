#pragma once
#include <d3d11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <wrl/client.h>
#include <stdexcept>
#include <iostream>

namespace lightray {
class CaptureApartment {
public:
    CaptureApartment() { winrt::init_apartment(winrt::apartment_type::multi_threaded); }
    ~CaptureApartment() { winrt::uninit_apartment(); }
    CaptureApartment(const CaptureApartment &) = delete;
    CaptureApartment &operator=(const CaptureApartment &) = delete;
};

// Uses the encoder's D3D11 device and keeps each frame alive through GPU conversion.
class WgcCapture {
    winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool pool_{nullptr};
    winrt::Windows::Graphics::Capture::GraphicsCaptureSession session_{nullptr};
    winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame held_{nullptr};
    winrt::Windows::Graphics::SizeInt32 size_{};
public:
    WgcCapture(ID3D11Device *device, HMONITOR monitor, unsigned width, unsigned height) {
        using namespace winrt::Windows::Graphics;
        if (!Capture::GraphicsCaptureSession::IsSupported()) throw std::runtime_error("Windows Graphics Capture unavailable");
        Microsoft::WRL::ComPtr<IDXGIDevice> dxgi;
        winrt::check_hresult(device->QueryInterface(IID_PPV_ARGS(&dxgi)));
        winrt::com_ptr<IInspectable> inspectable;
        winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(), inspectable.put()));
        auto projected = inspectable.as<winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice>();
        auto interop = winrt::get_activation_factory<Capture::GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        Capture::GraphicsCaptureItem item{nullptr};
        winrt::check_hresult(interop->CreateForMonitor(monitor, winrt::guid_of<Capture::GraphicsCaptureItem>(), winrt::put_abi(item)));
        size_ = item.Size();
        if (size_.Width != static_cast<int>(width) || size_.Height != static_cast<int>(height)) throw std::runtime_error("WGC geometry differs from selected output");
        pool_ = Capture::Direct3D11CaptureFramePool::CreateFreeThreaded(projected, winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size_);
        session_ = pool_.CreateCaptureSession(item);
        // Keep the system capture border and cursor behavior; no permission bypass.
        session_.StartCapture();
    }
    ~WgcCapture() {
        // IClosable cleanup can fail during shutdown; report it without throwing from a destructor.
        try { release(); if (session_) session_.Close(); if (pool_) pool_.Close(); }
        catch (const winrt::hresult_error &error) { std::cerr << "WGC close HRESULT " << error.code().value << '\n'; }
    }
    Microsoft::WRL::ComPtr<ID3D11Texture2D> next() {
        release();
        held_ = pool_.TryGetNextFrame();
        if (!held_) return {};
        // Drain at most two pool buffers and retain the latest available picture.
        auto newer = pool_.TryGetNextFrame();
        if (newer) { held_.Close(); held_ = newer; }
        const auto current = held_.ContentSize();
        if (current.Width != size_.Width || current.Height != size_.Height) throw std::runtime_error("WGC geometry changed; host restart required");
        auto access = held_.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
        Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
        winrt::check_hresult(access->GetInterface(IID_PPV_ARGS(&texture)));
        D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
        if (desc.Width != static_cast<unsigned>(size_.Width) || desc.Height != static_cast<unsigned>(size_.Height) || desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM) throw std::runtime_error("Unsupported WGC texture format");
        return texture;
    }
    void release() { if (held_) { held_.Close(); held_ = nullptr; } }
};
} // namespace lightray

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <iostream>

using namespace winrt::Windows::Graphics::Capture;

// A bounded alternative-capture diagnostic; no input, encoding or saved pixels.
int main() {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        DWORD session_id = 0;
        winrt::check_bool(ProcessIdToSessionId(GetCurrentProcessId(), &session_id));
        std::cout << "backend=wgc process_session=" << session_id << " console_session=" << WTSGetActiveConsoleSessionId() << '\n';
        const auto supported = GraphicsCaptureSession::IsSupported();
        std::cout << "capture_supported=" << supported << '\n';
        if (!supported) return 2;
        winrt::com_ptr<IDXGIFactory1> factory;
        winrt::check_hresult(CreateDXGIFactory1(__uuidof(IDXGIFactory1), factory.put_void()));
        winrt::com_ptr<IDXGIAdapter1> adapter;
        winrt::check_hresult(factory->EnumAdapters1(0, adapter.put()));
        DXGI_ADAPTER_DESC1 adapter_info{};
        winrt::check_hresult(adapter->GetDesc1(&adapter_info));
        std::wcout << L"adapter_vendor=" << adapter_info.VendorId << L" software=" << ((adapter_info.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) << L" name=" << adapter_info.Description << L"\n";
        winrt::com_ptr<IDXGIOutput> output;
        winrt::check_hresult(adapter->EnumOutputs(0, output.put()));
        DXGI_OUTPUT_DESC output_info{};
        winrt::check_hresult(output->GetDesc(&output_info));
        std::wcout << L"output=" << output_info.DeviceName << L" attached=" << output_info.AttachedToDesktop << L"\n";
        winrt::com_ptr<ID3D11Device> device;
        winrt::check_hresult(D3D11CreateDevice(adapter.get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, device.put(), nullptr, nullptr));
        auto dxgi = device.as<IDXGIDevice>();
        winrt::com_ptr<IInspectable> inspectable;
        winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()));
        auto projected_device = inspectable.as<winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice>();
        auto interop = winrt::get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        GraphicsCaptureItem item{nullptr};
        winrt::check_hresult(interop->CreateForMonitor(output_info.Monitor, winrt::guid_of<GraphicsCaptureItem>(), winrt::put_abi(item)));
        const auto size = item.Size();
        std::cout << "item_size=" << size.Width << 'x' << size.Height << '\n' << std::flush;
        auto pool = Direct3D11CaptureFramePool::CreateFreeThreaded(projected_device, winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
        auto session = pool.CreateCaptureSession(item);
        // Keep the platform's capture indicator and default cursor behavior.
        session.StartCapture();
        unsigned frames = 0, empty_polls = 0, size_changes = 0;
        D3D11_TEXTURE2D_DESC texture_info{};
        const auto start = GetTickCount64();
        while (GetTickCount64() - start < 5000) {
            auto frame = pool.TryGetNextFrame();
            if (!frame) { ++empty_polls; Sleep(5); continue; }
            const auto current = frame.ContentSize();
            if (current.Width != size.Width || current.Height != size.Height) ++size_changes;
            auto access = frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
            winrt::com_ptr<ID3D11Texture2D> texture;
            winrt::check_hresult(access->GetInterface(__uuidof(ID3D11Texture2D), texture.put_void()));
            texture->GetDesc(&texture_info);
            ++frames;
            frame.Close();
        }
        session.Close();
        pool.Close();
        std::cout << "capture_frames=" << frames << " empty_polls=" << empty_polls << " size_changes=" << size_changes << " texture_size=" << texture_info.Width << 'x' << texture_info.Height << " texture_format=" << texture_info.Format << " device_removed_hresult=" << device->GetDeviceRemovedReason() << " elapsed_ms=" << GetTickCount64() - start << '\n';
        return frames && !size_changes ? 0 : 2;
    } catch (const winrt::hresult_error &error) {
        std::cerr << "capture_hresult=" << error.code().value << '\n';
        return 1;
    } catch (const std::exception &error) {
        std::cerr << "capture_error=" << error.what() << '\n';
        return 1;
    }
}

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <dwmapi.h>
#include <wtsapi32.h>
#include <wrl/client.h>
#include <iostream>
using Microsoft::WRL::ComPtr;

static void describe_desktop(HANDLE handle, const char *label) {
    wchar_t name[256]{};
    DWORD needed = 0;
    if (handle && GetUserObjectInformationW(handle, UOI_NAME, name, sizeof(name), &needed))
        std::wcout << label << L"=" << name << L"\n";
    else
        std::cout << label << "_error=" << GetLastError() << '\n';
}

int main() {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    DWORD session = 0;
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &session)) return 1;
    std::cout << "process_session=" << session << " console_session=" << WTSGetActiveConsoleSessionId() << '\n';
    describe_desktop(GetProcessWindowStation(), "window_station");
    describe_desktop(GetThreadDesktop(GetCurrentThreadId()), "thread_desktop");
    const auto input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    describe_desktop(input, "input_desktop");
    if (input) CloseDesktop(input);
    BOOL composition = FALSE;
    const auto composition_status = DwmIsCompositionEnabled(&composition);
    std::cout << "dwm_hresult=" << composition_status << " composition=" << composition << '\n';
    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return 1;
    ComPtr<IDXGIAdapter1> selected;
    for (UINT i = 0; i < 8; ++i) {
        ComPtr<IDXGIAdapter1> adapter;
        const auto status = factory->EnumAdapters1(i, &adapter);
        if (status == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(status)) return 1;
        DXGI_ADAPTER_DESC1 desc{};
        if (FAILED(adapter->GetDesc1(&desc))) return 1;
        std::wcout << L"adapter=" << i << L" vendor=" << desc.VendorId << L" software=" << ((desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) << L" name=" << desc.Description << L"\n";
        if (i == 0) selected = adapter;
        for (UINT j = 0; j < 8; ++j) {
            ComPtr<IDXGIOutput> output;
            const auto output_status = adapter->EnumOutputs(j, &output);
            if (output_status == DXGI_ERROR_NOT_FOUND) break;
            if (FAILED(output_status)) return 1;
            DXGI_OUTPUT_DESC mode{};
            if (FAILED(output->GetDesc(&mode))) return 1;
            std::wcout << L"output=" << j << L" device=" << mode.DeviceName << L" attached=" << mode.AttachedToDesktop << L" rotation=" << mode.Rotation << L" rect=" << mode.DesktopCoordinates.left << L"," << mode.DesktopCoordinates.top << L"," << mode.DesktopCoordinates.right << L"," << mode.DesktopCoordinates.bottom << L"\n";
        }
    }
    if (!selected) return 1;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    const auto created = D3D11CreateDevice(selected.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context);
    std::cout << "device_hresult=" << created << '\n';
    if (FAILED(created)) return 1;
    ComPtr<IDXGIOutput> output;
    ComPtr<IDXGIOutput1> output1;
    if (FAILED(selected->EnumOutputs(0, &output)) || FAILED(output.As(&output1))) return 1;
    ComPtr<IDXGIOutputDuplication> duplication;
    const auto duplicate = output1->DuplicateOutput(device.Get(), &duplication);
    std::cout << "duplicate_hresult=" << duplicate << '\n' << std::flush;
    if (FAILED(duplicate)) return 2;
    DXGI_OUTDUPL_DESC mode{};
    duplication->GetDesc(&mode);
    std::cout << "mode=" << mode.ModeDesc.Width << 'x' << mode.ModeDesc.Height << " refresh=" << mode.ModeDesc.RefreshRate.Numerator << '/' << mode.ModeDesc.RefreshRate.Denominator << " format=" << mode.ModeDesc.Format << '\n';
    unsigned frames = 0, updates = 0, pointer_only = 0, timeouts = 0;
    HRESULT last = S_OK;
    const auto started = GetTickCount64();
    while (GetTickCount64() - started < 5000) {
        DXGI_OUTDUPL_FRAME_INFO info{};
        ComPtr<IDXGIResource> resource;
        last = duplication->AcquireNextFrame(16, &info, &resource);
        if (last == DXGI_ERROR_WAIT_TIMEOUT) { ++timeouts; continue; }
        if (FAILED(last)) break;
        ++frames;
        if (info.LastPresentTime.QuadPart) ++updates; else ++pointer_only;
        last = duplication->ReleaseFrame();
        if (FAILED(last)) break;
    }
    std::cout << "capture_frames=" << frames << " desktop_updates=" << updates << " pointer_only=" << pointer_only << " acquisition_timeouts=" << timeouts << " last_hresult=" << last << " device_removed_hresult=" << device->GetDeviceRemovedReason() << " elapsed_ms=" << GetTickCount64() - started << '\n';
    return frames ? 0 : 2;
}

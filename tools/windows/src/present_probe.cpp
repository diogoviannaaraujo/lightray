#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define UNICODE
#include <windows.h>
#include <d3d11_1.h>
#include <dxgi1_3.h>
#include <wrl/client.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using Microsoft::WRL::ComPtr;
using Clock = std::chrono::steady_clock;

static void check(HRESULT result, const char* action) {
    if (FAILED(result)) throw std::runtime_error(std::string(action) + " HRESULT=" + std::to_string(result));
}

static double milliseconds(Clock::time_point from, Clock::time_point to) {
    return std::chrono::duration<double, std::milli>(to - from).count();
}

static double percentile(std::vector<double> values, double fraction) {
    if (values.empty() || fraction <= 0 || fraction > 1) throw std::runtime_error("Invalid percentile input");
    std::sort(values.begin(), values.end());
    return values[static_cast<size_t>(std::ceil(fraction * static_cast<double>(values.size()))) - 1];
}

struct Options { UINT latency, width, height, frames; };

static void validate(const Options& options) {
    const bool dimensions = (options.width == 1920 && options.height == 1080) || (options.width == 2560 && options.height == 1440) || (options.width == 3840 && options.height == 2160);
    if ((options.latency != 1 && options.latency != 2) || !dimensions || options.frames < 120 || options.frames > 1200) throw std::runtime_error("Unsupported presentation experiment parameters");
}

static UINT number(const wchar_t* text) {
    const std::wstring value(text);
    if (value.empty() || value.find_first_not_of(L"0123456789") != std::wstring::npos) throw std::runtime_error("Expected an unsigned decimal integer");
    const auto parsed = std::stoul(value);
    if (parsed > 8192) throw std::runtime_error("Numeric parameter exceeds the lab limit");
    return static_cast<UINT>(parsed);
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, message, wparam, lparam);
}

struct Window {
    HWND handle = nullptr;
    ~Window() { if (handle && IsWindow(handle)) DestroyWindow(handle); }
};

struct WaitHandle {
    HANDLE handle = nullptr;
    ~WaitHandle() { if (handle) CloseHandle(handle); }
};

static void pump_messages() {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        if (message.message == WM_QUIT) throw std::runtime_error("Window closed before completion");
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
}

static void wait_for_frame(HANDLE handle) {
    const auto deadline = Clock::now() + std::chrono::seconds(3);
    while (Clock::now() < deadline) {
        const DWORD result = MsgWaitForMultipleObjectsEx(1, &handle, 100, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (result == WAIT_OBJECT_0) { pump_messages(); return; }
        if (result == WAIT_FAILED) throw std::runtime_error("Frame wait failed");
        pump_messages();
    }
    throw std::runtime_error("Frame latency wait timed out");
}

static void self_test() {
    for (const UINT latency : {1u, 2u}) for (const auto size : {std::pair{1920u, 1080u}, std::pair{2560u, 1440u}, std::pair{3840u, 2160u}}) validate({latency, size.first, size.second, 600});
    for (const Options invalid : {Options{0, 1920, 1080, 600}, Options{3, 1920, 1080, 600}, Options{1, 3840, 1080, 600}, Options{1, 1920, 1080, 0}, Options{1, 1920, 1080, 1201}}) {
        bool rejected = false;
        try { validate(invalid); } catch (const std::runtime_error&) { rejected = true; }
        if (!rejected) throw std::runtime_error("Invalid parameters accepted");
    }
    if (percentile({9, 1, 7, 3, 5}, .50) != 5 || percentile({9, 1, 7, 3, 5}, .95) != 9) throw std::runtime_error("Percentile regression");
    bool empty_rejected = false;
    try { static_cast<void>(percentile({}, .50)); } catch (const std::runtime_error&) { empty_rejected = true; }
    if (!empty_rejected) throw std::runtime_error("Empty percentile input accepted");
    std::cout << "{\"status\":\"passed\",\"parameter_cases\":11,\"statistics_cases\":3,\"windows_opened\":0}\n";
}

static void present(const Options& options, const std::filesystem::path& output_path) {
    validate(options);
    auto csv_path = output_path;
    csv_path.replace_extension(".csv");
    if (output_path.extension() != L".json" || std::filesystem::exists(output_path) || std::filesystem::exists(csv_path)) throw std::runtime_error("Output must be a new JSON/CSV pair");
    std::ofstream output(output_path), csv(csv_path);
    if (!output || !csv) throw std::runtime_error("Cannot create result files");
    try {
        if (!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) throw std::runtime_error("Cannot set DPI awareness");
        WNDCLASSW type{};
        type.lpfnWndProc = window_proc;
        type.hInstance = GetModuleHandleW(nullptr);
        type.lpszClassName = L"LightrayPresentationProbe";
        type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        if (!RegisterClassW(&type)) throw std::runtime_error("Cannot register presentation window");
        const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
        RECT bounds{0, 0, 1280, 720};
        if (!AdjustWindowRectEx(&bounds, style, FALSE, 0)) throw std::runtime_error("Cannot calculate window bounds");
        Window window;
        window.handle = CreateWindowExW(0, type.lpszClassName, L"Lightray: bounded D3D11 presentation test", style, CW_USEDEFAULT, CW_USEDEFAULT, bounds.right - bounds.left, bounds.bottom - bounds.top, nullptr, nullptr, type.hInstance, nullptr);
        if (!window.handle) throw std::runtime_error("Cannot create presentation window");
        ComPtr<IDXGIFactory2> factory;
        check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "Create DXGI factory");
        ComPtr<IDXGIAdapter1> adapter;
        check(factory->EnumAdapters1(0, &adapter), "Select adapter 0");
        DXGI_ADAPTER_DESC1 adapter_desc{};
        check(adapter->GetDesc1(&adapter_desc), "Read adapter");
        if (adapter_desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) throw std::runtime_error("Software adapter rejected");
        ComPtr<ID3D11Device> device;
        ComPtr<ID3D11DeviceContext> context;
        check(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context), "Create D3D11 device");
        ComPtr<ID3D11DeviceContext1> context1;
        check(context.As(&context1), "Get D3D11.1 context");
        DXGI_SWAP_CHAIN_DESC1 desc{};
        desc.Width = options.width;
        desc.Height = options.height;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.Scaling = DXGI_SCALING_STRETCH;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        desc.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
        ComPtr<IDXGISwapChain1> chain1;
        check(factory->CreateSwapChainForHwnd(device.Get(), window.handle, &desc, nullptr, nullptr, &chain1), "Create flip swapchain");
        check(factory->MakeWindowAssociation(window.handle, DXGI_MWA_NO_ALT_ENTER), "Disable implicit fullscreen");
        ComPtr<IDXGISwapChain2> chain;
        check(chain1.As(&chain), "Get swapchain2");
        check(chain->SetMaximumFrameLatency(options.latency), "Set queue depth");
        WaitHandle ready{chain->GetFrameLatencyWaitableObject()};
        if (!ready.handle) throw std::runtime_error("Waitable swapchain handle unavailable");
        ComPtr<ID3D11Texture2D> buffer;
        check(chain->GetBuffer(0, IID_PPV_ARGS(&buffer)), "Get backbuffer");
        ComPtr<ID3D11RenderTargetView> target;
        check(device->CreateRenderTargetView(buffer.Get(), nullptr, &target), "Create render target");
        ShowWindow(window.handle, SW_SHOWNOACTIVATE);
        csv << "frame,wait_ms,cpu_submit_ms,present_call_ms,submit_interval_ms\n";
        const auto start = Clock::now();
        auto previous = start;
        std::vector<double> intervals, waits, presents;
        for (UINT frame = 0; frame < options.frames; ++frame) {
            if (Clock::now() - start > std::chrono::seconds(30)) throw std::runtime_error("30-second presentation budget exceeded");
            const auto before_wait = Clock::now();
            wait_for_frame(ready.handle);
            const auto after_wait = Clock::now();
            const FLOAT background[] = {0.12f, 0.12f, 0.12f, 1.f};
            const FLOAT bar_color[] = {0.24f, 0.32f, 0.30f, 1.f};
            context->ClearRenderTargetView(target.Get(), background);
            const LONG position = static_cast<LONG>((static_cast<std::uint64_t>(frame) * 8) % (options.width - 64));
            const D3D11_RECT bar{position, 0, position + 64, static_cast<LONG>(options.height)};
            context1->ClearView(target.Get(), bar_color, &bar, 1);
            const auto before_present = Clock::now();
            const HRESULT result = chain->Present(1, 0);
            if (result == DXGI_STATUS_OCCLUDED) throw std::runtime_error("Window occluded; presentation run is invalid");
            check(result, "Present");
            const auto after_present = Clock::now();
            const double interval = milliseconds(previous, after_present);
            waits.push_back(milliseconds(before_wait, after_wait));
            presents.push_back(milliseconds(before_present, after_present));
            if (frame) intervals.push_back(interval);
            csv << frame << ',' << waits.back() << ',' << milliseconds(after_wait, before_present) << ',' << presents.back() << ',' << (frame ? interval : 0) << '\n';
            previous = after_present;
        }
        const double seconds = milliseconds(start, Clock::now()) / 1000;
        csv.flush();
        if (!csv) throw std::runtime_error("Cannot persist frame measurements");
        output << "{\"schema_version\":1,\"status\":\"passed\",\"maximum_frame_latency\":" << options.latency << ",\"buffer_width\":" << options.width << ",\"buffer_height\":" << options.height << ",\"frames_submitted\":" << options.frames << ",\"wall_seconds\":" << seconds << ",\"present_calls_per_second\":" << options.frames / seconds << ",\"submit_interval_p50_ms\":" << percentile(intervals, .50) << ",\"submit_interval_p95_ms\":" << percentile(intervals, .95) << ",\"submit_interval_p99_ms\":" << percentile(intervals, .99) << ",\"wait_p95_ms\":" << percentile(waits, .95) << ",\"present_call_p95_ms\":" << percentile(presents, .95) << ",\"limits\":[\"Synthetic moving bar; no video, network or input\",\"1280x720 window; framebuffer size is not physical presentation resolution\",\"Submission timings only; not displayed FPS or input-to-photon latency\"]}\n";
        output.flush();
        if (!output) throw std::runtime_error("Cannot persist run summary");
    } catch (...) {
        output << "{\"schema_version\":1,\"status\":\"failed\",\"reason\":\"presentation_incomplete\"}\n";
        throw;
    }
}

int wmain(int argc, wchar_t** argv) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    try {
        if (argc == 2 && std::wstring(argv[1]) == L"--self-test") { self_test(); return 0; }
        if (argc != 7 || std::wstring(argv[1]) != L"--present") { std::cerr << "Usage: present_probe --self-test OR --present latency width height frames new-result.json\n"; return 2; }
        present({number(argv[2]), number(argv[3]), number(argv[4]), number(argv[5])}, argv[6]);
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

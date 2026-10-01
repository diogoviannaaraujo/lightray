#define NOMINMAX
#include <filesystem>
#include <fstream>
#include <string>
#include <atomic>
#include <thread>
#include <windows.h>

namespace {
HWND edit = nullptr;
HFONT font = nullptr;
std::filesystem::path output;
unsigned clicks = 0, ticks = 0, scrolls = 0;
unsigned control_shortcuts = 0;
unsigned copy_shortcuts = 0, paste_shortcuts = 0, focus_losses = 0;
bool motion = false;
std::atomic<bool> animating = false, pending_paint = false, animation_failed = false;
std::thread animation_thread;
unsigned animation_paints = 0;
WNDPROC original_edit_proc = nullptr;
constexpr wchar_t expected[] = L"lightray windows test";

LRESULT CALLBACK edit_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_KEYDOWN && (GetKeyState(VK_CONTROL) & 0x8000)) {
        if (wparam == 'C') ++copy_shortcuts;
        if (wparam == 'V') ++paste_shortcuts;
    }
    if (message == WM_KEYDOWN && wparam == 'A' && (GetKeyState(VK_CONTROL) & 0x8000)) {
        ++control_shortcuts;
        SendMessageW(window, EM_SETSEL, 0, -1);
        return 0;
    }
    // The classic EDIT control has no built-in select-all shortcut.
    if (message == WM_CHAR && wparam == 1)
        return 0;
    return CallWindowProcW(original_edit_proc, window, message, wparam, lparam);
}

void save_result() {
    wchar_t text[256]{};
    GetWindowTextW(edit, text, 256);
    POINT pointer{};
    GetCursorPos(&pointer);
    std::ofstream result(output, std::ios::trunc);
    result << "{\"test_text_matches\":" << (std::wstring(text) == expected ? "true" : "false") << ",\"button_clicks\":" << clicks << ",\"scroll_events\":" << scrolls << ",\"control_shortcuts\":" << control_shortcuts << ",\"copy_shortcuts\":" << copy_shortcuts << ",\"paste_shortcuts\":" << paste_shortcuts << ",\"focus_losses\":" << focus_losses << ",\"animation_paints\":" << animation_paints << ",\"animation_failed\":" << (animation_failed ? "true" : "false") << ",\"ticks\":" << ticks << ",\"cursor_x\":" << pointer.x << ",\"cursor_y\":" << pointer.y << ",\"test_foreground\":" << (GetForegroundWindow() == GetParent(edit) ? "true" : "false") << "}\n";
}

LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_ACTIVATE:
        if (LOWORD(wparam) == WA_INACTIVE) ++focus_losses;
        break;
    case WM_CREATE: {
        RECT bounds{};
        GetClientRect(window, &bounds);
        const auto width = bounds.right, height = bounds.bottom;
        font = CreateFontW(48, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, width / 4, height / 3, width / 2, 90, window, nullptr, nullptr, nullptr);
        original_edit_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(edit, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(edit_proc)));
        SendMessageW(edit, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
        auto button = CreateWindowW(L"BUTTON", L"Test remote click", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, width / 4, height / 2, width / 2, 110, window, reinterpret_cast<HMENU>(1), nullptr, nullptr);
        SendMessageW(button, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
        SetTimer(window, 1, 250, nullptr);
        return 0;
    }
    case WM_APP + 1:
        pending_paint = false;
        InvalidateRect(window, nullptr, FALSE);
        UpdateWindow(window);
        return 0;
    case WM_COMMAND:
        if (LOWORD(wparam) == 1 && HIWORD(wparam) == BN_CLICKED) {
            ++clicks;
            save_result();
            InvalidateRect(window, nullptr, FALSE);
        }
        return 0;
    case WM_MOUSEWHEEL:
        ++scrolls;
        save_result();
        return 0;
    case WM_TIMER:
        ++ticks;
        save_result();
        InvalidateRect(window, nullptr, FALSE);
        if (ticks >= 2400)
            DestroyWindow(window);
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT paint{};
        auto dc = BeginPaint(window, &paint);
        RECT bounds{};
        GetClientRect(window, &bounds);
        if (motion)
            ++animation_paints;
        auto brush = CreateSolidBrush(RGB(16, 32, 48));
        FillRect(dc, &bounds, brush);
        DeleteObject(brush);
        if (motion) {
            const auto phase = static_cast<LONG>(GetTickCount64() % 2000) * bounds.right / 2000;
            for (LONG x = -bounds.right; x < bounds.right; x += 240) {
                RECT stripe{x + phase, bounds.bottom * 3 / 5, x + phase + 120, bounds.bottom * 7 / 10};
                auto color = CreateSolidBrush(RGB(20, 190, 220));
                FillRect(dc, &stripe, color);
                DeleteObject(color);
            }
        }
        SelectObject(dc, font);
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(240, 245, 255));
        RECT label{bounds.right / 8, bounds.bottom / 8, bounds.right * 7 / 8, bounds.bottom / 3};
        DrawTextW(dc, L"LIGHTRAY / WINDOWS / RTX 4090\nType: lightray windows test", -1, &label, DT_CENTER);
        std::wstring status = L"Remote clicks: " + std::to_wstring(clicks) + L"     Live tick: " + std::to_wstring(ticks);
        label = {bounds.right / 8, bounds.bottom * 3 / 4, bounds.right * 7 / 8, bounds.bottom};
        DrawTextW(dc, status.c_str(), -1, &label, DT_CENTER);
        EndPaint(window, &paint);
        return 0;
    }
    case WM_DESTROY:
        animating = false;
        if (animation_thread.joinable())
            animation_thread.join();
        KillTimer(window, 1);
        if (font)
            DeleteObject(font);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
} // namespace

int wmain(int argc, wchar_t **argv) {
    if (argc != 2 && argc != 3)
        return 2;
    output = argv[1];
    if (argc == 3) {
        if (std::wstring(argv[2]) != L"--motion")
            return 2;
        motion = true;
    }
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const auto instance = GetModuleHandleW(nullptr);
    WNDCLASSW type{};
    type.lpfnWndProc = window_proc;
    type.hInstance = instance;
    type.lpszClassName = L"LightrayDesktopTest";
    type.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
    if (!RegisterClassW(&type))
        return 3;
    auto window = CreateWindowW(type.lpszClassName, L"Lightray Windows Test", WS_POPUP | WS_VISIBLE | WS_CLIPCHILDREN, 0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN), nullptr, nullptr, instance, nullptr);
    if (!window)
        return 4;
    ShowWindow(window, SW_SHOW);
    SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    SetForegroundWindow(window);
    if (motion) {
        animating = true;
        animation_thread = std::thread([window] {
            HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
            if (!timer) {
                animation_failed = true;
                return;
            }
            while (animating) {
                LARGE_INTEGER due{};
                due.QuadPart = -83330;
                if (!SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE) || WaitForSingleObject(timer, 100) != WAIT_OBJECT_0) {
                    animation_failed = true;
                    break;
                }
                if (!pending_paint.exchange(true) && !PostMessageW(window, WM_APP + 1, 0, 0)) {
                    animation_failed = true;
                    break;
                }
            }
            CloseHandle(timer);
        });
    }
    MSG message{};
    int status;
    while ((status = static_cast<int>(GetMessageW(&message, nullptr, 0, 0))) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return status < 0 ? 5 : 0;
}

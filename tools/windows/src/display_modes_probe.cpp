#define NOMINMAX
#include <windows.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <iostream>
#include <string>
using Microsoft::WRL::ComPtr;
int main(int argc, char** argv) {
    ComPtr<IDXGIFactory1> factory;
    ComPtr<IDXGIAdapter1> adapter;
    ComPtr<IDXGIOutput> output;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))) || FAILED(factory->EnumAdapters1(0,&adapter)) || FAILED(adapter->EnumOutputs(0,&output))) return 1;
    DXGI_OUTPUT_DESC desc{};
    if (FAILED(output->GetDesc(&desc))) return 2;
    DEVMODEW mode{}; mode.dmSize = sizeof(mode);
    if (!EnumDisplaySettingsW(desc.DeviceName,ENUM_CURRENT_SETTINGS,&mode)) return 3;
    std::cout << "current " << mode.dmPelsWidth << 'x' << mode.dmPelsHeight << ' ' << mode.dmDisplayFrequency << "Hz\n";
    if (argc == 2 && std::string(argv[1]) == "--restore-current") {
        if (mode.dmPelsWidth != 3840 || mode.dmPelsHeight != 2160 || mode.dmDisplayFrequency != 60) return 9;
        const auto status = ChangeDisplaySettingsExW(desc.DeviceName, &mode, nullptr, CDS_RESET, nullptr);
        std::cout << "restore_current_status=" << status << "\n";
        return status == DISP_CHANGE_SUCCESSFUL ? 0 : 10;
    }
    if (argc != 1) {
        if (argc != 4 || std::string(argv[1]) != "--set-refresh") return 4;
        const auto hz = std::stoul(argv[2]), expected = std::stoul(argv[3]);
        if (mode.dmPelsWidth != 3840 || mode.dmPelsHeight != 2160 || mode.dmDisplayFrequency != expected || (hz != 60 && hz != 120 && hz != 144 && hz != 160)) return 5;
        const auto original = mode;
        bool found = false;
        for (DWORD i=0; EnumDisplaySettingsW(desc.DeviceName, i, &mode); ++i) {
            if (mode.dmPelsWidth==3840 && mode.dmPelsHeight==2160 && mode.dmBitsPerPel==32 && mode.dmDisplayFrequency==hz) { found=true; break; }
        }
        if (!found) return 6;
        const auto test = ChangeDisplaySettingsExW(desc.DeviceName, &mode, nullptr, CDS_TEST, nullptr);
        std::cout << "test_status=" << test << "\n";
        if (test != DISP_CHANGE_SUCCESSFUL) return 6;
        const auto changed = ChangeDisplaySettingsExW(desc.DeviceName, &mode, nullptr, 0, nullptr);
        std::cout << "change_status=" << changed << "\n";
        if (changed != DISP_CHANGE_SUCCESSFUL) return 7;
        if (!EnumDisplaySettingsW(desc.DeviceName, ENUM_CURRENT_SETTINGS, &mode) || mode.dmDisplayFrequency != hz) {
            auto rollback = original;
            std::cout << "rollback_status=" << ChangeDisplaySettingsExW(desc.DeviceName, &rollback, nullptr, 0, nullptr) << "\n";
            return 8;
        }
        std::cout << "applied " << hz << "Hz (registry unchanged)\n";
        return 0;
    }
    for (DWORD i=0;EnumDisplaySettingsW(desc.DeviceName,i,&mode);++i) {
        if (mode.dmPelsWidth==3840 && mode.dmPelsHeight==2160 && mode.dmBitsPerPel==32) std::cout << "available 3840x2160 " << mode.dmDisplayFrequency << "Hz\n";
    }
}

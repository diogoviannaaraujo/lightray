// Load the experimental Swift DLL from an MSVC executable and exercise the real AEAD path.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include "core_probe_vectors.h"

using OpenPacket = std::int32_t (*)(const std::uint8_t*, std::int32_t, const std::uint8_t*, std::int32_t, std::uint64_t, std::uint8_t*, std::int32_t);

int wmain(int argc, wchar_t** argv) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    if (argc != 2) { std::cerr << "Expected the Swift DLL path\n"; return 2; }
    std::cerr << "Loading Swift DLL\n";
    HMODULE library = LoadLibraryW(argv[1]);
    if (!library) { std::cerr << "DLL loading failed: " << GetLastError() << '\n'; return 1; }
    const auto open = reinterpret_cast<OpenPacket>(GetProcAddress(library, "lightray_probe_open_packet"));
    if (!open) { std::cerr << "C ABI export missing\n"; return 1; }
    std::cerr << "Swift DLL loaded; opening authenticated vector\n";
    std::array<std::uint8_t, 256> output{};
    auto invoke = [&](const std::uint8_t* data, std::int32_t count, std::int32_t keyCount = sizeof(key), std::int32_t capacity = 256) {
        return open(data, count, key, keyCount, packet_number, output.data(), capacity);
    };
    const auto size = invoke(packet, sizeof(packet));
    std::cerr << "Vector returned " << size << " bytes\n";
    bool passed = size == static_cast<std::int32_t>(sizeof(plaintext)) && std::equal(std::begin(plaintext), std::end(plaintext), output.begin());
    std::array<std::uint8_t, sizeof(packet)> corrupt{};
    std::copy(std::begin(packet), std::end(packet), corrupt.begin());
    corrupt.back() ^= 1;
    passed &= invoke(corrupt.data(), static_cast<std::int32_t>(corrupt.size())) == -2;
    passed &= invoke(nullptr, sizeof(packet)) == -1;
    passed &= invoke(packet, 1) == -1;
    passed &= invoke(packet, sizeof(packet), 31) == -1;
    passed &= invoke(packet, sizeof(packet), sizeof(key), 0) == -1;
    std::cout << "{\"status\":\"" << (passed ? "passed" : "failed") << "\",\"cases\":6}\n";
    // Swift metadata/runtime state can outlive an individual call. Keep this module for process lifetime.
    std::cerr << "C ABI checks finished; Swift DLL retained until process exit\n";
    return passed ? 0 : 1;
}

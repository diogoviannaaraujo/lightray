#pragma once
// Laboratory-only IPv4 adapter: always binds 127.0.0.1 and never listens externally.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <array>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string>

namespace lightray {
inline std::runtime_error socket_error(const char* action) {
    return std::runtime_error(std::string(action) + " Winsock " + std::to_string(WSAGetLastError()));
}
class WinsockRuntime {
public:
    WinsockRuntime() {
        WSADATA data{};
        const auto result = WSAStartup(MAKEWORD(2,2), &data);
        if (result) throw std::runtime_error("WSAStartup failed " + std::to_string(result));
    }
    ~WinsockRuntime() { WSACleanup(); }
    WinsockRuntime(const WinsockRuntime&) = delete;
    WinsockRuntime& operator=(const WinsockRuntime&) = delete;
};
class LoopbackSocket {
    SOCKET socket_ = INVALID_SOCKET;
    std::uint16_t port_ = 0;
public:
    explicit LoopbackSocket(std::uint16_t port) {
        socket_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (socket_ == INVALID_SOCKET) throw socket_error("socket");
        try {
            const BOOL exclusive = TRUE;
            if (setsockopt(socket_, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), sizeof(exclusive)) == SOCKET_ERROR) throw socket_error("exclusive bind");
            sockaddr_in address{};
            address.sin_family = AF_INET;
            address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            address.sin_port = htons(port);
            if (bind(socket_, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == SOCKET_ERROR) throw socket_error("bind loopback");
            int size = sizeof(address);
            if (getsockname(socket_, reinterpret_cast<sockaddr*>(&address), &size) == SOCKET_ERROR) throw socket_error("getsockname");
            port_ = ntohs(address.sin_port);
            u_long nonblocking = 1;
            if (ioctlsocket(socket_, FIONBIO, &nonblocking) == SOCKET_ERROR) throw socket_error("nonblocking");
        } catch (...) { closesocket(socket_); socket_ = INVALID_SOCKET; throw; }
    }
    ~LoopbackSocket() { if (socket_ != INVALID_SOCKET) closesocket(socket_); }
    LoopbackSocket(const LoopbackSocket&) = delete;
    LoopbackSocket& operator=(const LoopbackSocket&) = delete;
    std::uint16_t port() const noexcept { return port_; }
    // False means backpressure: caller must retain bytes and retry or explicitly fail.
    bool send(std::span<const std::uint8_t> bytes, std::uint16_t port) {
        if (bytes.empty() || bytes.size() > 1200 || !port) throw std::invalid_argument("Invalid UDP datagram");
        sockaddr_in address{}; address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(port);
        const auto n = sendto(socket_, reinterpret_cast<const char*>(bytes.data()), static_cast<int>(bytes.size()), 0, reinterpret_cast<const sockaddr*>(&address), sizeof(address));
        if (n == SOCKET_ERROR) { if (WSAGetLastError() == WSAEWOULDBLOCK) return false; throw socket_error("sendto"); }
        if (n != static_cast<int>(bytes.size())) throw std::runtime_error("Partial UDP send");
        return true;
    }
    // Zero means no datagram. Zero-length/oversize datagrams are rejected explicitly.
    int receive(std::span<std::uint8_t> bytes, std::uint16_t& port) {
        if (bytes.size() < 1201) throw std::invalid_argument("Receive buffer must detect oversize datagrams");
        sockaddr_in address{}; int address_size = sizeof(address);
        const auto n = recvfrom(socket_, reinterpret_cast<char*>(bytes.data()), 1201, 0, reinterpret_cast<sockaddr*>(&address), &address_size);
        if (n == SOCKET_ERROR) { if (WSAGetLastError() == WSAEWOULDBLOCK) return 0; throw socket_error("recvfrom"); }
        if (n <= 0 || n > 1200 || address_size != sizeof(address) || address.sin_family != AF_INET || address.sin_addr.s_addr != htonl(INADDR_LOOPBACK)) throw std::runtime_error("Invalid loopback datagram");
        port = ntohs(address.sin_port);
        return n;
    }
};
}

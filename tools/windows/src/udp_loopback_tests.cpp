#define NOMINMAX
#include "udp_loopback.hpp"
#include <iostream>
static void check(bool value) { if (!value) throw std::runtime_error("Loopback assertion failed"); }
int main() {
    try {
        lightray::WinsockRuntime runtime;
        std::uint16_t bound = 0;
        {
            lightray::LoopbackSocket receiver(0), sender(0);
            bound=receiver.port();
            std::array<std::uint8_t,1201> buffer{};
            std::uint16_t peer=0;
            check(receiver.receive(buffer,peer)==0);
            bool busy=false;
            try { lightray::LoopbackSocket duplicate(bound); } catch(const std::runtime_error&) { busy=true; }
            check(busy);
            bool oversize=false, empty=false;
            try { sender.send(buffer,bound); } catch(const std::invalid_argument&) { oversize=true; }
            try { sender.send({},bound); } catch(const std::invalid_argument&) { empty=true; }
            check(oversize && empty);
            buffer[0]=42; buffer[1199]=77;
            check(sender.send(std::span(buffer.data(),1200),bound));
            buffer.fill(0);
            int n=0;
            for(unsigned i=0;i<100 && !n;++i) { n=receiver.receive(buffer,peer); if(!n) Sleep(1); }
            check(n==1200 && buffer[0]==42 && buffer[1199]==77 && peer==sender.port());
            check(receiver.receive(buffer,peer)==0);
        }
        lightray::LoopbackSocket rebound(bound);
        check(rebound.port()==bound);
        std::cout << "{\"status\":\"passed\",\"cases\":7,\"loopback_only\":true}\n";
        return 0;
    } catch(const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

#include "capture_recovery.hpp"
#include <iostream>
#include <stdexcept>
using Recovery = lightray::CaptureRecovery;
using Action = Recovery::Action;
static void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
int main() {
    try {
        Recovery startup;
        check(!startup.ready() && startup.action(0) == Action::acquire, "Initial acquisition must not allow cached data");
        check(startup.action(999999) == Action::acquire && startup.action(1000000) == Action::recreate, "No-first-frame watchdog");
        startup.attempted(1000000, true);
        check(!startup.ready() && startup.action(1999999) == Action::acquire, "Recreation alone is not recovery");
        startup.attempted(2000000, true);
        check(startup.action(5000000) == Action::fail, "Recreation must not renew the episode deadline");
        Recovery lost;
        lost.frame(); lost.lost(100);
        check(!lost.ready() && lost.action(100099) == Action::wait && lost.action(100100) == Action::recreate, "Access loss invalidates cache and backs off");
        lost.attempted(100100, false);
        check(lost.action(300099) == Action::wait && lost.action(300100) == Action::recreate, "Failed retry uses longer backoff");
        lost.attempted(300100, true); lost.lost(300200);
        check(lost.attempts() == 2 && lost.action(5000100) == Action::fail, "Repeated access loss keeps the original budget");
        lost.frame();
        check(lost.ready() && lost.action(9000000) == Action::acquire, "Only a frame restores readiness");
        lost.lost(10000000);
        check(lost.attempts() == 0 && lost.action(10100000) == Action::recreate, "Later episode receives a fresh budget");
        Recovery backwards; backwards.action(100);
        check(backwards.action(99) == Action::fail, "Clock regression fails closed");
        Recovery near_limit; near_limit.action(UINT64_MAX - 10);
        check(near_limit.action(UINT64_MAX) == Action::acquire, "Clock arithmetic does not overflow");
        Recovery capped; capped.action(0);
        for (unsigned i = 0; i < 8; ++i) capped.attempted(i, false);
        check(capped.action(9) == Action::fail, "Attempt cap");
        std::cout << "{\"status\":\"passed\",\"cases\":12,\"faults\":\"simulated_clock_and_outcomes\"}\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

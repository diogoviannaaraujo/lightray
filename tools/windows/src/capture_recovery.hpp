#pragma once
#include <algorithm>
#include <cstdint>

namespace lightray {
// One bounded episode includes all recreations until an actual frame arrives.
class CaptureRecovery {
    enum class Phase { cold, ready, waiting, backoff } phase_ = Phase::cold;
    std::uint64_t started_ = 0, attempted_ = 0;
    unsigned attempts_ = 0;
public:
    enum class Action { acquire, wait, recreate, fail };
    static constexpr std::uint64_t budget_us = 5000000, first_frame_us = 1000000;
    bool ready() const { return phase_ == Phase::ready; }
    unsigned attempts() const { return attempts_; }
    Action action(std::uint64_t now) {
        if (phase_ == Phase::ready) return Action::acquire;
        if (phase_ == Phase::cold) { started_ = attempted_ = now; phase_ = Phase::waiting; }
        if (now < started_ || now < attempted_ || now - started_ >= budget_us || attempts_ >= 8) return Action::fail;
        if (phase_ == Phase::waiting) return now - attempted_ >= first_frame_us ? Action::recreate : Action::acquire;
        const auto delay = 100000ULL << std::min(attempts_, 3u);
        return now - attempted_ >= delay ? Action::recreate : Action::wait;
    }
    void lost(std::uint64_t now) {
        if (phase_ == Phase::ready || phase_ == Phase::cold) { started_ = now; attempts_ = 0; }
        attempted_ = now;
        phase_ = Phase::backoff;
    }
    void attempted(std::uint64_t now, bool success) {
        ++attempts_;
        attempted_ = now;
        phase_ = success ? Phase::waiting : Phase::backoff;
    }
    void frame() { phase_ = Phase::ready; }
};
} // namespace lightray

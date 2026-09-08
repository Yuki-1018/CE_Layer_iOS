#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdlib>

// Keeps the Normal interpreter fast without letting an optimistic fixed cycle
// count pull the entire VM below real time. It is guest-version agnostic, so a
// Windows 95 installation upgraded in-place to 98/Me benefits automatically.
class AdaptiveCycleController {
public:
    enum : int {
        kMinimumCycles = 50000,
        kMaximumCycles = 200000,
        kSampleFrames = 120
    };

    AdaptiveCycleController() { reset(120000); }

    void reset(int cycles) {
        cycles_ = std::max<int>(kMinimumCycles, std::min<int>(kMaximumCycles, cycles));
        accumulatedWorkNanoseconds_ = 0;
        sampledFrames_ = 0;
    }

    int cycles() const { return cycles_; }

    // Returns a new cycle count after a complete sample, or zero when the
    // existing count should remain in use. 13 ms leaves headroom in a 16.67 ms
    // frame for Metal, audio, input and user-mode networking.
    int observe(uint64_t workNanoseconds) {
        accumulatedWorkNanoseconds_ += workNanoseconds;
        if (++sampledFrames_ < kSampleFrames) return 0;

        const uint64_t average = accumulatedWorkNanoseconds_ / sampledFrames_;
        accumulatedWorkNanoseconds_ = 0;
        sampledFrames_ = 0;
        constexpr uint64_t target = 13000000;
        constexpr uint64_t lowerDeadband = 11500000;
        constexpr uint64_t upperDeadband = 14500000;
        if (average >= lowerDeadband && average <= upperDeadband) return 0;

        const int64_t proportional = average
            ? static_cast<int64_t>(cycles_) * static_cast<int64_t>(target) / static_cast<int64_t>(average)
            : kMaximumCycles;
        const int lowerStep = cycles_ * 7 / 8;
        const int upperStep = cycles_ * 9 / 8;
        int next = static_cast<int>(std::max<int64_t>(lowerStep, std::min<int64_t>(upperStep, proportional)));
        next = std::max<int>(kMinimumCycles, std::min<int>(kMaximumCycles, next));
        next = ((next + 500) / 1000) * 1000;
        if (std::abs(next - cycles_) < 2000) return 0;
        cycles_ = next;
        return cycles_;
    }

private:
    int cycles_ = 120000;
    uint64_t accumulatedWorkNanoseconds_ = 0;
    size_t sampledFrames_ = 0;
};

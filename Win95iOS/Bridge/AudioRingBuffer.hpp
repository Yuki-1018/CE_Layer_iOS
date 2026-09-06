#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

// Bounded stereo queue shared by the libretro producer and Core Audio render
// thread. It prebuffers after startup/underrun and fades transitions so normal
// scheduling jitter does not become harsh crackle. read() never allocates or
// waits for the emulator thread.
class AudioRingBuffer {
public:
    static constexpr size_t kChannels = 2;

    explicit AudioRingBuffer(size_t capacityFrames = 24000,
                             size_t primeFrames = 2048)
        : samples_(capacityFrames * kChannels),
          capacityFrames_(capacityFrames),
          primeFrames_(std::min(primeFrames, capacityFrames)) {}

    void reset() {
        std::lock_guard<std::mutex> lock(mutex_);
        readFrame_ = 0;
        availableFrames_ = 0;
        primed_ = false;
        fadeInRemaining_ = 0;
        lastLeft_ = 0;
        lastRight_ = 0;
        consumerDiscontinuity_ = false;
    }

    size_t write(const int16_t *data, size_t frames) {
        if (!data || !frames || !capacityFrames_) return frames;
        std::lock_guard<std::mutex> lock(mutex_);

        // If a whole ring was missed, retain only the newest audio and restart
        // from a safe prebuffered boundary.
        if (frames >= capacityFrames_) {
            data += (frames - capacityFrames_) * kChannels;
            frames = capacityFrames_;
            readFrame_ = 0;
            availableFrames_ = 0;
            primed_ = false;
        }

        const size_t freeFrames = capacityFrames_ - availableFrames_;
        const size_t overflow = frames > freeFrames ? frames - freeFrames : 0;
        if (overflow) {
            readFrame_ = (readFrame_ + overflow) % capacityFrames_;
            availableFrames_ -= overflow;
            primed_ = false;
        }

        const size_t writeFrame = (readFrame_ + availableFrames_) % capacityFrames_;
        const size_t firstFrames = std::min(frames, capacityFrames_ - writeFrame);
        std::memcpy(samples_.data() + writeFrame * kChannels,
                    data,
                    firstFrames * kChannels * sizeof(int16_t));
        if (firstFrames < frames) {
            std::memcpy(samples_.data(),
                        data + firstFrames * kChannels,
                        (frames - firstFrames) * kChannels * sizeof(int16_t));
        }
        availableFrames_ += frames;
        return frames;
    }

    size_t read(int16_t *output, size_t frames) {
        if (!output || !frames) return 0;
        std::memset(output, 0, frames * kChannels * sizeof(int16_t));

        std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
        if (!lock.owns_lock()) {
            // Never wait on the real-time render thread. Smooth this rare
            // producer collision and re-prime on the following callback.
            const int32_t left = lastLeft_.exchange(0);
            const int32_t right = lastRight_.exchange(0);
            const size_t fadeFrames = std::min(frames, fadeFrameCount());
            for (size_t i = 0; i < fadeFrames; ++i) {
                const int scale = static_cast<int>(fadeFrames - i - 1);
                output[i * kChannels] = static_cast<int16_t>(left * scale / static_cast<int>(fadeFrames));
                output[i * kChannels + 1] = static_cast<int16_t>(right * scale / static_cast<int>(fadeFrames));
            }
            consumerDiscontinuity_ = true;
            return fadeFrames;
        }
        if (!capacityFrames_) return 0;
        if (consumerDiscontinuity_.exchange(false)) {
            primed_ = false;
            fadeInRemaining_ = 0;
        }

        if (!primed_) {
            if (availableFrames_ < std::max(frames, primeFrames_)) return 0;
            primed_ = true;
            fadeInRemaining_ = fadeFrameCount();
        }

        if (availableFrames_ < frames) {
            // Keep a short producer tail for the next complete block and ramp
            // the previous sample to zero instead of emitting a hard edge.
            const size_t fadeFrames = std::min(frames, fadeFrameCount());
            for (size_t i = 0; i < fadeFrames; ++i) {
                const int scale = static_cast<int>(fadeFrames - i - 1);
                output[i * kChannels] = static_cast<int16_t>(lastLeft_.load() * scale / static_cast<int>(fadeFrames));
                output[i * kChannels + 1] = static_cast<int16_t>(lastRight_.load() * scale / static_cast<int>(fadeFrames));
            }
            primed_ = false;
            fadeInRemaining_ = 0;
            lastLeft_ = 0;
            lastRight_ = 0;
            return fadeFrames;
        }

        const size_t firstFrames = std::min(frames, capacityFrames_ - readFrame_);
        std::memcpy(output,
                    samples_.data() + readFrame_ * kChannels,
                    firstFrames * kChannels * sizeof(int16_t));
        if (firstFrames < frames) {
            std::memcpy(output + firstFrames * kChannels,
                        samples_.data(),
                        (frames - firstFrames) * kChannels * sizeof(int16_t));
        }
        readFrame_ = (readFrame_ + frames) % capacityFrames_;
        availableFrames_ -= frames;

        const size_t fadeFrames = std::min(frames, fadeInRemaining_);
        for (size_t i = 0; i < fadeFrames; ++i) {
            const size_t completed = fadeFrameCount() - fadeInRemaining_ + i + 1;
            output[i * kChannels] = static_cast<int16_t>(
                static_cast<int32_t>(output[i * kChannels]) * static_cast<int32_t>(completed) /
                static_cast<int32_t>(fadeFrameCount()));
            output[i * kChannels + 1] = static_cast<int16_t>(
                static_cast<int32_t>(output[i * kChannels + 1]) * static_cast<int32_t>(completed) /
                static_cast<int32_t>(fadeFrameCount()));
        }
        fadeInRemaining_ -= fadeFrames;
        lastLeft_ = output[(frames - 1) * kChannels];
        lastRight_ = output[(frames - 1) * kChannels + 1];
        return frames;
    }

    size_t availableFrames() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return availableFrames_;
    }

private:
    static size_t fadeFrameCount() { return 128; }

    mutable std::mutex mutex_;
    std::vector<int16_t> samples_;
    const size_t capacityFrames_;
    const size_t primeFrames_;
    size_t readFrame_ = 0;
    size_t availableFrames_ = 0;
    bool primed_ = false;
    size_t fadeInRemaining_ = 0;
    std::atomic<int32_t> lastLeft_{0};
    std::atomic<int32_t> lastRight_{0};
    std::atomic<bool> consumerDiscontinuity_{false};
};

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>

namespace metalcadence {

// Fixed-size sliding telemetry. record() never allocates, locks or sorts.
// Callers synchronize access with their existing scheduler lock; metrics()
// copies these small windows and calculates percentiles outside that lock.
template <std::size_t Capacity = 600> class FixedTimingWindow {
  public:
    static_assert(Capacity > 0);

    void record(double sample) noexcept {
        if (!std::isfinite(sample)) {
            return;
        }
        values_[writeIndex_] = sample;
        writeIndex_ = (writeIndex_ + 1) % Capacity;
        sampleCount_ = std::min(Capacity, sampleCount_ + 1);
    }

    double percentile(double fraction) const {
        if (sampleCount_ == 0) {
            return 0;
        }
        std::array<double, Capacity> copy = values_;
        const double clamped = std::clamp(fraction, 0.0, 1.0);
        const auto selected = static_cast<std::size_t>((sampleCount_ - 1) * clamped);
        std::nth_element(copy.begin(), copy.begin() + selected, copy.begin() + sampleCount_);
        return copy[selected];
    }

    std::size_t size() const noexcept {
        return sampleCount_;
    }

  private:
    std::array<double, Capacity> values_{};
    std::size_t sampleCount_ = 0;
    std::size_t writeIndex_ = 0;
};

} // namespace metalcadence

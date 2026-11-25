#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>

namespace metalcadence {

enum class DeadlineMode : std::uint8_t {
    Smooth,
    Interactive,
};

// The pts array is sorted in nondecreasing order. Renderable frames must
// already be GPU ready: this selection only decides which of them meets the
// upcoming display timestamp. The renderer owns every frame removed from
// its bounded queue until GPU presentation completes.
struct DueDecision {
    std::ptrdiff_t index = -1;
    std::size_t olderDueFrames = 0;
};

// Smooth mode preserves the oldest eligible intermediate frame, subject to
// a refresh-relative lateness tolerance. Interactive mode presents the
// freshest eligible frame to avoid displaying stale backlogged input.
// Both modes return -1 if no frame is ready for the upcoming deadline.
inline DueDecision selectDue(const double *pts,
                             std::size_t count,
                             double displayDeadline,
                             double lateTolerance,
                             DeadlineMode mode) {
    if (!pts || count == 0 || !std::isfinite(displayDeadline)) {
        return {};
    }

    std::ptrdiff_t lastDue = -1;
    std::ptrdiff_t earliestOnTime = -1;
    for (std::size_t i = 0; i < count; ++i) {
        if (!std::isfinite(pts[i])) {
            continue;
        }
        if (pts[i] > displayDeadline + .001) {
            break;
        }

        lastDue = static_cast<std::ptrdiff_t>(i);
        if (earliestOnTime < 0 && displayDeadline - pts[i] <= lateTolerance) {
            earliestOnTime = lastDue;
        }
    }

    if (lastDue < 0) {
        return {};
    }

    // Normal 165Hz display jitter can make two 60fps frames due together.
    // Skipping the older of those frames reduces fresh FPS without reducing
    // end-to-end input latency. Catch up only after a real 3+ frame backlog.
    if (mode == DeadlineMode::Interactive && lastDue >= 2) {
        return {lastDue, static_cast<std::size_t>(lastDue)};
    }

    const std::ptrdiff_t chosen = earliestOnTime >= 0 ? earliestOnTime : lastDue;
    return {chosen, static_cast<std::size_t>(chosen)};
}

} // namespace metalcadence

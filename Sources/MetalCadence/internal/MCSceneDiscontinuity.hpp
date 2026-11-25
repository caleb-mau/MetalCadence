#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdlib>

namespace metalcadence {

struct SceneDiscontinuity {
    bool abrupt = false;
    double changedFraction = 0;
    double brighterFraction = 0;
    double darkerFraction = 0;
};

// Conservative sampling of a pair of 8-bit luma planes. An abrupt localized
// teleport changes substantial bright and dark areas simultaneously. This
// deliberately does not classify a small moving cursor as a scene change.
// Sudden full-screen transitions are guarded separately. Not optical flow.
inline SceneDiscontinuity classifyDiscontinuity(const std::uint8_t *a,
                                                const std::uint8_t *b,
                                                std::size_t width,
                                                std::size_t height,
                                                std::size_t strideA,
                                                std::size_t strideB) {
    if (!a || !b || !width || !height || strideA < width || strideB < width)
        return {};
    constexpr std::size_t step = 16;
    std::size_t bright = 0, dark = 0, total = 0;
    for (std::size_t y = 8; y < height; y += step) {
        for (std::size_t x = 8; x < width; x += step) {
            const int delta =
                static_cast<int>(b[y * strideB + x]) - static_cast<int>(a[y * strideA + x]);
            bright += delta >= 42;
            dark += delta <= -42;
            total++;
        }
    }
    if (!total)
        return {};
    const double increasing = static_cast<double>(bright) / total;
    const double decreasing = static_cast<double>(dark) / total;
    const double changed = increasing + decreasing;
    const bool objectJump = changed >= .065 && increasing >= .023 && decreasing >= .023;
    const bool hardCut = changed >= .65;
    return {objectJump || hardCut, changed, increasing, decreasing};
}

} // namespace metalcadence

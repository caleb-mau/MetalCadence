#include "internal/MCSceneDiscontinuity.hpp"
#include <cassert>
#include <cstdio>
#include <vector>

constexpr int width = 1280, height = 720;
static void
rectangle(std::vector<std::uint8_t> &frame, int x, int y, int w, int h, std::uint8_t value) {
    for (int j = y; j < y + h; ++j)
        for (int i = x; i < x + w; ++i)
            frame[j * width + i] = value;
}
static metalcadence::SceneDiscontinuity compare(const std::vector<std::uint8_t> &a,
                                                const std::vector<std::uint8_t> &b) {
    return metalcadence::classifyDiscontinuity(a.data(), b.data(), width, height, width, width);
}
int main() {
    std::vector<std::uint8_t> a(width * height, 32), b(width * height, 32);
    assert(!compare(a, b).abrupt);
    // Ordinary single-pixel bar motion must retain interpolation.
    rectangle(a, 240, 75, 13, 570, 214);
    rectangle(b, 266, 75, 13, 570, 214);
    assert(!compare(a, b).abrupt);
    a.assign(width * height, 32);
    b.assign(width * height, 32);
    rectangle(a, 214, 254, 192, 192, 208);
    rectangle(b, 874, 254, 192, 192, 208);
    auto jump = compare(a, b);
    assert(jump.abrupt && jump.changedFraction > .065 && jump.changedFraction < .1);
    b = a;
    assert(!compare(a, b).abrupt);
    // Normal 25-pixel square motion changes much less surface area.
    b.assign(width * height, 32);
    rectangle(b, 239, 254, 192, 192, 208);
    assert(!compare(a, b).abrupt);
    b.assign(width * height, 220);
    assert(compare(a, b).abrupt); // large full-frame cut
    b.assign(width * height, 42);
    a.assign(width * height, 32);
    assert(!compare(a, b).abrupt);
    assert(!metalcadence::classifyDiscontinuity(nullptr, b.data(), width, height, width, width)
                .abrupt);
    std::puts("Scene guard classification: teleport, cursor, small motion and cut passed");
}

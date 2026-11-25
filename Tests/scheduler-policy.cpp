#include "internal/MCDeadlineSelection.hpp"
#include <array>
#include <cassert>
#include <cstdio>
#include <limits>

int main() {
    using namespace metalcadence;
    const std::array<double, 4> pts{1.0, 1.0166667, 1.0333333, 1.05};
    auto at = [&](std::size_t i) {
        return pts[i];
    };
    assert(overdueCount(at, pts.size(), .99) == 0);
    assert(overdueCount(at, pts.size(), 1.0) == 1);
    assert(overdueCount(at, pts.size(), 1.02) == 2);
    assert(overdueCount(at, pts.size(), 1.10) == 4);
    assert(overdueCount(at, 0, 1.10) == 0);
    assert(overdueCount(at, pts.size(), std::numeric_limits<double>::quiet_NaN()) == 0);
    // Getter-based and public pointer-based policies must agree for the same timeline.
    for (int tick = 0; tick < 240; ++tick) {
        double target = .95 + tick / 240.0;
        for (auto mode : {DeadlineMode::Smooth, DeadlineMode::Interactive}) {
            auto a = selectDueBy(at, pts.size(), target, .025, mode);
            auto b = selectDue(pts.data(), pts.size(), target, .025, mode);
            assert(a.index == b.index && a.olderDueFrames == b.olderDueFrames);
        }
    }
    assert(selectDueBy(at, pts.size(), 1.018, .025, DeadlineMode::Interactive).index == 0);
    assert(selectDueBy(at, pts.size(), 1.04, .025, DeadlineMode::Interactive).index == 2);
    const double overduePair[] = {1.0, 1.0166667};
    assert(selectDue(overduePair, 2, 1.06, .025, DeadlineMode::Smooth).index == 0);
    assert(selectDue(overduePair, 2, 1.06, .025, DeadlineMode::Interactive).index == 1);
    assert(selectDue(overduePair, 2, 1.16, .025, DeadlineMode::Smooth).index == 1);
    assert(selectDue(nullptr, 4, 1.04, .025, DeadlineMode::Smooth).index == -1);
    std::puts("Scheduler policy: overdue and selection checks passed");
}

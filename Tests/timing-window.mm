#include "internal/MCFixedTimingWindow.hpp"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <limits>

int main() {
    metalcadence::FixedTimingWindow<10> window;
    assert(window.size() == 0 && window.percentile(.99) == 0);
    for (int i = 0; i < 10; ++i) {
        window.record(i);
    }
    assert(window.size() == 10);
    assert(window.percentile(0.0) == 0);
    assert(window.percentile(.50) == 4);
    assert(window.percentile(.95) == 8);
    assert(window.percentile(1.0) == 9);
    for (int i = 10; i < 20; ++i) {
        window.record(i);
    }
    assert(window.size() == 10);
    assert(window.percentile(.50) == 14);
    assert(window.percentile(.95) == 18);
    assert(window.percentile(1.0) == 19);
    window.record(std::numeric_limits<double>::quiet_NaN());
    assert(window.size() == 10);
    assert(window.percentile(1.0) == 19);
    std::puts("Presentation telemetry: fixed C++20 timing window passed");
    return 0;
}

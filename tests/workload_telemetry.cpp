#include "../src/workloads/telemetry.hpp"
#include <cassert>
#include <cstdio>
#include <sstream>

int main() {
    std::vector<telemetry::Sample> samples;
    // Reverse service order proves percentile calculation sorts the observations.
    for (uint64_t i = 0; i < 100; ++i)
        samples.push_back({(i + 1) * 1000, (100 - i) * 1000, i * 1000, true});
    const auto stats = telemetry::summarize(samples, 0, 100, 0, 1000000000);
    assert(stats.completed == 100 && stats.failures == 0);
    assert(stats.p50_ns == 50000 && stats.p95_ns == 95000 && stats.p99_ns == 99000);
    assert(stats.max_ns == 100000 && stats.late_p99_ns == 98000);
    assert(stats.throughput == 100 && stats.elapsed_seconds == 1);
    samples.push_back({100001, 9999999, 9999999, false});
    samples.back().memory.allocation_calls = 1;
    samples.back().memory.allocation_failures = 1;
    const auto failed = telemetry::summarize(samples, 100, 101, 100000, 100001);
    assert(failed.attempted == 1 && failed.completed == 0 && failed.failures == 1);
    assert(failed.p99_ns == 0 && failed.throughput == 0);
    const auto mixed = telemetry::summarize(samples, 0, 101, 0, 1000000000);
    assert(mixed.p99_ns == 99000 && mixed.failures == 1);
    const auto empty = telemetry::summarize(samples, 0, 0, 0, 0);
    assert(empty.attempted == 0 && empty.throughput == 0);
    std::ostringstream out;
    telemetry::csv_header(out);
    telemetry::csv_row(out, "failure-test", "summary", "allocation_failed", "steady", 42,
        1, 64, 65536, 0, 100, 0, 0, 1, failed, 32, 0, 0);
    std::fputs(out.str().c_str(), stdout);
    std::puts("TELEMETRY_UNIT_PASS");
}

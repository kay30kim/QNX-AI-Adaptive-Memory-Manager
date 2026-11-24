#ifndef QNX_WORKLOAD_TELEMETRY_HPP
#define QNX_WORKLOAD_TELEMETRY_HPP

#include <algorithm>
#include <cstdint>
#include <iomanip>
#include <locale>
#include <ostream>
#include <vector>
#include "buffer_pool.hpp"

namespace telemetry {
// Only workload payload allocations are counted, not libc/measurement storage.
struct Sample {
    uint64_t end_ns, service_ns, lateness_ns;
    bool success;
    runtime::BufferStats memory;
    uint64_t peak_live, peak_owned;
    Sample(uint64_t end, uint64_t service, uint64_t lateness, bool ok,
           const runtime::BufferStats& counters = runtime::BufferStats(), uint64_t live = 0, uint64_t owned = 0)
        : end_ns(end), service_ns(service), lateness_ns(lateness), success(ok), memory(counters), peak_live(live), peak_owned(owned) {}
};
struct Stats {
    uint64_t attempted = 0, completed = 0, failures = 0;
    uint64_t p50_ns = 0, p95_ns = 0, p99_ns = 0, max_ns = 0, late_p99_ns = 0;
    double elapsed_seconds = 0, throughput = 0;
    runtime::BufferStats memory;
    uint64_t peak_live = 0, peak_owned = 0;
};

// Nearest-rank percentile. Input must already be sorted.
inline uint64_t percentile(const std::vector<uint64_t>& values, unsigned percent) {
    return values.empty() ? 0 : values[(values.size() * percent + 99) / 100 - 1];
}

inline Stats summarize(const std::vector<Sample>& samples, size_t begin, size_t end,
                       uint64_t start_ns, uint64_t end_ns) {
    Stats stats;
    std::vector<uint64_t> service, late;
    service.reserve(end - begin);
    late.reserve(end - begin);
    stats.attempted = end - begin;
    for (size_t i = begin; i < end; ++i) {
        stats.peak_live = std::max(stats.peak_live, samples[i].peak_live);
        stats.peak_owned = std::max(stats.peak_owned, samples[i].peak_owned);
        if (samples[i].success) {
            ++stats.completed;
            service.push_back(samples[i].service_ns);
            late.push_back(samples[i].lateness_ns);
        } else ++stats.failures;
    }
    if (end > begin) {
        const auto before = begin ? samples[begin - 1].memory : runtime::BufferStats();
        stats.memory = samples[end - 1].memory;
        stats.memory.allocation_calls -= before.allocation_calls;
        stats.memory.allocations -= before.allocations;
        stats.memory.frees -= before.frees;
        stats.memory.allocation_failures -= before.allocation_failures;
        stats.memory.allocated_bytes -= before.allocated_bytes;
        stats.memory.pool_hits -= before.pool_hits;
        stats.memory.pool_misses -= before.pool_misses;
        stats.memory.pool_exhaustions -= before.pool_exhaustions;
        stats.memory.invalid_releases -= before.invalid_releases;
        stats.memory.cache_hits -= before.cache_hits;
        stats.memory.cache_misses -= before.cache_misses;
        stats.memory.cache_evictions -= before.cache_evictions;
        stats.memory.cache_bypasses -= before.cache_bypasses;
    }
    std::sort(service.begin(), service.end());
    std::sort(late.begin(), late.end());
    stats.p50_ns = percentile(service, 50);
    stats.p95_ns = percentile(service, 95);
    stats.p99_ns = percentile(service, 99);
    stats.max_ns = service.empty() ? 0 : service.back();
    stats.late_p99_ns = percentile(late, 99);
    stats.elapsed_seconds = static_cast<double>(end_ns - start_ns) / 1e9;
    stats.throughput = stats.elapsed_seconds > 0 ? stats.completed / stats.elapsed_seconds : 0;
    return stats;
}

inline void csv_header(std::ostream& out) {
    out << "schema_version,run_id,row_type,status,mode,pattern,seed,configured_requests,keys,block_bytes,interval_ms,"
           "sample_every,window_index,start_ns,end_ns,attempted,completed,allocation_calls,allocations,frees,"
           "allocation_failures,allocated_bytes,live_buffer_bytes,peak_live_buffer_bytes,retained_buffer_bytes,"
           "measurement_storage_bytes,elapsed_seconds,throughput_rps,latency_p50_us,latency_p95_us,latency_p99_us,"
           "latency_max_us,start_lateness_p99_us,cache_hits,cache_misses,sequence_hash,result_checksum,"
           "pool_blocks,pool_capacity_bytes,pool_hits,pool_misses,pool_exhaustions,invalid_releases,"
           "request_failures,peak_owned_buffer_bytes,pool_metadata_bytes,cleanup_frees,post_cleanup_owned_bytes,"
           "cache_capacity_bytes,cache_effective_capacity_bytes,cache_bytes,cache_entries,cache_evictions,cache_bypasses,cache_metadata_bytes\n";
}

inline void csv_row(std::ostream& out, const char* run_id, const char* row_type, const char* status,
                    const char* pattern, uint32_t seed, uint32_t requested, uint32_t keys,
                    uint32_t bytes, uint32_t interval, uint32_t sample_every, size_t window,
                    uint64_t start_ns, uint64_t end_ns, const Stats& stats, size_t storage,
                    uint64_t sequence_hash, uint64_t checksum, const char* mode = "baseline",
                    uint32_t pool_blocks = 0, size_t pool_metadata = 0, uint64_t cleanup_frees = 0,
                    uint64_t post_cleanup_owned = 0, uint64_t cache_capacity = 0,
                    uint64_t cache_effective = 0, size_t cache_metadata = 0) {
    out.imbue(std::locale::classic());
    out << std::fixed << std::setprecision(9)
        << "3," << run_id << ',' << row_type << ',' << status << ',' << mode << ',' << pattern << ','
        << seed << ',' << requested << ',' << keys << ',' << bytes << ',' << interval << ','
        << sample_every << ',' << window << ',' << start_ns << ',' << end_ns << ','
        << stats.attempted << ',' << stats.completed << ',' << stats.memory.allocation_calls << ','
        << stats.memory.allocations << ',' << stats.memory.frees << ',' << stats.memory.allocation_failures << ','
        << stats.memory.allocated_bytes << ',' << stats.memory.live_bytes << ',' << stats.peak_live << ',' << stats.memory.retained_bytes << ','
        << storage << ',' << stats.elapsed_seconds << ',' << stats.throughput << ',';
    // No successful samples means unavailable latency, not a measured zero.
    if (stats.completed) {
        out << stats.p50_ns / 1000.0 << ',' << stats.p95_ns / 1000.0 << ','
            << stats.p99_ns / 1000.0 << ',' << stats.max_ns / 1000.0 << ',' << stats.late_p99_ns / 1000.0;
    } else out << ",,,,";
    out << ',';
    if (std::string(mode) == "cache") out << stats.memory.cache_hits << ',' << stats.memory.cache_misses;
    else out << ',';
    out << ',';
    if (std::string(row_type) == "summary")
        out << std::hex << sequence_hash << std::dec << ',' << checksum;
    else out << ',';
    out << ',' << pool_blocks << ',' << static_cast<uint64_t>(pool_blocks) * bytes << ','
        << stats.memory.pool_hits << ',' << stats.memory.pool_misses << ',' << stats.memory.pool_exhaustions << ','
        << stats.memory.invalid_releases << ',' << stats.failures << ',' << stats.peak_owned << ',' << pool_metadata << ',';
    if (std::string(row_type) == "summary") out << cleanup_frees << ',' << post_cleanup_owned;
    else out << ',';
    out << ',' << cache_capacity << ',' << cache_effective << ',' << stats.memory.cache_bytes << ','
        << stats.memory.cache_entries << ',' << stats.memory.cache_evictions << ',' << stats.memory.cache_bypasses << ',' << cache_metadata << '\n';
}
}
#endif

// Sprint 3, Step 1: reproducible requests and an allocate/fill/free baseline.
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <thread>

struct Options {
    const char* pattern = "steady";
    uint32_t seed = 42, requests = 1000, keys = 64, bytes = 65536, interval_ms = 10;
    bool trace = false, trace_only = false;
};

static void usage() {
    std::puts("Usage: memory_workload [options]\n"
        "  --pattern steady|burst|ramp  (default steady)\n"
        "  --seed N                    (0..4294967295; default 42)\n"
        "  --requests N                (1..1000000; default 1000)\n"
        "  --keys N                    (1..1000000; default 64)\n"
        "  --bytes N                   (1..16777216; default 65536)\n"
        "  --interval-ms N             (0..1000; default 10; 0 = unpaced)\n"
        "  --trace                     (request CSV on stdout, summary on stderr)\n"
        "  --trace-only                (CSV only; no allocation/sleep)\n"
        "  --help\n"
        "Patterns change scheduled spacing, not buffer size.\n"
        "Same options reproduce requests, not measured timing or OS memory.");
}

static bool number(const char* text, uint32_t low, uint32_t high, uint32_t& out) {
    if (!*text) return false;
    uint64_t value = 0;
    for (const char* p = text; *p; ++p) {
        if (*p < '0' || *p > '9') return false;
        value = value * 10 + static_cast<unsigned>(*p - '0');
        if (value > high) return false;
    }
    if (value < low) return false;
    out = static_cast<uint32_t>(value);
    return true;
}

// Defined byte order makes this fingerprint independent of host endianness.
static uint64_t hash_value(uint64_t hash, uint64_t value) {
    for (unsigned i = 0; i < 8; ++i) {
        hash ^= (value >> (8 * i)) & 255;
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

int main(int argc, char** argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        const char* arg = argv[i];
        if (!std::strcmp(arg, "--help")) { usage(); return 0; }
        if (!std::strcmp(arg, "--trace")) { o.trace = true; continue; }
        if (!std::strcmp(arg, "--trace-only")) { o.trace = o.trace_only = true; continue; }
        if (i + 1 >= argc) { std::fprintf(stderr, "Missing value: %s\n", arg); return 2; }
        const char* value = argv[++i];
        bool valid = false;
        if (!std::strcmp(arg, "--pattern")) {
            valid = !std::strcmp(value, "steady") || !std::strcmp(value, "burst") || !std::strcmp(value, "ramp");
            o.pattern = value;
        } else if (!std::strcmp(arg, "--seed")) valid = number(value, 0, UINT32_MAX, o.seed);
        else if (!std::strcmp(arg, "--requests")) valid = number(value, 1, 1000000, o.requests);
        else if (!std::strcmp(arg, "--keys")) valid = number(value, 1, 1000000, o.keys);
        else if (!std::strcmp(arg, "--bytes")) valid = number(value, 1, 16777216, o.bytes);
        else if (!std::strcmp(arg, "--interval-ms")) valid = number(value, 0, 1000, o.interval_ms);
        if (!valid) { std::fprintf(stderr, "Invalid option/value: %s %s (see --help)\n", arg, value); return 2; }
    }
    // mt19937 plus explicit modulo mapping is stable across standard libraries.
    std::mt19937 rng(o.seed);
    uint64_t scheduled_us = 0, sequence_hash = UINT64_C(14695981039346656037);
    uint64_t result_checksum = 0, completed = 0;
    const uint32_t hot_keys = o.keys / 4 ? o.keys / 4 : 1;
    const auto start = std::chrono::steady_clock::now();
    if (o.trace) std::puts("request_index,key,bytes,scheduled_us");
    for (uint32_t i = 0; i < o.requests; ++i) {
        // 80% target the first quarter of keys, providing reuse for future caches.
        const bool hot = rng() % 100 < 80;
        const uint32_t key = rng() % (hot ? hot_keys : o.keys);
        sequence_hash = hash_value(sequence_hash, key);
        sequence_hash = hash_value(sequence_hash, o.bytes);
        sequence_hash = hash_value(sequence_hash, scheduled_us);
        if (!o.trace_only) {
            std::this_thread::sleep_until(start + std::chrono::microseconds(scheduled_us));
            volatile unsigned char* block = static_cast<unsigned char*>(std::malloc(o.bytes));
            if (!block) {
                std::fprintf(stderr, "Allocation failed: request=%u bytes=%u completed=%llu\n",
                    i, o.bytes, static_cast<unsigned long long>(completed));
                return 1;
            }
            // Results depend only on key/size; caching can preserve the same result.
            uint64_t sum = 0;
            for (uint32_t j = 0; j < o.bytes; ++j) {
                block[j] = static_cast<unsigned char>((key + j) & 255);
                sum += block[j];
            }
            result_checksum += sum;
            std::free(const_cast<unsigned char*>(block));
            ++completed;
        }
        if (o.trace) std::printf("%u,%u,%u,%llu\n", i, key, o.bytes,
            static_cast<unsigned long long>(scheduled_us));
        uint64_t gap_us = static_cast<uint64_t>(o.interval_ms) * 1000;
        if (!std::strcmp(o.pattern, "burst")) gap_us = i % 100 < 20 ? gap_us / 10 : gap_us * 2;
        else if (!std::strcmp(o.pattern, "ramp")) {
            const uint64_t phase = static_cast<uint64_t>(i) * 10 / o.requests;
            gap_us = gap_us * (10 - phase) / 10;
        }
        scheduled_us += gap_us;
    }
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    FILE* report = o.trace ? stderr : stdout;
    std::fprintf(report, "mode=%s pattern=%s seed=%u requests=%u keys=%u bytes=%u interval_ms=%u\n",
        o.trace_only ? "trace-only" : "baseline", o.pattern, o.seed, o.requests, o.keys, o.bytes, o.interval_ms);
    std::fprintf(report, "sequence_hash=%016llx completed=%llu allocations=%llu result_checksum=%llu\n",
        static_cast<unsigned long long>(sequence_hash), static_cast<unsigned long long>(completed),
        static_cast<unsigned long long>(completed), static_cast<unsigned long long>(result_checksum));
    if (!o.trace_only) std::fprintf(report, "elapsed_seconds=%.6f (includes pacing%s)\n", elapsed,
        o.trace ? " and trace output" : "");
    if (o.trace && (std::fflush(stdout) != 0 || std::ferror(stdout))) {
        std::fprintf(stderr, "Cannot write request CSV.\n"); return 1;
    }
    return 0;
}

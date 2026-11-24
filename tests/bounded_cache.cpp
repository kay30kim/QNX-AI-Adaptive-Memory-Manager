#include "../src/workloads/bounded_cache.hpp"
#include <cstdio>
#include <set>
#define CHECK(condition) do { if (!(condition)) { std::printf("FAIL line %d: %s\n", __LINE__, #condition); std::fflush(stdout); std::abort(); } } while (false)

static std::set<void*> outstanding;
static bool fail_next = false;
static unsigned computations = 0;
static void* allocate(size_t bytes) {
    if (fail_next) { fail_next = false; return nullptr; }
    void* p = std::malloc(bytes);
    CHECK(p && outstanding.insert(p).second);
    return p;
}
static void deallocate(void* p) { CHECK(outstanding.erase(p) == 1); std::free(p); }
static uint64_t compute(uint32_t key, unsigned char* block, size_t bytes) {
    ++computations;
    uint64_t result = 0;
    for (size_t i = 0; i < bytes; ++i) { block[i] = (key + i) & 255; result += block[i]; }
    return result;
}
int main() {
    uint64_t a = 0, result = 0;
    runtime::BoundedCache invalid(0, 2, 64);
    CHECK(!invalid.valid() && !invalid.get_or_compute(1, result, compute));
    {
        runtime::BoundedCache cache(32, 8, 65, allocate, deallocate);
        CHECK(cache.valid() && cache.effective_capacity_bytes() == 64);
        CHECK(cache.get_or_compute(1, a, compute));
        CHECK(cache.get_or_compute(2, result, compute));
        CHECK(cache.get_or_compute(1, result, compute) && result == a);
        CHECK(computations == 2); // a hit must not invoke computation
        CHECK(cache.get_or_compute(3, result, compute)); // evicts key 2, not key 1
        CHECK(cache.get_or_compute(1, result, compute) && result == a);
        CHECK(computations == 3);
        CHECK(cache.get_or_compute(2, result, compute)); // miss, evicts key 3
        const auto s = cache.stats();
        CHECK(s.cache_hits == 2 && s.cache_misses == 4 && s.cache_evictions == 2);
        CHECK(s.allocations == 2 && s.pool_hits == 2 && s.invalid_releases == 0);
        CHECK(s.cache_bytes == 64 && s.live_bytes == 64 && s.retained_bytes == 0);
        CHECK(outstanding.size() == 2);
        cache.clear();
        CHECK(outstanding.empty() && cache.stats().frees == 2 && cache.stats().cache_entries == 0);
        cache.clear();
        CHECK(cache.stats().frees == 2);
        CHECK(cache.get_or_compute(1, result, compute) && result == a);
    }
    CHECK(outstanding.empty());
    {
        runtime::BoundedCache cache(32, 1, 1024, allocate, deallocate);
        CHECK(cache.effective_capacity_bytes() == 32);
        for (uint32_t key = 0; key < 100; ++key) {
            CHECK(cache.get_or_compute(key, result, compute));
            CHECK(cache.stats().cache_bytes <= 32 && outstanding.size() == 1);
        }
        CHECK(cache.stats().cache_evictions == 99 && cache.stats().pool_exhaustions == 0);
        CHECK(cache.stats().allocations == 1 && cache.stats().pool_hits == 99);
    }
    CHECK(outstanding.empty());
    for (size_t limit : {size_t(0), size_t(31)}) {
        runtime::BoundedCache cache(32, 1, limit, allocate, deallocate);
        CHECK(cache.valid() && cache.effective_capacity_bytes() == 0);
        CHECK(cache.get_or_compute(1, result, compute) && result == a);
        CHECK(cache.get_or_compute(1, result, compute) && result == a);
        CHECK(cache.stats().cache_bypasses == 2 && cache.stats().cache_hits == 0);
        CHECK(cache.stats().cache_bytes == 0 && cache.stats().retained_bytes == 32);
    }
    CHECK(outstanding.empty());
    {
        runtime::BoundedCache cache(32, 2, 64, allocate, deallocate);
        CHECK(cache.get_or_compute(1, result, compute));
        fail_next = true;
        CHECK(!cache.get_or_compute(2, result, compute));
        CHECK(cache.stats().allocation_failures == 1 && cache.stats().cache_entries == 1);
        CHECK(cache.get_or_compute(1, result, compute) && result == a);
        CHECK(cache.get_or_compute(2, result, compute));
        CHECK(cache.stats().cache_entries == 2 && cache.stats().invalid_releases == 0);
    }
    CHECK(outstanding.empty());
    std::puts("BOUNDED_CACHE_UNIT_PASS");
}

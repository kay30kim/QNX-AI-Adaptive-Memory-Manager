#include "../src/workloads/bounded_cache.hpp"
#include <cstdio>
#include <set>
#include <vector>
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
    CHECK(!invalid.set_capacity(64));
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
    {
        runtime::BoundedCache cache(32, 4, 0, allocate, deallocate);
        CHECK(cache.set_capacity(128));
        for (uint32_t key = 1; key <= 4; ++key) CHECK(cache.get_or_compute(key, result, compute));
        CHECK(cache.get_or_compute(1, a, compute)); // MRU order: 1,4,3,2
        CHECK(cache.set_capacity(65));
        CHECK(cache.effective_capacity_bytes() == 64 && outstanding.size() == 2);
        CHECK(cache.stats().cache_evictions == 2 && cache.stats().frees == 2);
        CHECK(cache.stats().live_bytes == 64 && cache.stats().retained_bytes == 0);
        const auto before = computations;
        CHECK(cache.get_or_compute(4, result, compute));
        CHECK(cache.get_or_compute(1, result, compute) && result == a);
        CHECK(computations == before); // survivors retain results
        CHECK(cache.set_capacity(SIZE_MAX)); // capped by original pool limit
        CHECK(cache.effective_capacity_bytes() == 128 && outstanding.size() == 2);
        fail_next = true;
        CHECK(!cache.get_or_compute(5, result, compute));
        CHECK(cache.get_or_compute(1, result, compute) && result == a);
        CHECK(cache.set_capacity(0) && outstanding.empty());
        CHECK(cache.stats().cache_entries == 0 && cache.metadata_bytes() == 0);
        CHECK(cache.get_or_compute(1, result, compute) && result == a);
        CHECK(cache.set_capacity(0) && outstanding.empty()); // trims bypass scratch too
        CHECK(cache.set_capacity(32));
        CHECK(cache.get_or_compute(1, result, compute) && result == a);
    }
    CHECK(outstanding.empty());
    {
        // Independent LRU reference across repeated resize/request cycles.
        runtime::BoundedCache cache(32, 8, 0, allocate, deallocate);
        std::vector<uint32_t> lru; // oldest first
        size_t capacity = 0;
        uint64_t hits = 0, misses = 0, evictions = 0;
        for (uint32_t step = 0; step < 500; ++step) {
            if (step % 7 == 0) {
                const size_t bytes = ((step * 13) % 11) * 32 + 7;
                capacity = std::min(size_t(8), bytes / 32);
                while (lru.size() > capacity) { lru.erase(lru.begin()); ++evictions; }
                CHECK(cache.set_capacity(bytes));
                CHECK(outstanding.size() == lru.size());
                CHECK(cache.stats().retained_bytes == 0);
            }
            const uint32_t key = (step * 17 + step / 3) % 13;
            auto found = std::find(lru.begin(), lru.end(), key);
            if (found != lru.end()) { ++hits; lru.erase(found); lru.push_back(key); }
            else {
                ++misses;
                if (capacity) {
                    if (lru.size() == capacity) { lru.erase(lru.begin()); ++evictions; }
                    lru.push_back(key);
                }
            }
            CHECK(cache.get_or_compute(key, result, compute));
            uint64_t expected = 0;
            for (size_t i = 0; i < 32; ++i) expected += (key + i) & 255;
            CHECK(result == expected);
            const auto s = cache.stats();
            CHECK(s.cache_hits == hits && s.cache_misses == misses && s.cache_evictions == evictions);
            CHECK(s.cache_entries == lru.size() && s.cache_bytes == lru.size() * 32);
            CHECK(s.allocations - s.frees == outstanding.size() && s.invalid_releases == 0);
        }
        cache.clear();
        CHECK(outstanding.empty() && cache.stats().allocations == cache.stats().frees);
    }
    CHECK(outstanding.empty());
    std::puts("BOUNDED_CACHE_UNIT_PASS");
}

#include "../src/workloads/buffer_pool.hpp"
#include <cassert>
#include <cstdio>
#include <set>
#undef assert
#define assert(condition) do { if (!(condition)) { std::printf("FAIL line %d: %s\n", __LINE__, #condition); std::fflush(stdout); std::abort(); } } while (false)

static std::set<void*> outstanding;
static bool fail_next = false;
static void* allocate(size_t bytes) {
    if (fail_next) { fail_next = false; return nullptr; }
    void* p = std::malloc(bytes);
    assert(p && outstanding.insert(p).second);
    return p;
}
static void deallocate(void* p) {
    assert(outstanding.erase(p) == 1); // catches duplicate/foreign frees
    std::free(p);
}
int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    runtime::BufferPool zero_bytes(0, 2), zero_blocks(8, 0), overflow(SIZE_MAX, 2);
    assert(!zero_bytes.valid() && !zero_blocks.valid() && !overflow.valid());
    assert(!zero_bytes.acquire() && !zero_blocks.acquire() && !overflow.acquire());
    {
        runtime::BufferPool pool(32, 2, allocate, deallocate);
        auto* a = pool.acquire();
        auto* b = pool.acquire();
        assert(a && b && a != b && pool.capacity_bytes() == 64);
        assert(pool.stats().live_bytes == 64 && outstanding.size() == 2);
        assert(!pool.acquire());
        assert(pool.stats().pool_exhaustions == 1 && pool.stats().allocation_calls == 2);
        a[0] = 123;
        assert(pool.release(a));
        assert(!pool.release(a));
        unsigned char foreign = 0;
        assert(!pool.release(&foreign) && !pool.release(nullptr));
        runtime::BufferPool other(32, 1, allocate, deallocate);
        assert(!other.release(b));
        assert(pool.stats().live_bytes == 32 && pool.stats().retained_bytes == 32);
        auto* reused = pool.acquire();
        assert(reused == a && reused[0] == 123);
        assert(pool.stats().pool_hits == 1 && pool.stats().allocations == 2);
        assert(pool.release(reused) && pool.release(b));
        for (int i = 0; i < 1000; ++i) {
            auto* p = pool.acquire();
            assert(p && pool.release(p));
            assert(pool.stats().live_bytes + pool.stats().retained_bytes <= pool.capacity_bytes());
        }
        assert(pool.stats().allocations == 2 && pool.stats().pool_hits == 1001);
        pool.clear();
        assert(pool.stats().frees == 2 && pool.stats().retained_bytes == 0 && outstanding.empty());
        pool.clear();
        assert(pool.stats().frees == 2);
        // Reuse after clear and destruction with an outstanding lease must not leak.
        assert(pool.acquire());
    }
    assert(outstanding.empty());
    {
        runtime::BufferPool pool(16, 1, allocate, deallocate);
        fail_next = true;
        assert(!pool.acquire());
        assert(pool.stats().allocation_failures == 1 && pool.stats().pool_exhaustions == 0);
        assert(pool.stats().live_bytes == 0 && pool.stats().retained_bytes == 0);
        auto* p = pool.acquire();
        assert(p && pool.release(p));
        assert(pool.stats().allocation_calls == 2 && pool.stats().allocations == 1);
    }
    assert(outstanding.empty());
    {
        runtime::BufferPool pool(32, 3, allocate, deallocate);
        auto* live = pool.acquire();
        auto* idle = pool.acquire();
        live[0] = 91;
        assert(pool.release(idle));
        assert(pool.trim_idle() == 32 && outstanding.size() == 1);
        assert(live[0] == 91 && pool.stats().live_bytes == 32);
        assert(pool.stats().retained_bytes == 0 && pool.stats().frees == 1);
        assert(pool.trim_idle() == 0 && pool.capacity_bytes() == 96);
        assert(pool.acquire()); // freed slots can allocate again
        assert(pool.release(live));
        assert(pool.trim_idle() == 32);
    }
    assert(outstanding.empty());
    std::puts("BUFFER_POOL_UNIT_PASS");
}

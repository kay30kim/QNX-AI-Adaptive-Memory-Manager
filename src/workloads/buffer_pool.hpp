#ifndef QNX_BUFFER_POOL_HPP
#define QNX_BUFFER_POOL_HPP
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <new>

namespace runtime {
struct BufferStats {
    uint64_t allocation_calls = 0, allocations = 0, frees = 0, allocation_failures = 0;
    uint64_t pool_hits = 0, pool_misses = 0, pool_exhaustions = 0, invalid_releases = 0;
    uint64_t allocated_bytes = 0, live_bytes = 0, retained_bytes = 0;
};

// Single-threaded, fixed-block, lazy allocation. Capacity bounds ALL owned
// blocks (checked out + idle). No heap fallback when the pool is exhausted.
// Callers must return each acquired pointer exactly once, before pool teardown.
class BufferPool {
    struct Slot { unsigned char* data = nullptr; bool used = false; };
    size_t block_bytes_;
    size_t blocks_ = 0;
    std::unique_ptr<Slot[]> slots_;
    BufferStats stats_;
    void* (*allocate_)(size_t);
    void (*deallocate_)(void*);
public:
    BufferPool(size_t bytes, size_t blocks, void* (*allocate)(size_t) = std::malloc,
               void (*deallocate)(void*) = std::free)
        : block_bytes_(bytes), allocate_(allocate), deallocate_(deallocate) {
        if (!bytes || !blocks || !allocate || !deallocate || blocks > SIZE_MAX / bytes || blocks > SIZE_MAX / sizeof(Slot)) return;
        slots_.reset(new (std::nothrow) Slot[blocks]);
        if (slots_) blocks_ = blocks;
    }
    BufferPool(const BufferPool&) = delete;
    BufferPool& operator=(const BufferPool&) = delete;
    ~BufferPool() { clear(); }
    const BufferStats& stats() const { return stats_; }
    bool valid() const { return blocks_ != 0; }
    size_t capacity_bytes() const { return blocks_ * block_bytes_; }
    size_t metadata_bytes() const { return blocks_ * sizeof(Slot); }

    unsigned char* acquire() {
        for (size_t i = 0; i < blocks_; ++i) {
            auto& slot = slots_[i];
            if (slot.data && !slot.used) {
                slot.used = true;
                ++stats_.pool_hits;
                stats_.live_bytes += block_bytes_;
                stats_.retained_bytes -= block_bytes_;
                return slot.data;
            }
        }
        ++stats_.pool_misses;
        for (size_t i = 0; i < blocks_; ++i) {
            auto& slot = slots_[i];
            if (!slot.data) {
                ++stats_.allocation_calls;
                slot.data = static_cast<unsigned char*>(allocate_(block_bytes_));
                if (!slot.data) { ++stats_.allocation_failures; return nullptr; }
                slot.used = true;
                ++stats_.allocations;
                stats_.allocated_bytes += block_bytes_;
                stats_.live_bytes += block_bytes_;
                return slot.data;
            }
        }
        ++stats_.pool_exhaustions;
        return nullptr;
    }

    bool release(unsigned char* block) {
        for (size_t i = 0; i < blocks_; ++i) {
            auto& slot = slots_[i];
            if (block && slot.data == block && slot.used) {
                slot.used = false;
                stats_.live_bytes -= block_bytes_;
                stats_.retained_bytes += block_bytes_;
                return true;
            }
        }
        ++stats_.invalid_releases;
        return false;
    }

    // Only call after all clients stop using their pointers. Idempotent;
    // destructor also releases outstanding blocks to avoid leaking on errors.
    void clear() noexcept {
        for (size_t i = 0; i < blocks_; ++i) {
            auto& slot = slots_[i];
            if (slot.data) { deallocate_(slot.data); ++stats_.frees; }
            slot.data = nullptr;
            slot.used = false;
        }
        stats_.live_bytes = stats_.retained_bytes = 0;
    }
};
}
#endif

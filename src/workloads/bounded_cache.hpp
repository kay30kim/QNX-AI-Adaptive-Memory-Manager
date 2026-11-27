#ifndef QNX_BOUNDED_CACHE_HPP
#define QNX_BOUNDED_CACHE_HPP
#include "buffer_pool.hpp"

namespace runtime {
// Single-threaded fixed-size result cache. Owns its pool and all cached leases.
// Compute fills a whole block and returns its result checksum; it must not throw
// or retain the buffer pointer. The key identifies immutable content at this size.
class BoundedCache {
    static constexpr size_t none = SIZE_MAX;
    struct Entry {
        unsigned char* block = nullptr;
        uint32_t key = 0;
        uint64_t result = 0;
        size_t previous = none, next = none;
    };
    BufferPool pool_;
    size_t block_bytes_, entry_limit_;
    std::unique_ptr<Entry[]> entries_;
    size_t head_ = none, tail_ = none;
    BufferStats cache_;
    uint64_t peak_live_ = 0, peak_owned_ = 0;

    void unlink(size_t index) {
        auto& entry = entries_[index];
        if (entry.previous == none) head_ = entry.next;
        else entries_[entry.previous].next = entry.next;
        if (entry.next == none) tail_ = entry.previous;
        else entries_[entry.next].previous = entry.previous;
        entry.previous = entry.next = none;
    }
    void front(size_t index) {
        auto& entry = entries_[index];
        entry.previous = none;
        entry.next = head_;
        if (head_ != none) entries_[head_].previous = index;
        else tail_ = index;
        head_ = index;
    }
    void observe() {
        peak_live_ = std::max(peak_live_, pool_.stats().live_bytes);
        peak_owned_ = std::max(peak_owned_, pool_.stats().live_bytes + pool_.stats().retained_bytes);
    }
public:
    BoundedCache(size_t bytes, size_t pool_blocks, size_t cache_bytes,
                 void* (*allocate)(size_t) = std::malloc, void (*deallocate)(void*) = std::free)
        : pool_(bytes, pool_blocks, allocate, deallocate), block_bytes_(bytes),
          entry_limit_(bytes ? std::min(pool_blocks, cache_bytes / bytes) : 0) {
        if (entry_limit_ > SIZE_MAX / sizeof(Entry)) { entry_limit_ = 0; return; }
        if (pool_.valid() && entry_limit_) entries_.reset(new (std::nothrow) Entry[entry_limit_]);
    }
    BoundedCache(const BoundedCache&) = delete;
    BoundedCache& operator=(const BoundedCache&) = delete;
    ~BoundedCache() { clear(); }
    bool valid() const { return pool_.valid() && (!entry_limit_ || entries_); }
    size_t effective_capacity_bytes() const { return entry_limit_ * block_bytes_; }
    size_t metadata_bytes() const { return entries_ ? entry_limit_ * sizeof(Entry) : 0; }
    size_t pool_metadata_bytes() const { return pool_.metadata_bytes(); }
    // Call between requests on the owning thread (never from Compute).
    // Round down to whole blocks and cap at the original pool capacity.
    // Allocate replacement metadata before changing anything: failure leaves
    // the existing capacity, entries, LRU order and counters untouched.
    bool set_capacity(size_t cache_bytes) {
        if (!valid()) return false;
        const size_t limit = std::min(pool_.capacity_bytes() / block_bytes_, cache_bytes / block_bytes_);
        if (limit > SIZE_MAX / sizeof(Entry)) return false;
        if (limit == entry_limit_) { pool_.trim_idle(); return true; }
        std::unique_ptr<Entry[]> replacement;
        if (limit) {
            replacement.reset(new (std::nothrow) Entry[limit]);
            if (!replacement) return false;
        }
        // Keep the most recently used entries, compacting their slot indices.
        const size_t keep = std::min(limit, static_cast<size_t>(cache_.cache_entries));
        size_t old = head_;
        for (size_t i = 0; i < keep; ++i) {
            replacement[i] = entries_[old];
            old = entries_[old].next;
            replacement[i].previous = i ? i - 1 : none;
            replacement[i].next = i + 1 < keep ? i + 1 : none;
        }
        while (cache_.cache_entries > keep) {
            const size_t index = tail_;
            pool_.release(entries_[index].block);
            unlink(index);
            --cache_.cache_entries;
            cache_.cache_bytes -= block_bytes_;
            ++cache_.cache_evictions;
        }
        entries_.swap(replacement);
        entry_limit_ = limit;
        head_ = keep ? 0 : none;
        tail_ = keep ? keep - 1 : none;
        pool_.trim_idle();
        return true;
    }
    uint64_t request_peak_live() const { return peak_live_; }
    uint64_t request_peak_owned() const { return peak_owned_; }
    BufferStats stats() const {
        auto result = pool_.stats();
        result.cache_hits = cache_.cache_hits;
        result.cache_misses = cache_.cache_misses;
        result.cache_evictions = cache_.cache_evictions;
        result.cache_bypasses = cache_.cache_bypasses;
        result.cache_bytes = cache_.cache_bytes;
        result.cache_entries = cache_.cache_entries;
        return result;
    }
    template<class Compute>
    bool get_or_compute(uint32_t key, uint64_t& result, Compute compute) {
        peak_live_ = peak_owned_ = 0;
        observe();
        if (!valid()) return false;
        for (size_t i = 0; i < entry_limit_; ++i) {
            auto& entry = entries_[i];
            if (entry.block && entry.key == key) {
                ++cache_.cache_hits;
                result = entry.result;
                unlink(i);
                front(i);
                return true;
            }
        }
        ++cache_.cache_misses;
        if (!entry_limit_) {
            ++cache_.cache_bypasses;
            auto* block = pool_.acquire();
            observe();
            if (!block) return false;
            result = compute(key, block, block_bytes_);
            return pool_.release(block);
        }
        size_t index = 0;
        if (cache_.cache_entries == entry_limit_) {
            index = tail_;
            // Evict BEFORE acquiring: respects the pool limit with no extra scratch block.
            if (!pool_.release(entries_[index].block)) return false;
            unlink(index);
            entries_[index].block = nullptr;
            --cache_.cache_entries;
            cache_.cache_bytes -= block_bytes_;
            ++cache_.cache_evictions;
        } else {
            while (entries_[index].block) ++index;
        }
        auto* block = pool_.acquire();
        observe();
        if (!block) return false;
        result = compute(key, block, block_bytes_);
        auto& entry = entries_[index];
        entry.block = block;
        entry.key = key;
        entry.result = result;
        front(index);
        ++cache_.cache_entries;
        cache_.cache_bytes += block_bytes_;
        return true;
    }
    void clear() noexcept {
        if (entries_) {
            for (size_t i = 0; i < entry_limit_; ++i) {
                if (entries_[i].block) pool_.release(entries_[i].block);
                entries_[i] = Entry();
            }
        }
        head_ = tail_ = none;
        cache_.cache_entries = cache_.cache_bytes = 0;
        pool_.clear();
    }
};
}
#endif

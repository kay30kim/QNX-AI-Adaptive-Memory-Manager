#define _POSIX_C_SOURCE 200809L
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

int main()
{
    constexpr size_t block_bytes = 1024 * 1024; // 1 MiB per operation
    constexpr size_t iterations = 100;
    const long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) {
        std::fprintf(stderr, "Cannot determine page size.\n");
        return 1;
    }

    for (size_t i = 0; i < iterations; ++i) {
        void* block = std::malloc(block_bytes);
        if (!block) {
            std::fprintf(stderr, "Allocation failed at operation %zu.\n", i + 1);
            return 1;
        }

        // Touch every page; volatile prevents these writes being optimized away.
        volatile unsigned char* bytes = static_cast<unsigned char*>(block);
        for (size_t offset = 0; offset < block_bytes; offset += static_cast<size_t>(page_size))
            bytes[offset] = 1;
        bytes[block_bytes - 1] = 1;

        std::free(block);
    }

    std::printf("Completed %zu operations: allocate, touch, free %zu MiB each.\n",
                iterations, block_bytes / (1024 * 1024));
    return 0;
}

#define _POSIX_C_SOURCE 200809L
#include <cstdio>
#include <cstdlib>
#include <sys/stat.h>
#include <unistd.h>

// These counters describe our requested buffers, not total process memory.
static void observe(const char* stage, size_t live_bytes)
{
    std::printf("\n=== %s ===\nApp live buffers: %zu MiB; PID: %ld\n",
                stage, live_bytes / (1024 * 1024), static_cast<long>(getpid()));
    std::fflush(stdout);
    char command[96];
    std::snprintf(command, sizeof(command), "pidin -p %ld mem",
                  static_cast<long>(getpid()));
    if (std::system(command) != 0)
        std::printf("pidin failed; the app counter above is still available.\n");
    std::printf("Inspect the numbers, then press Enter to continue.\n");
    std::fflush(stdout);
    int ch;
    do { ch = std::getchar(); } while (ch != '\n' && ch != EOF);
}

int main()
{
    // QNX exposes system-wide available RAM through /proc's st_size.
    struct stat memory_info = {};
    if (stat("/proc", &memory_info) == -1) {
        std::perror("Cannot read available RAM");
        return 1;
    }
    std::printf("System available RAM: %.2f MiB\n",
                static_cast<double>(memory_info.st_size) / (1024 * 1024));

    constexpr size_t block_bytes = 8 * 1024 * 1024;
    constexpr size_t block_count = 4;
    void* blocks[block_count] = {};
    const long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) {
        std::printf("Cannot determine page size.\n");
        return 1;
    }
    std::printf("Page size: %ld bytes\n", page_size);

    observe("1. Baseline", 0);
    for (size_t i = 0; i < block_count; ++i) {
        blocks[i] = std::malloc(block_bytes);
        if (!blocks[i]) {
            std::printf("Allocation failed; releasing existing buffers.\n");
            for (void* block : blocks) std::free(block);
            return 1;
        }
    }
    observe("2. Allocated, not explicitly touched", block_count * block_bytes);

    for (void* block : blocks) {
        // Volatile keeps these teaching writes from being optimized away.
        volatile unsigned char* bytes = static_cast<unsigned char*>(block);
        for (size_t offset = 0; offset < block_bytes; offset += static_cast<size_t>(page_size))
            bytes[offset] = 1;
        bytes[block_bytes - 1] = 1;
    }
    observe("3. Wrote to every page", block_count * block_bytes);

    for (size_t i = 0; i < block_count / 2; ++i) {
        std::free(blocks[i]);
        blocks[i] = nullptr;
    }
    observe("4. Freed half", block_count / 2 * block_bytes);
    for (void* block : blocks) std::free(block);
    observe("5. Freed all", 0);
    return 0;
}

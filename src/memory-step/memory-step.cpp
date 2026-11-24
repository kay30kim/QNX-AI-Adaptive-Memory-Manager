
#include <iostream>
#include <memory>
#include <chrono>
#include <thread>
#include <new>
#include <unistd.h>

int main() {
    constexpr size_t MiB = 1024 * 1024;
    constexpr size_t RAM = 700 * MiB;
    constexpr int HOLD_SECONDS = 4;

    std::unique_ptr<unsigned char[]> memory;

    try {
        std::cout << "PID: " << getpid() << '\n';
        std::cout << "Allocating 700 MiB...\n";

        // Allocate memory
        memory.reset(new unsigned char[RAM]);

        // Force physical page allocation
        long ps = sysconf(_SC_PAGESIZE);
        size_t page_size = ps > 0 ? static_cast<size_t>(ps) : 4096;

        volatile unsigned char* ptr = memory.get();

        for (size_t i = 0; i < RAM; i += page_size) {
            ptr[i] = 0xAA;
        }
        ptr[RAM - 1] = 0xAA;

        std::cout << "STEP UP: 700 MiB\n";

        std::this_thread::sleep_for(
            std::chrono::seconds(HOLD_SECONDS)
        );

        // Release memory
        memory.reset();

        std::cout << "STEP DOWN: 0 MiB\n";

    } catch (const std::bad_alloc&) {
        memory.reset();
        std::cerr << "ERROR: Out of memory\n";
        return 1;
    }

    return 0;
}

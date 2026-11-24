#include <algorithm>
#include <iostream>
#include <vector>
#include <cmath>
#include <chrono>
#include <thread>
#include <cstring>
#include <csignal>
#include <new>
#include <unistd.h>
#include <sys/mman.h>

volatile std::sig_atomic_t running = 1;

void stop_handler(int) {
    running = 0;
}

int main() {
    constexpr size_t MiB = 1024 * 1024;
    constexpr size_t BLOCK = 1 * MiB;

    // Target RAM = CENTER +/- AMPLITUDE MiB = 100..700 MiB.
    constexpr double CENTER = 400.0;
    constexpr double AMPLITUDE = 300.0;
    constexpr double MAX_TARGET = 700.0;   // also the capacity reserved for the block list

    constexpr double PERIOD_SLOW = 30.0;
    constexpr double PERIOD_FAST = 3.0;

    constexpr int INTERVAL_MS = 100;
    constexpr double PI = 3.14159265358979323846;

    using Clock = std::chrono::steady_clock;

    std::signal(SIGINT, stop_handler);
    std::signal(SIGTERM, stop_handler);

    std::vector<void*> blocks;

    try {
        blocks.reserve(static_cast<size_t>(MAX_TARGET));
    } catch (const std::bad_alloc&) {
        std::cerr << "ERROR: Vector allocation failed\n";
        return 1;
    }

    std::cout << "PID: " << getpid() << '\n';
    std::cout << "Sinusoidal RAM test started\n";

    auto start = Clock::now();
    size_t tick = 0;
    int status = 0;

    while (running) {
        auto now = Clock::now();

        double t = std::chrono::duration<double>(
            now - start
        ).count();

        // Low-frequency sinusoid
        double slow = std::sin(
            2.0 * PI * t / PERIOD_SLOW
        );

        // High-frequency sinusoid
        double fast = std::sin(
            2.0 * PI * t / PERIOD_FAST
        );

        // RAM = 400 +/- 300 MiB. Clamped so it can never be negative: converting a negative
        // value to size_t wraps to a huge target and allocates until memory runs out.
        double ram = std::clamp(CENTER + AMPLITUDE * slow * fast, 0.0, MAX_TARGET);

        size_t target = static_cast<size_t>(
            std::lround(ram)
        );

        // Allocate memory
        while (blocks.size() < target && running) {
            void* ptr = mmap(
                nullptr,
                BLOCK,
                PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANON,
                -1,
                0
            );

            if (ptr == MAP_FAILED) {
                std::perror("mmap failed");
                status = 1;
                running = 0;
                break;
            }

            std::memset(ptr, 0xAA, BLOCK);
            blocks.push_back(ptr);
        }

        // Release memory
        while (blocks.size() > target) {
            void* ptr = blocks.back();

            if (munmap(ptr, BLOCK) == -1) {
                std::perror("munmap failed");
                status = 1;
                running = 0;
                break;
            }

            blocks.pop_back();
        }

        if (tick % 5 == 0) {
            std::cout
                << "t=" << t
                << " s | Target=" << target
                << " MiB | Allocated="
                << blocks.size()
                << " MiB"
                << std::endl;
        }

        ++tick;

        std::this_thread::sleep_until(
            start + std::chrono::milliseconds(
                tick * INTERVAL_MS
            )
        );
    }

    // Release all memory
    std::cout << "Releasing all memory...\n";

    for (void* ptr : blocks) {
        if (munmap(ptr, BLOCK) == -1) {
            std::perror("munmap cleanup failed");
            status = 1;
        }
    }

    blocks.clear();

    std::cout << "Memory released. Exiting.\n";

    return status;
}
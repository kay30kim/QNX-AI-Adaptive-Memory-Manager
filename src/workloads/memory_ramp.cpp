#include <iostream>
#include <vector>
#include <memory>
#include <chrono>
#include <thread>
#include <cstring>

int main() {
    constexpr size_t STEP = 10 * 1024 * 1024;
    constexpr size_t MAX_RAM = 800 * 1024 * 1024;

    std::vector<std::unique_ptr<char[]>> blocks;
    size_t total = 0;

    try {
        blocks.reserve(MAX_RAM / STEP);

        while (total < MAX_RAM) {
            auto block = std::make_unique<char[]>(STEP);
            std::memset(block.get(), 1, STEP);

            blocks.push_back(std::move(block));
            total += STEP;

            std::cout << "RAM allocated: "
                      << total / (1024 * 1024)
                      << " / 800 MiB" << std::endl;

            if (total < MAX_RAM)
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(500)
                );
        }

    } catch (const std::bad_alloc&) {
        std::cerr << "ERROR: Out of memory." << std::endl;

        blocks.clear();
        std::cout << "Memory released after the exception." << std::endl;
        return 1;
    }

    blocks.clear();
    std::cout << "Memory released. Exiting." << std::endl;

    return 0;
}
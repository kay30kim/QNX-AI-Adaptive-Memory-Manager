#include <iostream>
#include <chrono>
#include <thread>

int main() {
    using namespace std::chrono;

    auto next = steady_clock::now();

    for (int i = 1; i <= 10; i++) {
        std::cout << "Hello World " << i << std::endl;

        next += seconds(1);
        std::this_thread::sleep_until(next);
    }

    return 0;
}

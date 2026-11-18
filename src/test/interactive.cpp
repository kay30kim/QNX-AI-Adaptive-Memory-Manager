#include <iostream>

int main() {
    std::cout << "Enter a number: " << std::flush;
    int value;
    if (!(std::cin >> value)) {
        std::cerr << "Invalid input.\n";
        return 1;
    }
    std::cout << "Received: " << value << '\n';
    return 0;
}

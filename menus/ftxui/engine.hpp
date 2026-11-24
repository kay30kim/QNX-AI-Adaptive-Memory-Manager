// Client for the headless engine `menu.ps1 -Serve` (see menus/dashboard.ps1).
// The engine owns all the logic; this side only parses its state frames and logs
// and sends it commands.
#pragma once
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

struct TreeNode {
    int depth = 0;
    bool dir = false;
    bool expanded = false;
    std::string name;
};

struct Snapshot {
    std::map<std::string, std::string> fields;
    std::vector<std::pair<std::string, double>> cores;
    std::vector<double> hist;       // QNX RAM used (MiB), one value per guest sample
    std::vector<double> hist_cpu;   // QNX mean CPU busy (%)
    std::vector<double> hist_host;  // VM host resident (MiB), one value per second
    std::vector<TreeNode> nodes;
    std::vector<std::string> sources;

    std::string get(const std::string& key) const;
    bool flag(const std::string& key) const { return get(key) == "1"; }
    bool has(const std::string& key) const { return fields.count(key) > 0; }
    double num(const std::string& key) const;
    void add(const std::string& line);
};

struct LogLine {
    std::string kind;  // cmd, err, ok, text
    std::string text;
};

// State shared between the reader threads and the UI thread.
struct EngineState {
    std::mutex mu;
    Snapshot snap;
    bool connected = false;
    bool closed = false;
    std::deque<LogLine> log;
    std::function<void()> notify;  // called (without the lock) after every update
    void add_log(std::string kind, std::string text);
};

class Engine {
public:
    Engine();
    ~Engine();
    bool start(std::string& error);
    void send(const std::string& verb, const std::string& argument = "");
    // Asks the engine to quit so it can stop its SSH sessions; kills it after a timeout.
    void stop();
    std::shared_ptr<EngineState> state() const { return state_; }

private:
    std::shared_ptr<EngineState> state_;
    void* process_ = nullptr;
    void* stdin_ = nullptr;
    void* job_ = nullptr;
};

std::string menu_script();

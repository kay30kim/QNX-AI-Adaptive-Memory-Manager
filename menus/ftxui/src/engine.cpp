#include "engine.hpp"

#include <cstdlib>
#include <thread>
#include <windows.h>

namespace {
constexpr size_t kLogLimit = 2000;

bool file_exists(const std::string& path) {
    DWORD attributes = GetFileAttributesA(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

std::vector<std::string> split_tabs(const std::string& value, size_t limit) {
    std::vector<std::string> parts;
    size_t start = 0;
    while (parts.size() + 1 < limit) {
        size_t tab = value.find('\t', start);
        if (tab == std::string::npos) break;
        parts.push_back(value.substr(start, tab - start));
        start = tab + 1;
    }
    parts.push_back(value.substr(start));
    return parts;
}

// Reads a pipe until it closes and calls `each` for every line.
void read_lines(HANDLE pipe, const std::function<void(const std::string&)>& each) {
    std::string pending;
    char buffer[4096];
    DWORD count = 0;
    while (ReadFile(pipe, buffer, sizeof buffer, &count, nullptr) && count > 0) {
        pending.append(buffer, count);
        size_t newline;
        while ((newline = pending.find('\n')) != std::string::npos) {
            std::string line = pending.substr(0, newline);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            each(line);
            pending.erase(0, newline + 1);
        }
    }
    if (!pending.empty()) each(pending);
    CloseHandle(pipe);
}

void notify(const std::shared_ptr<EngineState>& state) {
    std::function<void()> callback;
    {
        std::lock_guard<std::mutex> lock(state->mu);
        callback = state->notify;
    }
    if (callback) callback();
}
}  // namespace

// Finds menu.ps1: QNX_ROOT, then the executable's directory and its parents, then the current directory.
std::string menu_script() {
    const char* root = std::getenv("QNX_ROOT");
    if (root && *root) {
        std::string path = std::string(root) + "\\menu.ps1";
        if (file_exists(path)) return path;
    }
    char buffer[4096];
    DWORD length = GetModuleFileNameA(nullptr, buffer, sizeof buffer);
    if (length > 0 && length < sizeof buffer) {
        std::string dir(buffer, length);
        size_t slash;
        while ((slash = dir.find_last_of('\\')) != std::string::npos) {
            dir.resize(slash);
            std::string path = dir + "\\menu.ps1";
            if (file_exists(path)) return path;
        }
    }
    return "menu.ps1";
}

std::string Snapshot::get(const std::string& key) const {
    auto it = fields.find(key);
    return it == fields.end() ? std::string() : it->second;
}

double Snapshot::num(const std::string& key) const {
    auto it = fields.find(key);
    return it == fields.end() ? 0.0 : std::strtod(it->second.c_str(), nullptr);
}

void Snapshot::add(const std::string& line) {
    size_t tab = line.find('\t');
    std::string key = line.substr(0, tab);
    std::string value = tab == std::string::npos ? std::string() : line.substr(tab + 1);
    if (key == "core") {
        auto parts = split_tabs(value, 2);
        if (parts.size() == 2) cores.emplace_back(parts[0], std::strtod(parts[1].c_str(), nullptr));
    } else if (key == "hist" || key == "hist_cpu" || key == "hist_host") {
        std::vector<double>& series = key == "hist" ? hist : key == "hist_cpu" ? hist_cpu : hist_host;
        const char* p = value.c_str();
        char* end = nullptr;
        for (double v = std::strtod(p, &end); end != p; v = std::strtod(p, &end)) { series.push_back(v); p = end; }
    } else if (key == "src") {
        sources.push_back(value);
    } else if (key == "node") {
        auto parts = split_tabs(value, 4);
        if (parts.size() == 4) nodes.push_back({std::atoi(parts[0].c_str()), parts[1] == "1", parts[2] == "1", parts[3]});
    } else {
        fields[key] = value;
    }
}

void EngineState::add_log(std::string kind, std::string text) {
    log.push_back({std::move(kind), std::move(text)});
    while (log.size() > kLogLimit) log.pop_front();
}

Engine::Engine() : state_(std::make_shared<EngineState>()) {}

Engine::~Engine() {
    stop();
    if (job_) CloseHandle(job_);
}

bool Engine::start(std::string& error) {
    SECURITY_ATTRIBUTES sa{sizeof sa, nullptr, TRUE};
    HANDLE out_read, out_write, err_read, err_write, in_read, in_write;
    if (!CreatePipe(&out_read, &out_write, &sa, 0) || !CreatePipe(&err_read, &err_write, &sa, 0) || !CreatePipe(&in_read, &in_write, &sa, 0)) {
        error = "CreatePipe failed";
        return false;
    }
    SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(err_read, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(in_write, HANDLE_FLAG_INHERIT, 0);

    std::string command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"" + menu_script() + "\" -Serve";
    std::vector<char> line(command.begin(), command.end());
    line.push_back('\0');
    STARTUPINFOA startup{};
    startup.cb = sizeof startup;
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = in_read;
    startup.hStdOutput = out_write;
    startup.hStdError = err_write;
    PROCESS_INFORMATION info{};
    // A kill-on-close job makes sure the engine and its ssh children never outlive this program.
    job_ = CreateJobObjectA(nullptr, nullptr);
    if (job_) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &limits, sizeof limits);
    }
    BOOL ok = CreateProcessA(nullptr, line.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &startup, &info);
    CloseHandle(out_write);
    CloseHandle(err_write);
    CloseHandle(in_read);
    if (!ok) {
        error = "Could not start powershell.exe (error " + std::to_string(GetLastError()) + ")";
        CloseHandle(out_read);
        CloseHandle(err_read);
        CloseHandle(in_write);
        return false;
    }
    if (job_) AssignProcessToJobObject(job_, info.hProcess);
    ResumeThread(info.hThread);
    CloseHandle(info.hThread);
    process_ = info.hProcess;
    stdin_ = in_write;

    auto state = state_;
    std::thread([state, out_read] {
        auto current = std::make_shared<Snapshot>();
        bool in_frame = false;
        read_lines(out_read, [&](const std::string& line) {
            if (line == "@@FRAME") { *current = Snapshot{}; in_frame = true; return; }
            if (line == "@@END") {
                if (!in_frame) return;
                in_frame = false;
                {
                    std::lock_guard<std::mutex> lock(state->mu);
                    state->snap = *current;
                    state->connected = true;
                }
                notify(state);
                return;
            }
            if (line.rfind("@@LOG\t", 0) == 0) {
                auto parts = split_tabs(line.substr(6), 2);
                {
                    std::lock_guard<std::mutex> lock(state->mu);
                    if (parts.size() == 2) state->add_log(parts[0], parts[1]); else state->add_log("text", parts[0]);
                }
                notify(state);
                return;
            }
            if (in_frame) current->add(line);
        });
        {
            std::lock_guard<std::mutex> lock(state->mu);
            state->closed = true;
        }
        notify(state);
    }).detach();
    std::thread([state, err_read] {
        read_lines(err_read, [&](const std::string& line) {
            if (line.find_first_not_of(" \t") == std::string::npos) return;
            {
                std::lock_guard<std::mutex> lock(state->mu);
                state->add_log("err", line);
            }
            notify(state);
        });
    }).detach();
    return true;
}

void Engine::send(const std::string& verb, const std::string& argument) {
    if (!stdin_) return;
    std::string clean = argument;
    for (char& c : clean) if (c == '\t' || c == '\r' || c == '\n') c = ' ';
    std::string line = verb + "\t" + clean + "\n";
    DWORD written = 0;
    WriteFile(static_cast<HANDLE>(stdin_), line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
}

void Engine::stop() {
    {
        std::lock_guard<std::mutex> lock(state_->mu);
        state_->notify = nullptr;
    }
    if (!process_) return;
    send("quit");
    CloseHandle(static_cast<HANDLE>(stdin_));
    stdin_ = nullptr;
    if (WaitForSingleObject(static_cast<HANDLE>(process_), 4000) != WAIT_OBJECT_0) TerminateProcess(static_cast<HANDLE>(process_), 1);
    CloseHandle(static_cast<HANDLE>(process_));
    process_ = nullptr;
}

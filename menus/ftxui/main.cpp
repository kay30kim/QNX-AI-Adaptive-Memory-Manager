// FTXUI front end for the QNX Control Center.
// Same layout and keys as the PowerShell dashboard (menu.ps1). The logic runs in
// `menu.ps1 -Serve` (engine.cpp); this file only renders its state and forwards keys.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <string>
#include <variant>
#include <vector>

#include <ftxui/component/component.hpp>
#include <ftxui/component/screen_interactive.hpp>
#include <ftxui/dom/elements.hpp>
#include <ftxui/screen/terminal.hpp>

#include "engine.hpp"

using namespace ftxui;

namespace {
const char* const kLogo[] = {"    ___  _   _ __  __", "   / _ \\| \\ | |\\ \\/ /", "  | | | |  \\| | \\  /", "  | |_| | |\\  | /  \\", "   \\__\\_\\_| \\_|/_/\\_\\", "  CONTROL CENTER"};
const Color kGray = Color::GrayLight;
const Color kDark = Color::GrayDark;

// ---- UTF-8 helpers: widths are counted in code points, like the dashboard counts characters.
size_t u8len(const std::string& s) {
    size_t n = 0;
    for (unsigned char c : s) n += (c & 0xC0) != 0x80;
    return n;
}
// Byte offset where code point number `chars` starts (or the end of the string).
size_t u8offset(const std::string& s, size_t chars) {
    size_t seen = 0;
    for (size_t i = 0; i < s.size(); ++i) {
        if ((static_cast<unsigned char>(s[i]) & 0xC0) == 0x80) continue;
        if (seen++ == chars) return i;
    }
    return s.size();
}
std::string u8take(const std::string& s, size_t chars) { return s.substr(0, u8offset(s, chars)); }
std::string u8tail(const std::string& s, size_t chars) {
    size_t n = u8len(s);
    return n <= chars ? s : s.substr(u8offset(s, n - chars));
}
std::string fit(const std::string& s, size_t width) { return u8len(s) > width ? u8take(s, width - 1) + "~" : s; }
std::vector<std::string> wrap(const std::string& s, size_t width) {
    std::vector<std::string> out;
    if (s.empty()) { out.emplace_back(); return out; }
    for (std::string rest = s; !rest.empty();) {
        std::string chunk = u8take(rest, width);
        rest.erase(0, chunk.size());
        out.push_back(chunk);
    }
    return out;
}
// Wraps text to `width` code points, breaking at spaces when possible.
std::vector<std::string> wrap_words(const std::string& s, size_t width) {
    std::vector<std::string> out;
    std::string rest = s;
    while (!rest.empty()) {
        size_t take = rest.size();
        if (u8len(rest) > width) {
            std::string head = u8take(rest, width + 1);
            size_t space = head.find_last_of(' ');
            take = space != std::string::npos && space > 0 ? space : u8take(rest, width).size();
        }
        out.push_back(rest.substr(0, take));
        rest.erase(0, take);
        rest.erase(0, rest.find_first_not_of(' ') == std::string::npos ? rest.size() : rest.find_first_not_of(' '));
    }
    return out;
}
std::string fmt(const char* format, double value) {
    char buffer[64];
    std::snprintf(buffer, sizeof buffer, format, value);
    return buffer;
}
std::string upper(std::string s) {
    for (char& c : s) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    return s;
}
std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t"), b = s.find_last_not_of(" \t");
    return a == std::string::npos ? std::string() : s.substr(a, b - a + 1);
}
bool starts_with(const std::string& s, const std::string& prefix) { return s.rfind(prefix, 0) == 0; }
Color log_color(const std::string& kind) {
    if (kind == "cmd") return Color::Magenta;
    if (kind == "err") return Color::Red;
    if (kind == "ok") return Color::Green;
    return kGray;
}
Element line(const std::string& s, Color c) { return text(s) | color(c); }
Color load_color(double busy) { return busy >= 85 ? Color::Red : busy >= 50 ? Color::Yellow : Color::Green; }

// A live chart: multi-row bars (8 levels per row) with a labelled Y axis; newest sample on the right.
struct ChartSpec {
    std::string title;
    std::vector<double> values;
    double low = 0, high = 100;
    double min_span = 0;  // > 0: dynamic axis that follows the visible samples
    int decimals = 0;
    Color color = Color::Cyan;
};
// Dynamic Y axis: follows the min/max of the visible samples (plus a margin), so small changes show.
// `min_span` keeps flat data from being magnified into noise.
ChartSpec dynamic_chart(const std::string& title, const std::vector<double>& values, double min_span, int decimals, Color c) {
    return {title, values, 0, 0, min_span, decimals, c};
}
// 0..N% axis, N rounded up to a multiple of 10 (at least 10).
ChartSpec percent_chart(const std::string& title, const std::vector<double>& values, Color c) {
    double max = *std::max_element(values.begin(), values.end());
    return {title, values, 0, std::clamp(std::ceil(max / 10) * 10, 10.0, 100.0), 0, 1, c};
}
// Samples per chart column: 2 samples (~1 s at 2 Hz) per column doubles the visible time window.
constexpr size_t kSamplesPerColumn = 2;

// Groups the newest samples into at most `max_columns` columns (newest last); each column
// shows the highest of its samples, so short peaks stay visible.
std::vector<double> chart_columns(const std::vector<double>& values, size_t max_columns) {
    size_t start = values.size() - std::min(values.size(), max_columns * kSamplesPerColumn);
    std::vector<double> columns;
    for (size_t end = values.size(); end > start;) {
        size_t begin = end - start >= kSamplesPerColumn ? end - kSamplesPerColumn : start;
        columns.push_back(*std::max_element(values.begin() + begin, values.begin() + end));
        end = begin;
    }
    std::reverse(columns.begin(), columns.end());
    return columns;
}

std::pair<double, double> chart_scale(const ChartSpec& chart, size_t visible) {
    if (chart.min_span <= 0) return {chart.low, chart.high};
    auto first = chart.values.end() - static_cast<std::ptrdiff_t>(visible);
    double low = *std::min_element(first, chart.values.end()), high = *std::max_element(first, chart.values.end());
    if (high - low < chart.min_span) {
        double mid = (low + high) / 2;
        low = mid - chart.min_span / 2;
        high = mid + chart.min_span / 2;
    }
    double pad = (high - low) * 0.15;
    return {std::max(0.0, low - pad), high + pad};
}
Element chart_element(const ChartSpec& chart, int width, int height) {
    static const char* const kBars[] = {"\u2581", "\u2582", "\u2583", "\u2584", "\u2585", "\u2586", "\u2587", "\u2588"};
    char number[32];
    std::snprintf(number, sizeof number, "%.*f", chart.decimals, chart.values.empty() ? 0.0 : chart.values.back());
    Elements rows = {line(fit(" " + chart.title + "  now " + number, width), chart.color)};
    if (chart.values.empty() || height <= 0) return vbox(std::move(rows));
    // Scale from the samples that fit (axis labels are at most ~7 characters wide).
    // Scale from the columns that fit (axis labels are at most ~7 characters wide).
    ChartSpec grouped = chart;
    grouped.values = chart_columns(chart.values, static_cast<size_t>(std::max(1, width - 10)));
    auto [low, high] = chart_scale(grouped, grouped.values.size());
    int digits = chart.min_span > 0 && high - low < 20 ? 1 : 0;
    auto label = [&](double v) { char b[32]; std::snprintf(b, sizeof b, "%.*f", digits, v); return std::string(b); };
    int mid_row = height >= 5 ? height / 2 : -1;
    std::vector<std::string> labels(height);
    for (int r = 0; r < height; ++r) {
        if (r == 0) labels[r] = label(high);
        else if (r == height - 1) labels[r] = label(low);
        else if (r == mid_row) labels[r] = label(high - (high - low) * r / (height - 1));
    }
    size_t label_width = 1;
    for (const auto& l : labels) label_width = std::max(label_width, l.size());
    int axis_width = static_cast<int>(label_width) + 2;
    int plot_width = std::max(0, width - axis_width - 1);
    std::vector<double> visible = chart_columns(chart.values, static_cast<size_t>(plot_width));
    size_t count = visible.size();
    double span = std::max(high - low, 1e-9);
    std::vector<int> eighths;  // bar height of each sample, in eighths of a row
    for (double value : visible)
        eighths.push_back(std::max(1, static_cast<int>(std::clamp((value - low) / span, 0.0, 1.0) * height * 8)));
    for (int r = 0; r < height; ++r) {
        std::string axis = " " + std::string(label_width - labels[r].size(), ' ') + labels[r] + (labels[r].empty() ? "\u2502" : "\u2524");
        std::string plot(plot_width - count, ' ');
        int base = (height - 1 - r) * 8;
        for (int level : eighths) {
            int cell = std::clamp(level - base, 0, 8);
            plot += cell == 0 ? " " : kBars[cell - 1];
        }
        rows.push_back(hbox({line(axis, kDark), line(plot, chart.color)}));
    }
    return vbox(std::move(rows));
}

struct Ui {
    std::string input, program_input;
    bool focus_program = false, memory_open = true, quit = false, live = true;
    size_t log_top = 0, log_max_top = 0;
    int page = 0, max_page = 0, width = 0, height = 0;
};

Element render(const EngineState& st, Ui& ui) {
    const Snapshot& s = st.snap;
    auto size_now = Terminal::Size();
    int width = size_now.dimx, height = size_now.dimy;
    ui.width = width; ui.height = height;
    if (width < 70 || height < 20) return text("Expand terminal to at least 70 columns x 20 rows. Press Q then Enter to quit.");

    bool show_memory = ui.memory_open && width >= 100;
    int left_width = show_memory ? std::clamp(width * 30 / 100, 34, 42) : std::clamp(width * 46 / 100, 38, 60);
    int middle_width = show_memory ? std::clamp(width * 35 / 100, 32, 60) : 0;  // room for command lines and charts; taken from OUTPUT
    int right_width = width - left_width - 3 - (show_memory ? middle_width + 3 : 0);
    int rows = height - 1;
    std::string state = s.get("state").empty() ? "UNKNOWN" : s.get("state");
    bool tree = s.flag("tree");
    bool guest = s.has("guest_used") && s.has("guest_total");
    double pct = s.num("guest_pct");
    Color memory_color = guest && pct >= 90 ? Color::Red : guest && pct >= 75 ? Color::Yellow : Color::Cyan;
    std::string separator_line = "  " + std::string(std::min(left_width - 2, 40), '-');

    // ---- left column (same rows as the PowerShell dashboard)
    std::vector<std::string> left(std::begin(kLogo), std::end(kLogo));
    left.push_back("  TARGET  " + (s.get("target").empty() ? std::string("?") : s.get("target")) + "  |  " + state);
    left.push_back("  ADDRESS " + (s.get("address").empty() ? std::string("not detected") : s.get("address")));
    left.push_back(separator_line);
    if (guest) left.push_back(fmt("  QNX RAM  %.0f", s.num("guest_used")) + fmt("/%.0f MiB", s.num("guest_total")) + fmt("  %.0f%%", pct));
    else if (st.connected && !s.flag("probe")) left.push_back("  QNX RAM  probe off (P)");
    else left.push_back("  QNX RAM  waiting for pidin...");
    left.push_back(s.has("host_resident") ? fmt("  VM HOST  %.0f MiB resident", s.num("host_resident")) : std::string("  VM HOST  unavailable"));
    left.push_back("  Backend: " + (st.connected ? s.get("backend") : std::string("connecting...")) + (s.has("guest_cpu") ? fmt("  CPU %.1f%%", s.num("guest_cpu")) : std::string()));
    left.push_back(separator_line);
    left.push_back(tree ? std::string("  SRC TREE  Up/Down Enter Esc") : std::string("  PROGRAMS  [") + (s.flag("busy") ? "BUSY" : "READY") + "] (number + Enter)");
    int page_size = std::max(1, height - 22);
    ui.max_page = std::max(0, (static_cast<int>(s.sources.size()) + page_size - 1) / page_size - 1);
    ui.page = std::min(ui.page, ui.max_page);
    if (tree) {
        int cursor = static_cast<int>(s.num("tree_cursor"));
        int start = std::max(0, cursor - page_size + 1);
        for (int i = start; i < std::min(static_cast<int>(s.nodes.size()), start + page_size); ++i) {
            const TreeNode& node = s.nodes[i];
            std::string icon = node.dir ? (node.expanded ? "[-]" : "[+]") : "   ";
            left.push_back(std::string(i == cursor ? ">" : " ") + " " + std::string(node.depth * 2, ' ') + icon + " " + node.name);
        }
        if (s.nodes.empty()) left.push_back("  The src folder is empty");
    } else {
        for (int i = ui.page * page_size; i < std::min(static_cast<int>(s.sources.size()), (ui.page + 1) * page_size); ++i)
            left.push_back("  " + std::to_string(i + 1) + ". " + s.sources[i]);
    }
    while (static_cast<int>(left.size()) < height - 7) left.emplace_back();
    left.push_back(tree ? std::string("  Up/Down move  Enter open  Esc back") : "  Page " + std::to_string(ui.page + 1) + "/" + std::to_string(ui.max_page + 1) + "  <-/-> programs");
    left.push_back(s.flag("recording") ? " T Tree M Panel H pidin G REC S SSH" : " T Tree M Panel H pidin G CSV S SSH");
    left.push_back(tree ? " Enter: open/run .cpp   Esc: back" : " I VM C Cfg P Probe V Tools Q Quit");
    std::string prompt = s.get("prompt").empty() ? "  Select: " : s.get("prompt");
    size_t room = std::max<size_t>(1, left_width - u8len(prompt) - 1);
    std::string prompt_line = prompt + u8tail(ui.input, room);
    left.push_back(prompt_line);
    int prompt_row = std::min(static_cast<int>(left.size()) - 1, rows - 1);

    Elements left_rows;
    for (int row = 0; row < rows; ++row) {
        std::string value = row < static_cast<int>(left.size()) ? left[row] : std::string();
        std::string body = trim(value);
        Color c = kGray;
        if (row < 6) c = Color::Cyan;
        else if (row == 6) c = state == "RUNNING" ? Color::Green : Color::Yellow;
        else if (row == 8 || row == 12) c = kDark;
        else if (row == 9 || row == 10) c = memory_color;
        else if (row == 13 || starts_with(value, "> ")) c = Color::Cyan;
        else if (starts_with(value, "  ") && !body.empty() && std::isdigit(static_cast<unsigned char>(body[0])) && body.find(". ") != std::string::npos) c = Color::White;
        else for (const char* key : {"I VM", "T Tree", "Q Quit", "Select:", "Host/IP", "SSH user", "SSH port", "SSH command", "VM name", "Tree:"})
            if (starts_with(body, key)) { c = Color::Cyan; break; }
        if (row == prompt_row && !ui.focus_program) left_rows.push_back(hbox({line(fit(value, left_width - 1), c), text(" ") | inverted}));
        else left_rows.push_back(line(fit(value, left_width), c));
    }
    auto column_separator = [&] { return hbox({text(" "), separator() | color(kDark), text(" ")}); };
    Elements columns = {vbox(std::move(left_rows)) | size(WIDTH, EQUAL, left_width), column_separator()};

    // ---- middle column: QNX guest, launched program, VM host, and their live charts
    if (show_memory) {
        std::vector<std::variant<Element, ChartSpec>> items;
        auto add = [&](const std::string& value, Color c = kGray) { items.emplace_back(line(fit(value, middle_width), c)); };
        auto add_gauge = [&](const std::string& prefix, double ratio, Color c, const std::string& suffix) {
            int bar = std::max(1, middle_width - static_cast<int>(prefix.size() + suffix.size()) - 1);
            items.emplace_back(hbox({line(prefix, kGray), gauge(static_cast<float>(std::clamp(ratio, 0.0, 1.0))) | color(c) | bgcolor(kDark) | size(WIDTH, EQUAL, bar), line(suffix, c)}));
        };
        // "$ command" lines: the exact command behind the metric above them (wrapped to the column).
        auto command = [&](const std::string& value) {
            size_t room = static_cast<size_t>(std::max(8, middle_width - 4));
            auto pieces = wrap_words(value, room);
            for (size_t i = 0; i < pieces.size() && !value.empty(); ++i) add((i == 0 ? " $ " : "   ") + pieces[i], kDark);
        };
        add(" QNX GUEST  pidin/top via SSH", Color::Cyan);
        if (s.flag("recording")) add(" [REC] CSV recording active", Color::Red); else add(" -----------------------------");
        if (st.connected && !s.flag("probe")) { add(" Probe OFF: host-only mode"); add(" P + Enter to enable"); }
        else if (guest) {
            command(s.get("cmd_ssh"));
            add(fmt(" RAM %.0f", s.num("guest_used")) + fmt("/%.0f MiB", s.num("guest_total")) + fmt("  %.1f%%", pct));
            add_gauge(" ram  ", pct / 100.0, memory_color, fmt(" %5.1f%%", pct));
            command(s.get("cmd_ram"));
            for (const auto& core : s.cores) add_gauge(" cpu" + core.first + " ", core.second / 100.0, load_color(core.second), fmt(" %5.1f%%", core.second));
            if (!s.cores.empty()) command(s.get("cmd_cpu"));
            add(" Visible procs " + s.get("guest_procs") + "  threads " + s.get("guest_threads"));
            command(s.get("cmd_procs"));
            if (!s.hist.empty()) items.emplace_back(dynamic_chart("QNX RAM used MiB", s.hist, 4, 0, memory_color));
            if (!s.hist_cpu.empty()) items.emplace_back(percent_chart("QNX CPU busy %", s.hist_cpu, Color::Green));
        } else add(" Waiting for guest sample...");
        if (s.flag("program_active")) {
            add(" PROGRAM (pidin mem)", Color::Cyan);
            command(s.get("cmd_program"));
            if (s.has("program_pid")) {
                add(" pid " + s.get("program_pid"));
                add(" data " + s.get("program_data") + "  heap " + s.get("program_heap"));
                add(" peak data " + s.get("program_peak_data") + "  heap " + s.get("program_peak_heap"));
            } else add(s.flag("probe") ? " waiting for pidin..." : " needs guest probe (P)");
        }
        add("");
        add(" VM HOST  hypervisor process", Color::Cyan);
        add(" -----------------------------");
        if (s.has("host_resident")) {
            add(fmt(" Resident %.0f MiB", s.num("host_resident")));
            if (s.has("host_delta")) {
                double delta = std::round(s.num("host_delta"));
                add(" Since start " + (delta == 0 ? std::string("0") : fmt("%+.0f", delta)) + fmt("  peak %.0f MiB", s.num("host_peak")));
            }
            command(s.get("cmd_host"));
            if (!s.hist_host.empty()) items.emplace_back(dynamic_chart("VM host resident MiB", s.hist_host, 2, 1, Color::Magenta));
        } else add(" Unavailable");
        add(s.flag("recording") ? " G stop CSV  P guest probe" : " G record CSV  P guest probe");

        // Charts share the free rows of the column. When space is short, drop the host chart, then CPU, then RAM.
        auto is_chart = [](const std::variant<Element, ChartSpec>& item) { return std::holds_alternative<ChartSpec>(item); };
        int chart_height = 0;
        for (;;) {
            int charts = static_cast<int>(std::count_if(items.begin(), items.end(), is_chart));
            int free = rows - static_cast<int>(items.size());  // every item uses one row; a chart's row is its title
            if (charts == 0) break;
            if (free >= 3 * charts) { chart_height = std::min(14, free / charts); break; }
            auto last = std::find_if(items.rbegin(), items.rend(), is_chart);
            items.erase(std::next(last).base());
        }
        Elements middle;
        for (auto& item : items) {
            if (auto* chart = std::get_if<ChartSpec>(&item)) middle.push_back(chart_element(*chart, middle_width, chart_height));
            else middle.push_back(std::get<Element>(item));
        }
        columns.push_back(vbox(std::move(middle)) | size(WIDTH, EQUAL, middle_width));
        columns.push_back(column_separator());
    }

    // ---- right column: live output with scrollback and the program input line
    bool interactive = s.flag("interactive");
    std::vector<std::pair<std::string, Color>> wrapped;
    for (const auto& entry : st.log)
        for (auto& piece : wrap(entry.text, right_width)) wrapped.emplace_back(std::move(piece), log_color(entry.kind));
    if (interactive && !s.get("partial").empty())
        for (auto& piece : wrap(s.get("partial"), right_width)) wrapped.emplace_back(std::move(piece), Color::White);
    int visible_rows = std::max(0, rows - 2 - (interactive ? 1 : 0));
    ui.log_max_top = wrapped.size() > static_cast<size_t>(visible_rows) ? wrapped.size() - visible_rows : 0;
    if (!ui.live) ui.log_top = std::min(ui.log_top, ui.log_max_top);
    size_t start = ui.live ? ui.log_max_top : ui.log_top;
    Elements right = {line(ui.live ? " OUTPUT [LIVE]   Up/PgUp: history" : " OUTPUT [PAUSED] End: live", Color::Cyan),
                      line(std::string(std::min(right_width, 40), '-'), Color::Cyan)};
    for (size_t i = start; i < std::min(wrapped.size(), start + visible_rows); ++i) right.push_back(line(wrapped[i].first, wrapped[i].second));
    if (interactive) {
        while (static_cast<int>(right.size()) < rows - 1) right.push_back(text(""));
        std::string prefix = ui.focus_program ? " INPUT > " : " [Tab] input > ";
        std::string value = u8take(prefix + u8tail(ui.program_input, std::max<size_t>(1, right_width - prefix.size() - 1)), right_width - 1);
        Elements input = {line(value, Color::Cyan)};
        if (ui.focus_program) input.push_back(text(" ") | inverted);
        right.push_back(hbox(std::move(input)));
    }
    columns.push_back(vbox(std::move(right)) | size(WIDTH, EQUAL, right_width));

    std::string status = st.connected ? " FTXUI front end  |  engine: menu.ps1 -Serve  |  Ctrl+C quits" : " FTXUI front end  |  starting engine (menu.ps1 -Serve)...";
    return vbox({hbox(std::move(columns)) | size(HEIGHT, EQUAL, rows), line(u8take(status, width), kDark)});
}

// ---- keys (same as the dashboard)
void submit(Ui& ui, Engine& engine, const Snapshot& s) {
    std::string value = trim(ui.input);
    ui.input.clear();
    std::string mode = s.get("mode");
    if (mode.empty() || mode == "command") {
        std::string key = upper(value);
        if (key.empty()) return;
        if (key == "M") { ui.memory_open = !ui.memory_open; return; }
        if (key == "[") { ui.page = std::max(0, ui.page - 1); return; }
        if (key == "]") { ui.page = std::min(ui.max_page, ui.page + 1); return; }
        if (key == "Q") { ui.quit = true; return; }
    }
    engine.send("submit", value);
    ui.live = true;
}

void handle(const Event& event, Ui& ui, Engine& engine, const Snapshot& s) {
    if (event == Event::CtrlC) { ui.quit = true; return; }
    size_t page = static_cast<size_t>(std::max(1, ui.height - 4));
    bool tree = s.flag("tree");
    if (event == Event::Tab) {
        if (ui.focus_program) ui.focus_program = false;
        else if (s.flag("interactive") && !tree) { ui.focus_program = true; ui.live = true; }
        return;
    }
    if (ui.focus_program) {
        if (event == Event::Return) { engine.send("program", ui.program_input); ui.program_input.clear(); ui.live = true; }
        else if (event == Event::Backspace) { if (!ui.program_input.empty()) ui.program_input = u8take(ui.program_input, u8len(ui.program_input) - 1); }
        else if (event.is_character() && ui.program_input.size() < 2048) ui.program_input += event.character();
        return;
    }
    if (tree) {
        if (event == Event::Return) engine.send("tree", "enter");
        else if (event == Event::ArrowUp) engine.send("tree", "up");
        else if (event == Event::ArrowDown) engine.send("tree", "down");
        else if (event == Event::ArrowLeft) engine.send("tree", "left");
        else if (event == Event::ArrowRight) engine.send("tree", "right");
        else if (event == Event::Escape) engine.send("tree", "esc");
        return;
    }
    bool command_mode = s.get("mode").empty() || s.get("mode") == "command";
    auto pause_at = [&](size_t top) { ui.live = false; ui.log_top = top; };
    if (event == Event::Return) submit(ui, engine, s);
    else if (event == Event::ArrowUp) pause_at((ui.live ? ui.log_max_top : ui.log_top) > 0 ? (ui.live ? ui.log_max_top : ui.log_top) - 1 : 0);
    else if (event == Event::ArrowDown) { if (!ui.live) { if (ui.log_top + 1 >= ui.log_max_top) ui.live = true; else ++ui.log_top; } }
    else if (event == Event::PageUp) { size_t top = ui.live ? ui.log_max_top : ui.log_top; pause_at(top > page ? top - page : 0); }
    else if (event == Event::PageDown) { if (!ui.live) { if (ui.log_top + page >= ui.log_max_top) ui.live = true; else ui.log_top += page; } }
    else if (event == Event::End) ui.live = true;
    else if (event == Event::ArrowLeft && command_mode) ui.page = std::max(0, ui.page - 1);
    else if (event == Event::ArrowRight && command_mode) ui.page = std::min(ui.max_page, ui.page + 1);
    else if (event == Event::Backspace) { if (!ui.input.empty()) ui.input = u8take(ui.input, u8len(ui.input) - 1); }
    else if (event == Event::Escape) { ui.input.clear(); engine.send("escape"); }
    else if (event.is_character() && ui.input.size() < 2048) ui.input += event.character();
}
}  // namespace

int main() {
    Engine engine;
    auto state = engine.state();
    auto screen = ScreenInteractive::Fullscreen();
    screen.TrackMouse(false);       // keep the terminal's own text selection, like the dashboard
    screen.ForceHandleCtrlC(false); // Ctrl+C is handled below so the engine is stopped cleanly
    {
        std::lock_guard<std::mutex> lock(state->mu);
        state->notify = [&screen] { screen.PostEvent(Event::Custom); };
    }
    std::string error;
    if (!engine.start(error)) {
        std::cerr << "Could not start menu.ps1 -Serve (" << menu_script() << "): " << error << "\n";
        return 1;
    }
    Ui ui;
    bool closed = false;
    auto renderer = Renderer([&] {
        std::lock_guard<std::mutex> lock(state->mu);
        if (!state->snap.flag("interactive")) { ui.focus_program = false; ui.program_input.clear(); }
        return render(*state, ui);
    });
    auto component = CatchEvent(renderer, [&](Event event) {
        if (event.is_mouse()) return false;
        Snapshot snapshot;
        {
            std::lock_guard<std::mutex> lock(state->mu);
            closed = state->closed;
            snapshot = state->snap;
        }
        if (event != Event::Custom) handle(event, ui, engine, snapshot);
        if (ui.quit || closed) screen.Exit();
        return true;
    });
    screen.Loop(component);
    engine.stop();
    if (closed && !ui.quit) {
        std::lock_guard<std::mutex> lock(state->mu);
        std::cerr << "The engine (menu.ps1 -Serve) stopped. Last messages:\n";
        size_t from = state->log.size() > 6 ? state->log.size() - 6 : 0;
        for (size_t i = from; i < state->log.size(); ++i) std::cerr << "  " << state->log[i].text << "\n";
    }
    return 0;
}

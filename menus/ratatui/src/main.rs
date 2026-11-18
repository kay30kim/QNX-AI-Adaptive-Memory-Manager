//! Ratatui front end for the QNX Control Center.
//! Same layout and keys as the PowerShell dashboard (menu.ps1). The logic (VM discovery,
//! guest/host telemetry, build + upload + run, SSH, CSV) runs in `menu.ps1 -Serve`; this
//! program renders its state frames and sends it commands over stdin/stdout.
use std::{
    collections::{HashMap, VecDeque},
    env,
    io::{self, BufRead, BufReader, Read, Write},
    path::PathBuf,
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Sender},
    thread,
    time::{Duration, Instant},
};

use crossterm::{
    event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{
    backend::CrosstermBackend,
    layout::Rect,
    style::{Color, Style},
    text::{Line, Span},
    widgets::{Gauge, Paragraph, Sparkline},
    Frame, Terminal,
};

const LOG_LIMIT: usize = 2000;
const LOGO: [&str; 6] = ["    ___  _   _ __  __", "   / _ \\| \\ | |\\ \\/ /", "  | | | |  \\| | \\  /", "  | |_| | |\\  | /  \\", "   \\__\\_\\_| \\_|/_/\\_\\", "  CONTROL CENTER"];

/// Finds menu.ps1: QNX_ROOT, then the executable's directory and its parents, then the current directory.
fn menu_script() -> PathBuf {
    if let Some(root) = env::var_os("QNX_ROOT") {
        let p = PathBuf::from(root).join("menu.ps1");
        if p.is_file() { return p; }
    }
    if let Ok(exe) = env::current_exe() {
        for dir in exe.ancestors().skip(1) {
            let p = dir.join("menu.ps1");
            if p.is_file() { return p; }
        }
    }
    PathBuf::from("menu.ps1")
}

// ---------------------------------------------------------------- engine protocol

#[derive(Clone)]
struct Node { depth: usize, dir: bool, expanded: bool, name: String }

#[derive(Default, Clone)]
struct Snapshot {
    fields: HashMap<String, String>,
    cores: Vec<(String, f64)>,
    hist: Vec<f64>,
    hist_cpu: Vec<f64>,
    hist_host: Vec<f64>,
    nodes: Vec<Node>,
    sources: Vec<String>,
}
impl Snapshot {
    fn get(&self, key: &str) -> &str { self.fields.get(key).map(String::as_str).unwrap_or("") }
    fn flag(&self, key: &str) -> bool { self.get(key) == "1" }
    fn num(&self, key: &str) -> Option<f64> { self.fields.get(key).and_then(|v| v.parse().ok()) }
    fn add(&mut self, line: &str) {
        let (key, value) = line.split_once('\t').unwrap_or((line, ""));
        match key {
            "core" => if let Some((id, busy)) = value.split_once('\t') { self.cores.push((id.to_owned(), busy.parse().unwrap_or(0.0))); },
            "hist" => self.hist = value.split_whitespace().filter_map(|v| v.parse().ok()).collect(),
            "hist_cpu" => self.hist_cpu = value.split_whitespace().filter_map(|v| v.parse().ok()).collect(),
            "hist_host" => self.hist_host = value.split_whitespace().filter_map(|v| v.parse().ok()).collect(),
            "src" => self.sources.push(value.to_owned()),
            "node" => {
                let parts: Vec<&str> = value.splitn(4, '\t').collect();
                if parts.len() == 4 {
                    self.nodes.push(Node { depth: parts[0].parse().unwrap_or(0), dir: parts[1] == "1", expanded: parts[2] == "1", name: parts[3].to_owned() });
                }
            }
            _ => { self.fields.insert(key.to_owned(), value.to_owned()); }
        }
    }
}

enum Message { Frame(Snapshot), Log(String, String), Closed }

struct Engine { child: Child, stdin: Option<ChildStdin> }
impl Engine {
    fn start(tx: Sender<Message>) -> io::Result<Engine> {
        let mut command = Command::new("powershell.exe");
        command.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]).arg(menu_script()).arg("-Serve")
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        #[cfg(windows)]
        { use std::os::windows::process::CommandExt; command.creation_flags(0x0800_0000); } // CREATE_NO_WINDOW
        let mut child = command.spawn()?;
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        let out_tx = tx.clone();
        thread::spawn(move || {
            let mut current: Option<Snapshot> = None;
            for raw in BufReader::new(stdout).split(b'\n') {
                let Ok(raw) = raw else { break };
                let text = String::from_utf8_lossy(&raw);
                let line = text.trim_end_matches('\r');
                if line == "@@FRAME" { current = Some(Snapshot::default()); }
                else if line == "@@END" { if let Some(s) = current.take() { if out_tx.send(Message::Frame(s)).is_err() { break; } } }
                else if let Some(rest) = line.strip_prefix("@@LOG\t") {
                    let (kind, body) = rest.split_once('\t').unwrap_or(("text", rest));
                    if out_tx.send(Message::Log(kind.to_owned(), body.to_owned())).is_err() { break; }
                } else if let Some(s) = current.as_mut() { s.add(line); }
            }
            let _ = out_tx.send(Message::Closed);
        });
        thread::spawn(move || {
            let mut text = String::new();
            let _ = BufReader::new(stderr).read_to_string(&mut text);
            for line in text.lines().filter(|l| !l.trim().is_empty()) { let _ = tx.send(Message::Log("err".into(), line.to_owned())); }
        });
        let stdin = child.stdin.take();
        Ok(Engine { child, stdin })
    }
    fn send(&mut self, verb: &str, argument: &str) {
        if let Some(stdin) = self.stdin.as_mut() {
            let clean: String = argument.chars().map(|c| if c == '\t' || c == '\r' || c == '\n' { ' ' } else { c }).collect();
            let _ = writeln!(stdin, "{verb}\t{clean}");
            let _ = stdin.flush();
        }
    }
    /// Asks the engine to quit (it stops its SSH sessions), then kills it if it does not exit.
    fn stop(&mut self) {
        self.send("quit", "");
        self.stdin = None;
        let deadline = Instant::now() + Duration::from_secs(4);
        while Instant::now() < deadline {
            if let Ok(Some(_)) = self.child.try_wait() { return; }
            thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
    }
}

// ---------------------------------------------------------------- UI state

struct App {
    snap: Snapshot,
    connected: bool,
    closed: bool,
    quit: bool,
    log: VecDeque<(String, String)>,
    log_top: Option<usize>,
    log_max_top: usize,
    input: String,
    program_input: String,
    focus_program: bool,
    memory_open: bool,
    page: usize,
    max_page: usize,
    height: usize,
    width: usize,
}
impl App {
    fn add_log(&mut self, kind: &str, text: &str) {
        self.log.push_back((kind.to_owned(), text.to_owned()));
        while self.log.len() > LOG_LIMIT { self.log.pop_front(); }
    }
}

fn fit(text: &str, width: usize) -> String {
    if text.chars().count() > width { text.chars().take(width.saturating_sub(1)).chain(std::iter::once('~')).collect() } else { text.to_owned() }
}
fn cut(text: &str, width: usize) -> String { text.chars().take(width).collect() }
/// Wraps text to `width` characters, breaking at spaces when possible.
fn wrap_words(text: &str, width: usize) -> Vec<String> {
    let mut lines = Vec::new();
    let mut rest: Vec<char> = text.chars().collect();
    while !rest.is_empty() {
        let mut take = rest.len();
        if take > width {
            take = rest[..=width].iter().rposition(|&c| c == ' ').filter(|&p| p > 0).unwrap_or(width);
        }
        lines.push(rest[..take].iter().collect());
        rest = rest[take..].iter().skip_while(|&&c| c == ' ').cloned().collect();
    }
    lines
}
fn styled(text: String, color: Color) -> Line<'static> { Line::from(Span::styled(text, Style::default().fg(color))) }
fn log_color(kind: &str) -> Color {
    match kind { "cmd" => Color::Magenta, "err" => Color::Red, "ok" => Color::Green, "input" => Color::White, _ => Color::Gray }
}

enum Middle { Text(String, Color), Gauge { prefix: String, ratio: f64, color: Color, suffix: String }, Chart(Chart) }

fn load_color(busy: f64) -> Color { if busy >= 85.0 { Color::Red } else if busy >= 50.0 { Color::Yellow } else { Color::Green } }

/// A live chart: multi-row bars (8 levels per row) with a labelled Y axis; newest sample on the right.
struct Chart { title: String, values: Vec<f64>, low: f64, high: f64, min_span: Option<f64>, decimals: usize, color: Color }
impl Chart {
    /// Dynamic Y axis: follows the min/max of the visible samples (plus a margin), so small changes show.
    /// `min_span` keeps flat data from being magnified into noise.
    fn dynamic(title: &str, values: &[f64], min_span: f64, decimals: usize, color: Color) -> Chart {
        Chart { title: title.into(), values: values.to_vec(), low: 0.0, high: 0.0, min_span: Some(min_span), decimals, color }
    }
    /// 0..N% axis, N rounded up to a multiple of 10 (at least 10).
    fn percent(title: &str, values: &[f64], color: Color) -> Chart {
        let max = values.iter().cloned().fold(0.0, f64::max);
        Chart { title: title.into(), values: values.to_vec(), low: 0.0, high: ((max / 10.0).ceil() * 10.0).clamp(10.0, 100.0), min_span: None, decimals: 1, color }
    }
    fn scale(&self, visible: &[f64]) -> (f64, f64) {
        let Some(min_span) = self.min_span else { return (self.low, self.high) };
        let min = visible.iter().cloned().fold(f64::MAX, f64::min);
        let max = visible.iter().cloned().fold(f64::MIN, f64::max);
        let (mut low, mut high) = (min, max);
        if high - low < min_span { let mid = (min + max) / 2.0; low = mid - min_span / 2.0; high = mid + min_span / 2.0; }
        let pad = (high - low) * 0.15;
        ((low - pad).max(0.0), high + pad)
    }
}

/// Samples per chart column: 2 samples (~1 s at 2 Hz) per column doubles the visible time window.
const SAMPLES_PER_COLUMN: usize = 2;

/// Groups the newest samples into at most `max_columns` columns (newest last); each column
/// shows the highest of its samples, so short peaks stay visible.
fn columns(values: &[f64], max_columns: usize) -> Vec<f64> {
    let take = (max_columns * SAMPLES_PER_COLUMN).min(values.len());
    let mut columns: Vec<f64> = values[values.len() - take..].rchunks(SAMPLES_PER_COLUMN)
        .map(|chunk| chunk.iter().cloned().fold(f64::MIN, f64::max)).collect();
    columns.reverse();
    columns
}

fn render_chart(f: &mut Frame, chart: &Chart, area: Rect) {
    let width = area.width as usize;
    let height = area.height.saturating_sub(1) as usize;
    let last = chart.values.last().copied().unwrap_or(0.0);
    let title = format!(" {}  now {:.*}", chart.title, chart.decimals, last);
    f.render_widget(Paragraph::new(styled(fit(&title, width), chart.color)), Rect::new(area.x, area.y, area.width, 1));
    if height == 0 || chart.values.is_empty() { return; }
    // Scale from the columns that fit (axis labels are at most ~7 characters wide).
    let (low, high) = chart.scale(&columns(&chart.values, width.saturating_sub(10).max(1)));
    let digits = if chart.min_span.is_some() && high - low < 20.0 { 1 } else { 0 };
    let label = |v: f64| format!("{v:.digits$}");
    let mid_row = if height >= 5 { Some(height / 2) } else { None };
    let labels: Vec<String> = (0..height).map(|r| {
        if r == 0 { label(high) }
        else if r == height - 1 { label(low) }
        else if Some(r) == mid_row { label(high - (high - low) * r as f64 / (height - 1) as f64) }
        else { String::new() }
    }).collect();
    let label_width = labels.iter().map(String::len).max().unwrap_or(1);
    let axis: Vec<Line> = labels.iter().map(|text| {
        let tick = if text.is_empty() { '│' } else { '┤' };
        styled(format!(" {text:>label_width$}{tick}"), Color::DarkGray)
    }).collect();
    let axis_width = label_width + 2;
    f.render_widget(Paragraph::new(axis), Rect::new(area.x, area.y + 1, axis_width as u16, height as u16));
    let plot_width = width.saturating_sub(axis_width + 1);
    let visible = columns(&chart.values, plot_width);
    let count = visible.len();
    if count == 0 { return; }
    let span = (high - low).max(f64::EPSILON);
    let floor = (1000 / (8 * height as u64)).max(1); // the lowest value still shows one eighth of a row
    let data: Vec<u64> = visible.iter()
        .map(|v| ((((v - low) / span).clamp(0.0, 1.0) * 1000.0) as u64).max(floor)).collect();
    let plot = Rect::new(area.x + (axis_width + plot_width - count) as u16, area.y + 1, count as u16, height as u16);
    f.render_widget(Sparkline::default().data(&data).max(1000).style(Style::default().fg(chart.color)), plot);
}


fn draw(f: &mut Frame, app: &mut App) {
    let area = f.area();
    let (width, height) = (area.width as usize, area.height as usize);
    app.width = width; app.height = height;
    if width < 70 || height < 20 {
        f.render_widget(Paragraph::new("Expand terminal to at least 70 columns x 20 rows. Press Q then Enter to quit."), area);
        return;
    }
    let s = &app.snap;
    let show_memory = app.memory_open && width >= 100;
    let left_width = if show_memory { (width * 30 / 100).clamp(34, 42) } else { (width * 46 / 100).clamp(38, 60) };
    let middle_width = if show_memory { (width * 35 / 100).clamp(32, 60) } else { 0 }; // room for command lines and charts; taken from OUTPUT
    let right_width = width - left_width - 3 - if show_memory { middle_width + 3 } else { 0 };
    let separator_line = format!("  {}", "-".repeat((left_width - 2).min(40)));
    let rows = height - 1;
    let state = if s.get("state").is_empty() { "UNKNOWN" } else { s.get("state") };
    let tree = s.flag("tree");
    let guest = s.num("guest_used").zip(s.num("guest_total")).zip(s.num("guest_pct"));
    let memory_color = match s.num("guest_pct") { Some(p) if p >= 90.0 => Color::Red, Some(p) if p >= 75.0 => Color::Yellow, _ => Color::Cyan };

    // ---- left column (same rows as the PowerShell dashboard)
    let mut left: Vec<String> = LOGO.iter().map(|l| l.to_string()).collect();
    left.push(format!("  TARGET  {}  |  {}", if s.get("target").is_empty() { "?" } else { s.get("target") }, state));
    left.push(format!("  ADDRESS {}", if s.get("address").is_empty() { "not detected" } else { s.get("address") }));
    left.push(separator_line.clone());
    left.push(match guest {
        Some(((used, total), pct)) => format!("  QNX RAM  {used:.0}/{total:.0} MiB  {pct:.0}%"),
        None if app.connected && !s.flag("probe") => "  QNX RAM  probe off (P)".into(),
        None => "  QNX RAM  waiting for pidin...".into(),
    });
    left.push(match s.num("host_resident") { Some(r) => format!("  VM HOST  {r:.0} MiB resident"), None => "  VM HOST  unavailable".into() });
    let cpu = s.num("guest_cpu").map(|c| format!("  CPU {c:.1}%")).unwrap_or_default();
    left.push(format!("  Backend: {}{}", if app.connected { s.get("backend") } else { "connecting..." }, cpu));
    left.push(separator_line);
    left.push(if tree { "  SRC TREE  Up/Down Enter Esc".into() } else if s.flag("busy") { "  PROGRAMS  [BUSY] K/Ctrl+C: stop".into() } else { "  PROGRAMS  [READY] (number + Enter)".into() });
    let page_size = height.saturating_sub(22).max(1);
    app.max_page = s.sources.len().div_ceil(page_size).saturating_sub(1);
    app.page = app.page.min(app.max_page);
    if tree {
        let cursor: usize = s.get("tree_cursor").parse().unwrap_or(0);
        let start = (cursor + 1).saturating_sub(page_size);
        for (i, node) in s.nodes.iter().enumerate().skip(start).take(page_size) {
            let icon = if node.dir { if node.expanded { "[-]" } else { "[+]" } } else { "   " };
            left.push(format!("{} {}{} {}", if i == cursor { '>' } else { ' ' }, "  ".repeat(node.depth), icon, node.name));
        }
        if s.nodes.is_empty() { left.push("  The src folder is empty".into()); }
    } else {
        for (i, source) in s.sources.iter().enumerate().skip(app.page * page_size).take(page_size) { left.push(format!("  {}. {}", i + 1, source)); }
    }
    while left.len() < height - 7 { left.push(String::new()); }
    left.push(if tree { "  Up/Down move  Enter open  Esc back".into() } else { format!("  Page {}/{}  <-/-> programs", app.page + 1, app.max_page + 1) });
    left.push(if s.flag("recording") { " T Tree M Panel H pidin G REC S SSH".into() } else { " T Tree M Panel H pidin G CSV S SSH".into() });
    left.push(if tree { "  Enter: open/run .cpp   Esc: back".into() } else { " I VM C Cfg P Probe V Tools Q Quit".into() });
    let prompt = if s.get("prompt").is_empty() { "  Select: " } else { s.get("prompt") };
    let room = left_width.saturating_sub(prompt.chars().count()).max(1);
    let typed = app.input.chars().count();
    let visible: String = app.input.chars().skip(typed.saturating_sub(room)).collect();
    left.push(format!("{prompt}{visible}"));
    let prompt_row = (left.len() - 1).min(rows - 1);

    let left_lines: Vec<Line> = left.iter().take(rows).enumerate().map(|(row, text)| {
        let color = match row {
            0..=5 => Color::Cyan,
            6 => if state == "RUNNING" { Color::Green } else { Color::Yellow },
            7 => Color::Gray,
            8 | 12 => Color::DarkGray,
            9 | 10 => memory_color,
            13 => Color::Cyan,
            _ if text.starts_with("> ") => Color::Cyan,
            _ if text.trim_start().split('.').next().is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit())) && text.starts_with("  ") => Color::White,
            _ if ["I VM", "T Tree", "Q Quit", "Select:", "Host/IP", "SSH user", "SSH port", "SSH command", "VM name", "Tree:"].iter().any(|k| text.trim_start().starts_with(k)) => Color::Cyan,
            _ => Color::Gray,
        };
        styled(fit(text, left_width), color)
    }).collect();
    f.render_widget(Paragraph::new(left_lines), Rect::new(0, 0, left_width as u16, rows as u16));

    let separator: Vec<Line> = (0..rows).map(|_| styled(" │ ".into(), Color::DarkGray)).collect();
    f.render_widget(Paragraph::new(separator.clone()), Rect::new(left_width as u16, 0, 3, rows as u16));
    let mut right_x = left_width + 3;

    // ---- middle column: QNX guest, launched program, VM host, and their live charts
    if show_memory {
        // "$ command" lines: the exact command behind the metric above them (wrapped to the column).
        let command = |middle: &mut Vec<Middle>, text: &str| {
            for (i, piece) in wrap_words(text, middle_width.saturating_sub(4).max(8)).into_iter().enumerate() {
                middle.push(Middle::Text(format!("{}{piece}", if i == 0 { " $ " } else { "   " }), Color::DarkGray));
            }
        };
        let mut middle: Vec<Middle> = vec![Middle::Text(" QNX GUEST  pidin/top via SSH".into(), Color::Cyan)];
        middle.push(if s.flag("recording") { Middle::Text(" [REC] CSV recording active".into(), Color::Red) } else { Middle::Text(" -----------------------------".into(), Color::Gray) });
        if app.connected && !s.flag("probe") {
            middle.push(Middle::Text(" Probe OFF: host-only mode".into(), Color::Gray));
            middle.push(Middle::Text(" P + Enter to enable".into(), Color::Gray));
        } else if let Some(((used, total), pct)) = guest {
            command(&mut middle, s.get("cmd_ssh"));
            middle.push(Middle::Text(format!(" RAM {used:.0}/{total:.0} MiB  {pct:.1}%"), Color::Gray));
            middle.push(Middle::Gauge { prefix: " ram  ".into(), ratio: pct / 100.0, color: memory_color, suffix: format!(" {pct:>5.1}%") });
            command(&mut middle, s.get("cmd_ram"));
            for (id, busy) in &s.cores {
                middle.push(Middle::Gauge { prefix: format!(" cpu{id} "), ratio: busy / 100.0, color: load_color(*busy), suffix: format!(" {busy:>5.1}%") });
            }
            if !s.cores.is_empty() { command(&mut middle, s.get("cmd_cpu")); }
            middle.push(Middle::Text(format!(" Visible procs {}  threads {}", s.get("guest_procs"), s.get("guest_threads")), Color::Gray));
            command(&mut middle, s.get("cmd_procs"));
            if !s.hist.is_empty() { middle.push(Middle::Chart(Chart::dynamic("QNX RAM used MiB", &s.hist, 4.0, 0, memory_color))); }
            if !s.hist_cpu.is_empty() { middle.push(Middle::Chart(Chart::percent("QNX CPU busy %", &s.hist_cpu, Color::Green))); }
        } else {
            middle.push(Middle::Text(" Waiting for guest sample...".into(), Color::Gray));
        }
        if s.flag("program_active") {
            middle.push(Middle::Text(" PROGRAM (pidin mem)".into(), Color::Cyan));
            command(&mut middle, s.get("cmd_program"));
            if !s.get("program_pid").is_empty() {
                middle.push(Middle::Text(format!(" pid {}", s.get("program_pid")), Color::Gray));
                middle.push(Middle::Text(format!(" data {}  heap {}", s.get("program_data"), s.get("program_heap")), Color::Gray));
                middle.push(Middle::Text(format!(" peak data {}  heap {}", s.get("program_peak_data"), s.get("program_peak_heap")), Color::Gray));
            } else if s.flag("probe") {
                middle.push(Middle::Text(" waiting for pidin...".into(), Color::Gray));
            } else {
                middle.push(Middle::Text(" needs guest probe (P)".into(), Color::Gray));
            }
        }
        middle.push(Middle::Text(String::new(), Color::Gray));
        middle.push(Middle::Text(" VM HOST  hypervisor process".into(), Color::Cyan));
        middle.push(Middle::Text(" -----------------------------".into(), Color::Gray));
        if let Some(resident) = s.num("host_resident") {
            middle.push(Middle::Text(format!(" Resident {resident:.0} MiB"), Color::Gray));
            if let (Some(delta), Some(peak)) = (s.num("host_delta"), s.num("host_peak")) {
                let delta = delta.round(); let delta = if delta == 0.0 { "0".to_string() } else { format!("{delta:+.0}") };
                middle.push(Middle::Text(format!(" Since start {delta}  peak {peak:.0} MiB"), Color::Gray));
            }
            command(&mut middle, s.get("cmd_host"));
            if !s.hist_host.is_empty() { middle.push(Middle::Chart(Chart::dynamic("VM host resident MiB", &s.hist_host, 2.0, 1, Color::Magenta))); }
        } else {
            middle.push(Middle::Text(" Unavailable".into(), Color::Gray));
        }
        middle.push(Middle::Text(if s.flag("recording") { " G stop CSV  P guest probe".into() } else { " G record CSV  P guest probe".into() }, Color::Gray));

        // Charts share the free rows of the column. When space is short, drop the host chart, then CPU, then RAM.
        let mut chart_height = 0;
        loop {
            let charts = middle.iter().filter(|m| matches!(m, Middle::Chart(_))).count();
            let free = rows.saturating_sub(middle.len()); // every item uses one row; a chart's row is its title
            if charts == 0 { break; }
            if free >= 3 * charts { chart_height = (free / charts).min(14); break; }
            if let Some(i) = middle.iter().rposition(|m| matches!(m, Middle::Chart(_))) { middle.remove(i); }
        }
        let x = right_x as u16;
        let mut row = 0usize;
        for item in middle {
            if row >= rows { break; }
            match item {
                Middle::Text(text, color) => f.render_widget(Paragraph::new(styled(fit(&text, middle_width), color)), Rect::new(x, row as u16, middle_width as u16, 1)),
                Middle::Gauge { prefix, ratio, color, suffix } => {
                    let bar = middle_width.saturating_sub(prefix.len() + suffix.len() + 1);
                    f.render_widget(Paragraph::new(styled(prefix.clone(), Color::Gray)), Rect::new(x, row as u16, prefix.len() as u16, 1));
                    f.render_widget(
                        Gauge::default().ratio(ratio.clamp(0.0, 1.0)).label("").use_unicode(true).gauge_style(Style::default().fg(color).bg(Color::DarkGray)),
                        Rect::new(x + prefix.len() as u16, row as u16, bar as u16, 1));
                    f.render_widget(Paragraph::new(styled(suffix.clone(), color)), Rect::new(x + (prefix.len() + bar) as u16, row as u16, suffix.len() as u16, 1));
                }
                Middle::Chart(chart) => {
                    let height = chart_height.min(rows - row - 1);
                    render_chart(f, &chart, Rect::new(x, row as u16, middle_width as u16, (height + 1) as u16));
                    row += height;
                }
            }
            row += 1;
        }
        f.render_widget(Paragraph::new(separator), Rect::new((right_x + middle_width) as u16, 0, 3, rows as u16));
        right_x += middle_width + 3;
    }

    // ---- right column: live output with scrollback and the program input line
    let interactive = s.flag("interactive");
    let mut wrapped: Vec<(String, Color)> = Vec::new();
    let mut push_wrapped = |text: &str, color: Color| {
        let chars: Vec<char> = text.chars().collect();
        if chars.is_empty() { wrapped.push((String::new(), color)); }
        for chunk in chars.chunks(right_width.max(1)) { wrapped.push((chunk.iter().collect(), color)); }
    };
    for (kind, text) in &app.log { push_wrapped(text, log_color(kind)); }
    if interactive && !s.get("partial").is_empty() { push_wrapped(s.get("partial"), Color::White); }
    let input_rows = usize::from(interactive);
    let visible_rows = rows.saturating_sub(2 + input_rows);
    app.log_max_top = wrapped.len().saturating_sub(visible_rows);
    let start = match app.log_top { Some(top) => { let top = top.min(app.log_max_top); app.log_top = Some(top); top } None => app.log_max_top };
    let mut right: Vec<Line> = vec![
        styled(if app.log_top.is_none() { " OUTPUT [LIVE]   Up/PgUp: history".into() } else { " OUTPUT [PAUSED] End: live".into() }, Color::Cyan),
        styled("-".repeat(right_width.min(40)), Color::Cyan),
    ];
    for (text, color) in wrapped.iter().skip(start).take(visible_rows) { right.push(styled(text.clone(), *color)); }
    let mut cursor = (prompt_row, (prompt.chars().count() + visible.chars().count()).min(left_width - 1));
    if interactive {
        while right.len() < rows - 1 { right.push(Line::default()); }
        let prefix = if app.focus_program { " INPUT > " } else { " [Tab] input > " };
        let room = right_width.saturating_sub(prefix.len()).max(1);
        let count = app.program_input.chars().count();
        let tail: String = app.program_input.chars().skip(count.saturating_sub(room)).collect();
        let text = cut(&format!("{prefix}{tail}"), right_width);
        if app.focus_program { cursor = (rows - 1, right_x + text.chars().count()); }
        right.push(styled(text, Color::Cyan));
    }
    f.render_widget(Paragraph::new(right), Rect::new(right_x as u16, 0, right_width as u16, rows as u16));

    let status = if app.connected { " Ratatui front end  |  engine: menu.ps1 -Serve  |  Ctrl+C: stop task / quit" } else { " Ratatui front end  |  starting engine (menu.ps1 -Serve)..." };
    f.render_widget(Paragraph::new(styled(cut(status, width), Color::DarkGray)), Rect::new(0, rows as u16, width as u16, 1));
    f.set_cursor_position(((cursor.1.min(width - 1)) as u16, cursor.0 as u16));
}

// ---------------------------------------------------------------- keys (same as the dashboard)

fn submit(app: &mut App, engine: &mut Engine) {
    let value = app.input.trim().to_owned();
    app.input.clear();
    if app.snap.get("mode").is_empty() || app.snap.get("mode") == "command" {
        match value.to_uppercase().as_str() {
            "" => return,
            "M" => {
                app.memory_open = !app.memory_open;
                if app.memory_open && app.width < 100 { app.add_log("text", "[widen terminal to 100 columns to show metrics panel]"); }
                return;
            }
            "[" => { app.page = app.page.saturating_sub(1); return; }
            "]" => { app.page = (app.page + 1).min(app.max_page); return; }
            "Q" => { app.quit = true; return; }
            _ => {}
        }
    }
    engine.send("submit", &value);
    app.log_top = None;
}

fn handle_key(app: &mut App, engine: &mut Engine, key: KeyEvent) {
    if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
        if app.snap.flag("busy") { engine.send("stop", ""); } else { app.quit = true; } // stop the task, or quit when idle
        return;
    }
    let page = app.height.saturating_sub(4).max(1);
    let tree = app.snap.flag("tree");
    if key.code == KeyCode::Tab {
        if app.focus_program { app.focus_program = false; }
        else if app.snap.flag("interactive") && !tree { app.focus_program = true; app.log_top = None; }
        return;
    }
    if app.focus_program {
        match key.code {
            KeyCode::Enter => { let text = std::mem::take(&mut app.program_input); engine.send("program", &text); app.log_top = None; }
            KeyCode::Backspace => { app.program_input.pop(); }
            KeyCode::Char(c) if app.program_input.len() < 2048 => app.program_input.push(c),
            _ => {}
        }
        return;
    }
    if tree {
        let command = match key.code { KeyCode::Enter => "enter", KeyCode::Up => "up", KeyCode::Down => "down", KeyCode::Left => "left", KeyCode::Right => "right", KeyCode::Esc => "esc", _ => return };
        engine.send("tree", command);
        return;
    }
    let command_mode = app.snap.get("mode").is_empty() || app.snap.get("mode") == "command";
    match key.code {
        KeyCode::Enter => submit(app, engine),
        KeyCode::Up => app.log_top = Some(app.log_top.unwrap_or(app.log_max_top).saturating_sub(1)),
        KeyCode::Down => if let Some(top) = app.log_top { app.log_top = if top + 1 >= app.log_max_top { None } else { Some(top + 1) }; },
        KeyCode::PageUp => app.log_top = Some(app.log_top.unwrap_or(app.log_max_top).saturating_sub(page)),
        KeyCode::PageDown => if let Some(top) = app.log_top { app.log_top = if top + page >= app.log_max_top { None } else { Some(top + page) }; },
        KeyCode::End => app.log_top = None,
        KeyCode::Left if command_mode => app.page = app.page.saturating_sub(1),
        KeyCode::Right if command_mode => app.page = (app.page + 1).min(app.max_page),
        KeyCode::Backspace => { app.input.pop(); }
        KeyCode::Esc => { app.input.clear(); engine.send("escape", ""); }
        KeyCode::Char(c) if app.input.len() < 2048 => app.input.push(c),
        _ => {}
    }
}

fn main() -> io::Result<()> {
    let (tx, rx) = mpsc::channel();
    let mut engine = match Engine::start(tx) {
        Ok(engine) => engine,
        Err(error) => { eprintln!("Could not start menu.ps1 -Serve ({}): {error}", menu_script().display()); return Err(error); }
    };
    let mut app = App {
        snap: Snapshot::default(), connected: false, closed: false, quit: false, log: VecDeque::new(), log_top: None, log_max_top: 0,
        input: String::new(), program_input: String::new(), focus_program: false, memory_open: true, page: 0, max_page: 0, height: 0, width: 0,
    };
    enable_raw_mode()?;
    execute!(io::stdout(), EnterAlternateScreen)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(io::stdout()))?;
    let result = (|| -> io::Result<()> {
        while !app.quit {
            while let Ok(message) = rx.try_recv() {
                match message {
                    Message::Frame(snapshot) => {
                        app.snap = snapshot; app.connected = true;
                        if !app.snap.flag("interactive") { app.focus_program = false; app.program_input.clear(); }
                    }
                    Message::Log(kind, text) => app.add_log(&kind, &text),
                    Message::Closed => app.closed = true,
                }
            }
            if app.closed { break; }
            terminal.draw(|f| draw(f, &mut app))?;
            if event::poll(Duration::from_millis(100))? {
                if let Event::Key(key) = event::read()? { if key.kind == KeyEventKind::Press { handle_key(&mut app, &mut engine, key); } }
            }
        }
        Ok(())
    })();
    let _ = disable_raw_mode();
    let _ = execute!(terminal.backend_mut(), LeaveAlternateScreen);
    let _ = terminal.show_cursor();
    engine.stop();
    if app.closed && !app.quit {
        eprintln!("The engine (menu.ps1 -Serve) stopped. Last messages:");
        for (_, text) in app.log.iter().rev().take(6).collect::<Vec<_>>().into_iter().rev() { eprintln!("  {text}"); }
    }
    result
}

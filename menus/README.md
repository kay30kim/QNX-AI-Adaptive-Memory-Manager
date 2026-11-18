# QNX Control Center: menus

## Entry points

| Script | Purpose |
| --- | --- |
| `menu.ps1` | Main PowerShell dashboard with all features. |
| `menu-opciones.ps1` | Selector for the three interfaces (dashboard, Ratatui, FTXUI). Builds a compiled one if it is missing or older than its sources, then runs it. |

```powershell
powershell -ExecutionPolicy Bypass -File .\menu.ps1               # dashboard
powershell -ExecutionPolicy Bypass -File .\menu-opciones.ps1      # choose an interface
powershell -ExecutionPolicy Bypass -File .\menu-opciones.ps1 -Menu ftxui   # launch one directly
powershell -ExecutionPolicy Bypass -File .\menu-opciones.ps1 -Rebuild      # rebuild all compiled menus
```

`menu.ps1` also has non-interactive modes:
- `-Check` and `-Snapshot` print the status and the program list.
- `-Run src\path\file.cpp` compiles, uploads and runs one program.
- `-Serve` is the headless engine used by the compiled front ends, described below.

## Telemetry: guest view and host view

The dashboard shows two independent memory views:

| View | Source | Runs inside QNX? |
| --- | --- | --- |
| **QNX guest** | `/proc/vm/stats` page counters × page size (exact free/total RAM), `pidin info` (visible processes and threads), `top -b` (per-core busy % = 100 − idle), `pidin -p <pid> mem` (data/heap/stack of the program you launched) | Yes, over **one persistent SSH session**. Memory is sampled every `GuestProbeSeconds` (0.5 s = 2 Hz); CPU comes from one continuous `top` in the same session, once per second, because QNX `top` cannot measure shorter windows |
| **VM host** | VirtualBox `VBoxManage metrics` (`RAM/Usage/Used`) or the QEMU process working set on Windows | No |

- Press **`P`**, then Enter, to turn the guest probe off or on. With the probe off, nothing runs inside QNX and only the host view is measured. The setting is saved in `qnx.local.json`.
- The host figure is what the hypervisor process costs Windows. It is not guest free RAM or heap usage.
- `qnxuser` can see only its own processes, so the process and thread counts and `pidin mem` exclude system processes.
- The program memory panel works for programs launched from the dashboard. Uploaded binaries are named `/tmp/qnx-menu-<hex>`, and they are matched by their hexadecimal suffix because `pidin` truncates names to 18 characters. When the program exits, its peak data and heap values are written to the output pane.
- The charts and the on-screen figures are illustrative and rounded for display. The CSV stores exact values only.

### CSV recording (`G`)

Each recording creates `measurements/qnx-metrics-<timestamp>.csv`. Rows are written as follows:
- **Guest probe running:** one row per QNX sample, at 2 Hz.
- **Probe off or SSH down:** one row per host sample.

The file has only these columns:

| Column | Meaning | Exactness |
| --- | --- | --- |
| `timestamp_utc` | Time of the QNX sample, or of the host sample when there is no guest sample. | |
| `program` | `src`-relative path of the program launched from the menu, such as `src\memory-ramp\memory-ramp.cpp`. Empty when none is running. | |
| `guest_used_bytes`, `guest_free_bytes` | QNX RAM used and free. Total = used + free. | Exact: `/proc/vm/stats` page counters × page size |
| `guest_cpu_busy_percent` | Mean CPU busy over all cores. | Exact mean of what `top` reports: 100 − idle % per core, 0.1 % resolution, 1 s window. Changes once per second. |
| `program_heap_bytes` | Heap of the launched program. | Exact when `pidin` prints it in bytes or `K`. Empty when `pidin` rounds it to `M` or `G`. |
| `host_resident_bytes` | Memory that the VM process uses on Windows. | Exact: VirtualBox in KiB, QEMU in bytes |

**The CSV holds exact data only.** An empty cell means the value is unavailable, or only available rounded. An empty cell is never an estimate.

`qnxuser` cannot read `/proc/<pid>/*` (`vmstat`, `pmap`, `mappings` and `devctl` all return "Operation not permitted"), so the exact size of a large program heap is not available from outside the process.

## Dashboard keys

| Key | Action |
| --- | --- |
| number + Enter | Compile the program, upload it and run it in QNX. Use **Tab** to type input for an interactive program. |
| `T` | Browse `src` as a tree |
| `M` | Show or hide the metrics column. It needs at least 100 columns. |
| `H` | Show host details and run `pidin info; pidin mem` in the output pane |
| `P` | Turn the guest probe on or off |
| `G` | Start or stop CSV recording |
| `S` | Run a single SSH command |
| `I` | Start the VM (VirtualBox, or QEMU with `QemuExecutable`) |
| `C` | Set host, user, port and VM |
| `V` | Show hypervisor diagnostics |
| `K` or Ctrl+C | Stop the running task. A program in QNX first gets Ctrl+C (SIGINT); after 3 s it is forced with `kill -9` and its binary is removed. A build, upload or other command has its whole process tree killed. With nothing running, Ctrl+C quits. |
| `Q` | Quit |

Up/Down, PgUp/PgDn and End scroll the output pane.

## Configuration (`qnx.local.json`, git-ignored)

| Key | Default | Meaning |
| --- | --- | --- |
| `Vm` | `noname` | VirtualBox VM name |
| `Backend` | `auto` | `auto`, `virtualbox` or `qemu` |
| `Host` / `Port` / `User` | auto / `22` / `qnxuser` | SSH target. Leave `Host` empty for VirtualBox auto-detection. QEMU always needs it, typically `127.0.0.1` with a `hostfwd` port. |
| `GuestProbe` | `true` | Run `pidin`/`top` inside QNX for the guest view |
| `GuestProbeSeconds` | `0.5` | Guest memory sampling period in seconds (0.5 = 2 Hz; minimum 0.2) |
| `QemuExecutable` / `QemuArguments` / `QemuPid` / `QemuRamMiB` | — | QEMU launch, process selection and configured RAM |
| `SdkEnv` | `%USERPROFILE%\qnx800\qnxsdp-env.bat` | QNX SDP environment script |

SSH must work without a password prompt (key-based authentication).

## Compiled front ends

| Folder | Library | Language |
| --- | --- | --- |
| `ratatui/` | [Ratatui](https://ratatui.rs) | Rust |
| `ftxui/` | [FTXUI](https://github.com/ArthurSonzogni/FTXUI) | C++ |

Both front ends have the same layout and keys as the dashboard:
- **Left column:** logo, target, address, guest and host RAM, programs and prompt.
- **Middle column:** QNX GUEST, PROGRAM and VM HOST. It is hidden below 100 columns or with `M`.
  - **Gauges:** RAM and each CPU core.
  - **Live charts:** QNX RAM used, QNX CPU busy and VM host resident. Each chart is a multi-row bar chart with a Y axis, with the newest sample on the right. Charts fill the free rows of the column. When space is short, the host chart is dropped first, then CPU.
  - **Commands:** a dark `$ ...` line under each metric shows the exact command that produces it: `ssh`, `grep ... /proc/vm/stats`, `top -b -D 1 -z 5`, `pidin info`, `pidin -p <pid> mem`, and `VBoxManage metrics query` or the QEMU `WorkingSet64`. The engine defines each command once in `menu.ps1` (`$GuestCommands`, `Get-HostMetricCommand`) and uses the same definition to measure and to display, so the two always match.
  - **Width:** the column takes about 35% of the terminal width (32 to 60 characters), taken from OUTPUT, to fit the command lines and the charts.
  - **Chart columns:** each chart column groups 2 samples (about 1 s) and shows the higher one.
  - **History and rate:** the engine samples at 2 Hz and keeps the last 240 samples, about 2 minutes. QNX CPU changes once per second, the minimum of QNX `top`. The VirtualBox host metric also changes once per second, its minimum period. QEMU is sampled at a true 2 Hz.
- **Right column:** OUTPUT, with scrollback and Tab for program input.
- **Bottom line:** a status line.

The front ends contain no logic of their own. Each one starts `menu.ps1 -Serve`, the dashboard engine without its console UI, which does VM discovery, both telemetry views, build, upload and run, SSH, CSV and configuration. The front end renders the engine's state with its own widgets: Ratatui `Gauge`/`Sparkline` and FTXUI `gauge`/`separator`. A fix in `dashboard.ps1` therefore applies to all three interfaces.

Each executable looks for `menu.ps1` in `QNX_ROOT`, then in its own folder and that folder's parents, so it can be started from any directory. When the front end exits or is closed, the engine stops its SSH sessions. FTXUI also runs it in a kill-on-close job object.

### Engine protocol (`menu.ps1 -Serve`)

- **stdout:** `@@LOG<TAB>kind<TAB>text` lines (kind is `cmd`, `err`, `ok` or `text`), and state blocks from `@@FRAME` to `@@END` made of `key<TAB>value` lines, such as `state`, `guest_used`, `core`, `hist`, `program_heap`, `host_resident`, `src` or `node`. A block is sent only when the state changes.
- **stdin:** `submit<TAB>text`, which is the same as typing in the Select prompt, plus `escape`, `stop`, `program<TAB>text`, `tree<TAB>up|down|left|right|enter|esc` and `quit`. Closing stdin also stops the engine.

### Building

```powershell
powershell -ExecutionPolicy Bypass -File .\menus\build.ps1                    # all
powershell -ExecutionPolicy Bypass -File .\menus\build.ps1 -Target ftxui
powershell -ExecutionPolicy Bypass -File .\menus\build.ps1 -Clean             # rebuild from scratch
```

Requirements on `PATH`: `git`, `cmake`, MinGW-w64 (`gcc`, `g++`, `mingw32-make`) and Rust (`cargo`, MSVC host toolchain). Third-party sources are cloned into `.build/` at pinned revisions. The output in `menus/bin/` is linked statically, with no MinGW or VC++ runtime DLLs, and is git-ignored. `menu-opciones.ps1` rebuilds it automatically when needed.

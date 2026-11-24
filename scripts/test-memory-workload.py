"""Compile and test workload + telemetry in QNX/QEMU using the sibling SDP/VM."""
import csv
import io
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
VM = ROOT.parent / "qnx-hello-vm"
SDK = ROOT.parent / "qnx800"
BUILD = ROOT / ".build" / "workload-tests"
QEMU = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "qemu/qemu-system-x86_64.exe"
BUILD.mkdir(parents=True, exist_ok=True)

cases = {
    "steady": "--pattern steady --requests 200 --bytes 257 --trace-only",
    "repeat": "--pattern steady --requests 200 --bytes 257 --trace-only",
    "seed": "--pattern steady --requests 200 --bytes 257 --seed 43 --trace-only",
    "burst": "--pattern burst --requests 200 --bytes 257 --trace-only",
    "ramp": "--pattern ramp --requests 200 --bytes 257 --trace-only",
    "baseline": "--requests 200 --bytes 257 --interval-ms 0 --trace",
    "paced": "--requests 5 --bytes 257 --interval-ms 10 --trace",
    "one": "--requests 1 --keys 1 --bytes 1 --seed 0 --interval-ms 0 --trace",
    "maxseed": "--seed 4294967295 --requests 1 --trace-only",
    "zero": "--requests 0",
    "overflow": "--seed 4294967296",
    "negative": "--bytes -1",
    "missing": "--seed",
    "unknown": "--wrong 1",
    "pattern": "--pattern invalid",
    "help": "--help",
    "metrics": "--requests 200 --bytes 257 --interval-ms 0 --sample-every 35 --run-id test-metrics --metrics-csv",
    "metrics_paced": "--requests 10 --bytes 257 --interval-ms 10 --sample-every 3 --metrics-csv",
    "metrics_one": "--requests 1 --bytes 1 --interval-ms 0 --metrics-csv",
    "metrics_burst": "--requests 10 --bytes 257 --pattern burst --metrics-csv",
    "metrics_ramp": "--requests 10 --bytes 257 --pattern ramp --metrics-csv",
    "conflict": "--metrics-csv --trace-only",
    "bad_id": "--run-id bad,id",
    "bad_window": "--sample-every 0",
}
script = ["#!/bin/sh"]
for name, args in cases.items():
    script += [f"echo BEGIN_{name}", f"/proc/boot/memory_workload {args}",
               'echo EXIT=$?', f"echo END_{name}"]
script += ["echo BEGIN_interrupted", "/proc/boot/memory_workload --requests 10000 --interval-ms 10 --metrics-csv &",
           "child=$!", "sleep 1", "kill -INT $child", "wait $child", "echo EXIT=$?", "echo END_interrupted",
           "echo BEGIN_unit", "/proc/boot/telemetry_test", "echo EXIT=$?", "echo END_unit", "echo STEP1_TESTS_DONE"]
(BUILD / "cases.sh").write_text("\n".join(script) + "\n", encoding="ascii", newline="\n")
base = (VM / "output/build/ifs.build").read_text()
assert "\n/proc/boot/hello\n" in base, "Expected Hello World startup entry"
base = base.replace("\n/proc/boot/hello\n", "\n/proc/boot/sh /proc/boot/cases.sh\n", 1)
base += (f"\n[uid=0 gid=0 perms=0755] /proc/boot/memory_workload={BUILD.as_posix()}/memory_workload\n"
         f"[uid=0 gid=0 perms=0444] /proc/boot/cases.sh={BUILD.as_posix()}/cases.sh\n")
base += f"[uid=0 gid=0 perms=0755] /proc/boot/telemetry_test={BUILD.as_posix()}/telemetry_test\n"
(BUILD / "test.build").write_text(base, encoding="ascii")
batch = ["@echo off", f'call "{SDK / "qnxsdp-env.bat"}" >nul', "@echo off",
         "if errorlevel 1 exit /b 1",
         f'q++ -Vgcc_ntox86_64 -std=c++11 -Wall -Wextra -Werror -static "{ROOT / "src/workloads/memory_workload.cpp"}" -o "{BUILD / "memory_workload"}"',
         "if errorlevel 1 exit /b 1",
         f'q++ -Vgcc_ntox86_64 -std=c++11 -Wall -Wextra -Werror -static "{ROOT / "tests/workload_telemetry.cpp"}" -o "{BUILD / "telemetry_test"}"',
         "if errorlevel 1 exit /b 1", f'cd /d "{VM}"',
         'set "MKFS_PATH=../qnx800/target/qnx/x86_64;../qnx800/target/qnx/x86_64/boot/sys;../qnx800/target/qnx;."',
         'set "PROCESSOR=x86_64"',
         f'mkifs -o "{BUILD}" "{BUILD / "test.build"}" "{BUILD / "test.bin"}"',
         "exit /b %errorlevel%"]
(BUILD / "build.cmd").write_text("\n".join(batch) + "\n", encoding="ascii")
subprocess.run(["cmd.exe", "/d", "/c", str(BUILD / "build.cmd")], check=True)
log_path = BUILD / "qnx-test.log"
with log_path.open("wb") as log:
    proc = subprocess.Popen([str(QEMU), "-cpu", "max", "-m", "1024", "-smp", "2",
                             "-display", "none", "-serial", "stdio", "-monitor", "none",
                             "-nic", "none", "-kernel", str(BUILD / "test.bin")],
                            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if "STEP1_TESTS_DONE" in log_path.read_text(errors="replace"):
                break
            if proc.poll() is not None:
                raise RuntimeError("QEMU exited before tests completed")
            time.sleep(0.2)
        else:
            raise RuntimeError(f"QNX test timeout; inspect {log_path}")
    finally:
        proc.terminate()
        proc.wait(timeout=10)

output = log_path.read_text(errors="replace").replace("\r", "")
chunks = {}
for name in list(cases) + ["interrupted", "unit"]:
    match = re.search(rf"BEGIN_{name}\n(.*?)END_{name}", output, re.S)
    assert match, f"Missing test output: {name}"
    chunks[name] = match.group(1)
    expected = 2 if name in {"zero", "overflow", "negative", "missing", "unknown", "pattern", "conflict", "bad_id", "bad_window"} else (130 if name == "interrupted" else 0)
    assert f"EXIT={expected}\n" in chunks[name], (name, chunks[name])

def rows(name):
    lines = [line for line in chunks[name].splitlines() if re.match(r"^\d+,", line)]
    return [list(map(int, row)) for row in csv.reader(io.StringIO("\n".join(lines)))]

steady = rows("steady")
assert len(steady) == 200 and steady == rows("repeat")
assert [r[1] for r in steady] != [r[1] for r in rows("seed")]
assert all(r[0] == i and 0 <= r[1] < 64 and r[2] == 257 and r[3] == i * 10000
           for i, r in enumerate(steady))
for name in ("burst", "ramp"):
    trace = rows(name)
    assert [r[:3] for r in trace] == [r[:3] for r in steady]
    for i in range(199):
        gap = (1000 if i % 100 < 20 else 20000) if name == "burst" else 10000 * (10 - i * 10 // 200) // 10
        assert trace[i + 1][3] - trace[i][3] == gap, (name, i)
baseline = rows("baseline")
assert [r[:3] for r in baseline] == [r[:3] for r in steady]
assert all(r[3] == 0 for r in baseline)
expected_sum = sum(sum((key + j) & 255 for j in range(size)) for _, key, size, _ in baseline)
assert "completed=200 allocations=200" in chunks["baseline"]
assert f"result_checksum={expected_sum}" in chunks["baseline"]
assert [r[3] for r in rows("paced")] == [0, 10000, 20000, 30000, 40000]
assert "completed=5 allocations=5" in chunks["paced"]
assert rows("one") == [[0, 0, 1, 0]]
assert "completed=1 allocations=1 result_checksum=0" in chunks["one"]
def metrics(name):
    lines = [line for line in chunks[name].splitlines() if line.startswith(("schema_version,", "1,"))]
    return list(csv.DictReader(lines))

for name in ("metrics", "metrics_paced", "metrics_one", "metrics_burst", "metrics_ramp", "interrupted"):
    data = metrics(name)
    assert data and all(None not in r and None not in r.values() for r in data), name
    summary = data[-1]
    windows = data[:-1]
    assert summary["row_type"] == "summary"
    assert all(r["row_type"] == "window" for r in windows)
    assert len({r["run_id"] for r in data}) == 1 and summary["run_id"]
    completed = int(summary["completed"])
    assert completed == sum(int(r["completed"]) for r in windows)
    assert len(windows) == (completed + int(summary["sample_every"]) - 1) // int(summary["sample_every"])
    assert summary["status"] == ("interrupted" if name == "interrupted" else "complete")
    if name == "interrupted": assert 0 < completed < 10000
    else: assert completed == int(summary["configured_requests"])
    for r in data:
        n, size = int(r["completed"]), int(r["block_bytes"])
        assert int(r["attempted"]) == int(r["allocation_calls"]) == int(r["allocations"]) == int(r["frees"]) == n
        assert int(r["allocated_bytes"]) == n * size
        assert int(r["live_buffer_bytes"]) == int(r["retained_buffer_bytes"]) == int(r["allocation_failures"]) == 0
        assert int(r["peak_live_buffer_bytes"]) == size
        assert r["cache_hits"] == r["cache_misses"] == ""
        assert 0 <= float(r["latency_p50_us"]) <= float(r["latency_p95_us"]) <= float(r["latency_p99_us"]) <= float(r["latency_max_us"])
        seconds = (int(r["end_ns"]) - int(r["start_ns"])) / 1e9
        assert abs(float(r["elapsed_seconds"]) - seconds) < 1e-9
        assert abs(float(r["throughput_rps"]) - n / seconds) < 1e-5
    for a, b in zip(windows, windows[1:]): assert a["end_ns"] == b["start_ns"]
assert metrics("metrics")[0]["run_id"] == "test-metrics"
assert int(metrics("metrics")[-1]["result_checksum"]) == expected_sum
assert "TELEMETRY_UNIT_PASS" in chunks["unit"]
failed = metrics("unit")[0]
assert failed["allocation_failures"] == "1" and failed["allocations"] == "0"
assert failed["latency_p99_us"] == failed["cache_hits"] == failed["cache_misses"] == ""
print(f"PASS: {len(cases) + 2} QNX cases; workload reproducibility, CSV/counters, percentile reference, pacing, interruption, and invalid inputs.")
print(f"QNX log: {log_path}")

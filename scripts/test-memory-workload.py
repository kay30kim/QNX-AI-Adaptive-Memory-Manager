"""Compile and test Step 1 inside QNX/QEMU. Requires the sibling SDP and VM setup."""
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
}
script = ["#!/bin/sh"]
for name, args in cases.items():
    script += [f"echo BEGIN_{name}", f"/proc/boot/memory_workload {args}",
               'echo EXIT=$?', f"echo END_{name}"]
script += ["echo STEP1_TESTS_DONE"]
(BUILD / "cases.sh").write_text("\n".join(script) + "\n", encoding="ascii", newline="\n")
base = (VM / "output/build/ifs.build").read_text()
assert "\n/proc/boot/hello\n" in base, "Expected Hello World startup entry"
base = base.replace("\n/proc/boot/hello\n", "\n/proc/boot/sh /proc/boot/cases.sh\n", 1)
base += (f"\n[uid=0 gid=0 perms=0755] /proc/boot/memory_workload={BUILD.as_posix()}/memory_workload\n"
         f"[uid=0 gid=0 perms=0444] /proc/boot/cases.sh={BUILD.as_posix()}/cases.sh\n")
(BUILD / "test.build").write_text(base, encoding="ascii")
batch = ["@echo off", f'call "{SDK / "qnxsdp-env.bat"}" >nul', "@echo off",
         "if errorlevel 1 exit /b 1",
         f'q++ -Vgcc_ntox86_64 -std=c++11 -Wall -Wextra -Werror -static "{ROOT / "src/workloads/memory_workload.cpp"}" -o "{BUILD / "memory_workload"}"',
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
for name in cases:
    match = re.search(rf"BEGIN_{name}\n(.*?)END_{name}", output, re.S)
    assert match, f"Missing test output: {name}"
    chunks[name] = match.group(1)
    expected = 2 if name in {"zero", "overflow", "negative", "missing", "unknown", "pattern"} else 0
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
print(f"PASS: {len(cases)} QNX cases; reproducibility, seed, pacing schedules, baseline results, and invalid inputs.")
print(f"QNX log: {log_path}")

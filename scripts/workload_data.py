"""Validate and replay QNX workload telemetry using only Python's standard library."""
import argparse
import csv
import glob
import json
import math
from pathlib import Path
import re
import sys
import time

V1 = "schema_version run_id row_type status mode pattern seed configured_requests keys block_bytes interval_ms sample_every window_index start_ns end_ns attempted completed allocation_calls allocations frees allocation_failures allocated_bytes live_buffer_bytes peak_live_buffer_bytes retained_buffer_bytes measurement_storage_bytes elapsed_seconds throughput_rps latency_p50_us latency_p95_us latency_p99_us latency_max_us start_lateness_p99_us cache_hits cache_misses sequence_hash result_checksum".split()
V2 = V1 + "pool_blocks pool_capacity_bytes pool_hits pool_misses pool_exhaustions invalid_releases request_failures peak_owned_buffer_bytes pool_metadata_bytes cleanup_frees post_cleanup_owned_bytes".split()
V3 = V2 + "cache_capacity_bytes cache_effective_capacity_bytes cache_bytes cache_entries cache_evictions cache_bypasses cache_metadata_bytes".split()
SCHEMAS = {1: V1, 2: V2, 3: V3}
TEXT = set("run_id row_type status mode pattern sequence_hash".split())
LATENCIES = "latency_p50_us latency_p95_us latency_p99_us latency_max_us start_lateness_p99_us".split()
FLOATS = set(LATENCIES + ["elapsed_seconds", "throughput_rps"])
OPTIONAL = set(LATENCIES + "cache_hits cache_misses sequence_hash result_checksum cleanup_frees post_cleanup_owned_bytes".split())
CONFIG = "schema_version run_id status mode pattern seed configured_requests keys block_bytes interval_ms sample_every measurement_storage_bytes pool_blocks pool_capacity_bytes pool_metadata_bytes cache_capacity_bytes cache_effective_capacity_bytes cache_metadata_bytes".split()
ADDITIVE = "attempted completed allocation_calls allocations frees allocation_failures allocated_bytes pool_hits pool_misses pool_exhaustions invalid_releases request_failures cache_hits cache_misses cache_evictions cache_bypasses".split()


class DataError(ValueError):
    pass


def require(condition, context, message):
    if not condition:
        raise DataError(f"{context}: {message}")


def parse_value(field, value, context):
    if value == "":
        require(field in OPTIONAL, context, f"missing value: {field}")
        return None
    if field in TEXT:
        return value
    if field in FLOATS:
        try:
            parsed = float(value)
        except ValueError as exc:
            raise DataError(f"{context}: invalid number: {field}={value!r}") from exc
        require(math.isfinite(parsed) and parsed >= 0, context, f"non-finite/negative {field}")
        return parsed
    require(bool(re.fullmatch(r"[0-9]+", value)) and len(value) <= 20, context, f"invalid unsigned integer: {field}={value!r}")
    parsed = int(value)
    require(parsed <= 2**64 - 1, context, f"integer overflow: {field}")
    return parsed


def validate_row(r, context):
    version, mode = r["schema_version"], r["mode"]
    require(r["row_type"] in ("window", "summary"), context, "unknown row_type")
    require(r["status"] in ("complete", "interrupted", "allocation_failed", "pool_exhausted"), context, "unknown status")
    require(mode in ({1: ("baseline",), 2: ("baseline", "pool"), 3: ("baseline", "pool", "cache")}[version]), context, "mode incompatible with schema")
    require(r["pattern"] in ("steady", "burst", "ramp"), context, "unknown pattern")
    require(bool(re.fullmatch(r"[A-Za-z0-9_-]{1,64}", r["run_id"])), context, "invalid run_id")
    for field, low, high in (("seed", 0, 2**32 - 1), ("configured_requests", 1, 1000000),
                             ("keys", 1, 1000000), ("block_bytes", 1, 16777216),
                             ("interval_ms", 0, 1000), ("sample_every", 1, 1000000)):
        require(low <= r[field] <= high, context, f"out-of-range {field}")
    attempted, completed, size = r["attempted"], r["completed"], r["block_bytes"]
    require(completed <= attempted <= r["configured_requests"], context, "invalid attempted/completed counts")
    require(r["allocation_calls"] == r["allocations"] + r["allocation_failures"], context, "allocation_calls != allocations + failures")
    require(r["allocated_bytes"] == r["allocations"] * size, context, "allocated_bytes inconsistent with allocations")
    failures = attempted - completed
    if version >= 2:
        require(r["request_failures"] == failures, context, "request_failures != attempted - completed")
    require(r["allocation_failures"] <= failures, context, "more allocation failures than failed requests")
    require(r["end_ns"] >= r["start_ns"], context, "end_ns precedes start_ns")
    duration = (r["end_ns"] - r["start_ns"]) / 1e9
    require(math.isclose(r["elapsed_seconds"], duration, rel_tol=1e-12, abs_tol=1e-9), context, "elapsed_seconds inconsistent with nanosecond offsets")
    expected_rate = completed / duration if duration else 0
    require(math.isclose(r["throughput_rps"], expected_rate, rel_tol=1e-9, abs_tol=1e-8), context, "throughput_rps inconsistent with completed/duration")
    if completed:
        require(all(r[f] is not None for f in LATENCIES), context, "successful requests require latency statistics")
        values = [r[f] for f in LATENCIES[:4]]
        require(values == sorted(values), context, "latency percentiles are out of order")
        require(r["latency_max_us"] <= duration * 1e6 + 1e-6, context, "service latency exceeds row duration")
    else:
        require(all(r[f] is None for f in LATENCIES), context, "no successful requests: latency must be empty")
    require(r["peak_live_buffer_bytes"] >= r["live_buffer_bytes"], context, "peak live bytes below current live bytes")
    if mode == "baseline":
        require(r["allocations"] == r["frees"] == completed and r["allocation_calls"] == attempted, context, "baseline allocator counts inconsistent")
        require(r["live_buffer_bytes"] == r["retained_buffer_bytes"] == 0, context, "baseline cannot retain buffers")
    if version >= 2:
        require(r["peak_owned_buffer_bytes"] >= max(r["peak_live_buffer_bytes"], r["live_buffer_bytes"] + r["retained_buffer_bytes"]), context, "peak owned bytes below observed bytes")
        if mode == "baseline":
            require(all(r[f] == 0 for f in ("pool_blocks", "pool_capacity_bytes", "pool_hits", "pool_misses", "pool_exhaustions", "pool_metadata_bytes")), context, "baseline has pool metrics")
        else:
            require(1 <= r["pool_blocks"] <= 4096, context, "invalid pool block count")
            require(r["pool_capacity_bytes"] == r["pool_blocks"] * size, context, "pool capacity mismatch")
            require(r["peak_owned_buffer_bytes"] <= r["pool_capacity_bytes"], context, "pool capacity exceeded")
            require(r["pool_misses"] == r["allocation_calls"] + r["pool_exhaustions"], context, "pool misses inconsistent")
            require(r["allocation_failures"] + r["pool_exhaustions"] == failures, context, "pool failure counts inconsistent")
        require(r["invalid_releases"] == 0, context, "invalid buffer return recorded")
        if mode == "pool":
            require(r["pool_hits"] + r["pool_misses"] == attempted, context, "pool acquires inconsistent with requests")
    if mode == "cache":
        require(r["cache_hits"] is not None and r["cache_misses"] is not None, context, "cache counts must be present")
        require(r["cache_hits"] + r["cache_misses"] == attempted, context, "cache hits + misses != attempted")
        require(r["pool_hits"] + r["pool_misses"] == r["cache_misses"], context, "cache misses != pool acquires")
        require(0 <= r["cache_capacity_bytes"] <= 2**32 - 1, context, "invalid cache capacity")
        effective = min(r["pool_blocks"], r["cache_capacity_bytes"] // size) * size
        require(r["cache_effective_capacity_bytes"] == effective, context, "effective cache capacity mismatch")
        require(r["cache_bytes"] == r["cache_entries"] * size <= effective, context, "cache occupancy exceeds capacity or disagrees with entries")
        require(r["live_buffer_bytes"] == r["cache_bytes"], context, "cached leases disagree with live bytes")
        require(r["cache_evictions"] <= r["cache_misses"], context, "too many cache evictions")
        require(r["cache_bypasses"] == (r["cache_misses"] if effective == 0 else 0), context, "cache bypass count inconsistent with capacity")
    else:
        require(r["cache_hits"] is None and r["cache_misses"] is None, context, "non-cache hit/miss fields must be empty, not zero")
        if version == 3:
            require(all(r[f] == 0 for f in V3[len(V2):]), context, "non-cache mode has cache metrics")
    summary = r["row_type"] == "summary"
    if summary:
        require(r["window_index"] == r["start_ns"] == 0, context, "summary index/start must be zero")
        require(isinstance(r["sequence_hash"], str) and bool(re.fullmatch(r"[0-9a-fA-F]{1,16}", r["sequence_hash"])), context, "missing/invalid sequence_hash")
        require(r["result_checksum"] is not None, context, "missing result_checksum")
        if version >= 2:
            require(r["cleanup_frees"] is not None and r["post_cleanup_owned_bytes"] == 0, context, "missing cleanup or payload leak")
            require(r["allocations"] == r["frees"] + r["cleanup_frees"], context, "cleanup free count mismatch")
    else:
        require(attempted > 0, context, "empty window")
        require(r["sequence_hash"] is None and r["result_checksum"] is None, context, "window contains summary fingerprints")
        if version >= 2:
            require(r["cleanup_frees"] is None and r["post_cleanup_owned_bytes"] is None, context, "window contains teardown metrics")


def load_run(path, allow_incomplete=False):
    path = Path(path)
    rows, line_numbers = [], []
    try:
        with path.open(encoding="utf-8-sig", newline="") as stream:
            reader = csv.reader(stream, strict=True)
            header = next(reader, [])
            require(header and len(header) == len(set(header)), path, "empty or duplicate header")
            require("schema_version" in header, path, "not a workload telemetry CSV (missing schema_version)")
            version = None
            for cells in reader:
                context = f"{path}:{reader.line_num}"
                require(len(cells) == len(header), context, "CSV column count mismatch")
                raw = dict(zip(header, cells))
                require(raw["schema_version"] in ("1", "2", "3"), context, "unsupported schema_version")
                if version is None:
                    version = int(raw["schema_version"])
                    require(set(header) == set(SCHEMAS[version]), context, "columns do not match schema version")
                require(int(raw["schema_version"]) == version, context, "mixed schema versions")
                row = {field: parse_value(field, raw[field], context) for field in header}
                validate_row(row, context)
                rows.append(row)
                line_numbers.append(reader.line_num)
    except (OSError, UnicodeError, csv.Error) as exc:
        raise DataError(f"{path}: {exc}") from exc
    require(rows, path, "no data rows")
    require(rows[-1]["row_type"] == "summary" and sum(r["row_type"] == "summary" for r in rows) == 1, path, "expected exactly one final summary (truncated or concatenated run)")
    summary, windows = rows[-1], rows[:-1]
    totals = {f: 0 for f in ADDITIVE if f in summary and summary[f] is not None}
    last_end = 0
    for index, r in enumerate(windows):
        context = f"{path}:{line_numbers[index]}"
        require(all(r[f] == summary[f] for f in CONFIG if f in summary), context, "run identity/configuration/status changed")
        require(r["window_index"] == index, context, "missing, duplicate, or reordered window index")
        require(r["start_ns"] == last_end, context, "time gap, overlap, or out-of-order window")
        require(r["attempted"] <= r["sample_every"], context, "window exceeds sample_every")
        if index < len(windows) - 1:
            require(r["attempted"] == r["sample_every"], context, "short non-final window")
        for field in totals:
            totals[field] += r[field]
        owned = (totals["allocations"] - totals["frees"]) * r["block_bytes"]
        require(owned >= 0 and owned == r["live_buffer_bytes"] + r["retained_buffer_bytes"], context, "buffer ownership does not balance with cumulative allocations/frees")
        last_end = r["end_ns"]
    require(summary["end_ns"] >= last_end, path, "summary ends before last window")
    for field, total in totals.items():
        require(summary[field] == total, path, f"summary {field} != sum of windows")
    for field in ("live_buffer_bytes", "retained_buffer_bytes", "cache_bytes", "cache_entries"):
        if field in summary:
            require(summary[field] == (windows[-1][field] if windows else 0), path, f"summary {field} != final window")
    for field in ("peak_live_buffer_bytes", "peak_owned_buffer_bytes", "latency_max_us"):
        if field in summary:
            values = [r[field] for r in windows if r[field] is not None]
            expected = max(values) if values else (None if field == "latency_max_us" else 0)
            require(summary[field] == expected, path, f"summary {field} != maximum window value")
    failures = summary["attempted"] - summary["completed"]
    status = summary["status"]
    if status == "complete":
        require(summary["completed"] == summary["configured_requests"] and failures == 0, path, "complete status with missing/failed requests")
    elif status == "interrupted":
        require(summary["completed"] < summary["configured_requests"] and failures == 0, path, "invalid interrupted status")
    else:
        counter = "allocation_failures" if status == "allocation_failed" else "pool_exhaustions"
        require(summary.get(counter, 0) > 0 and failures > 0, path, "failure status without matching failure count")
    require(status == "complete" or allow_incomplete, path, f"run is {status}; use --allow-incomplete to inspect this run")
    return rows


def replay_records(rows, speed=0, include_summary=False, clock=time.monotonic, sleep=time.sleep):
    """Replay measured window availability; never regenerate individual requests."""
    if not math.isfinite(speed) or speed < 0:
        raise DataError("speed must be finite and >= 0")
    origin = clock()
    for r in rows:
        if r["row_type"] == "summary" and not include_summary:
            continue
        if speed:
            deadline = origin + r["end_ns"] / 1e9 / speed
            while True:
                remaining = deadline - clock()
                if remaining <= 0:
                    break
                sleep(min(remaining, 0.1))
        yield r


def resolve_inputs(arguments):
    paths = []
    for arg in arguments:
        p = Path(arg)
        matches = sorted(p.glob("workload-*.csv")) if p.is_dir() else [Path(x) for x in sorted(glob.glob(arg))]
        if not matches and p.is_file(): matches = [p]
        require(matches, arg, "no matching workload CSV files")
        paths.extend(x.resolve() for x in matches)
    return list(dict.fromkeys(paths))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="validate complete files and report errors with file/line context")
    validate.add_argument("paths", nargs="+", help="files, globs, or directories (workload-*.csv only)")
    validate.add_argument("--allow-incomplete", action="store_true")
    replay = commands.add_parser("replay", help="validate then emit time-ordered JSON Lines")
    replay.add_argument("path")
    replay.add_argument("--speed", type=float, default=0, help="0 = immediate; 1 = recorded timing; 10 = ten times faster")
    replay.add_argument("--include-summary", action="store_true")
    replay.add_argument("--allow-incomplete", action="store_true")
    replay.add_argument("--output", type=Path, help="new JSONL file; existing files are never overwritten")
    args = parser.parse_args(argv)
    try:
        if args.command == "validate":
            reports, errors, identities = [], [], set()
            for path in resolve_inputs(args.paths):
                try:
                    rows = load_run(path, args.allow_incomplete)
                    summary = rows[-1]
                    require(summary["run_id"] not in identities, path, "duplicate run_id across input files")
                    identities.add(summary["run_id"])
                    reports.append({"path": str(path), "run_id": summary["run_id"], "schema_version": summary["schema_version"],
                                    "mode": summary["mode"], "status": summary["status"], "windows": len(rows) - 1,
                                    "completed": summary["completed"]})
                except DataError as exc:
                    errors.append(str(exc))
            print(json.dumps({"valid": not errors, "runs": reports, "errors": errors}, indent=2, ensure_ascii=False))
            return 1 if errors else 0
        require(math.isfinite(args.speed) and args.speed >= 0, "replay", "speed must be finite and >= 0")
        rows = load_run(args.path, args.allow_incomplete)  # Validate before creating output or emitting events.
        stream = args.output.open("x", encoding="utf-8", newline="\n") if args.output else sys.stdout
        try:
            for index, row in enumerate(replay_records(rows, args.speed, args.include_summary)):
                event = {"event_index": index, "source_file": str(Path(args.path).resolve()), "record": row}
                print(json.dumps(event, ensure_ascii=False, allow_nan=False), file=stream, flush=True)
        finally:
            if args.output: stream.close()
        return 0
    except (DataError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Replay interrupted; any output file contains only the events already emitted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())

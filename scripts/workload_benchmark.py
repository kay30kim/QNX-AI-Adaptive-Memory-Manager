"""Repeat matched QNX baseline/pool/cache runs and report measured tradeoffs."""
import argparse
import csv
import hashlib
import html
import json
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time
import uuid

from workload_data import DataError, load_run, require
from workload_ai import examples, read_recordings, run_pipeline

ROOT = Path(__file__).resolve().parents[1]
MODES = ['baseline', 'pool', 'cache']
METRICS = ['allocations', 'peak_owned_bytes', 'latency_p99_us', 'throughput_rps',
           'request_failures', 'cache_hit_ratio', 'cleanup_frees', 'post_cleanup_owned_bytes']
CONFIG_FIELDS = ['pattern', 'seed', 'configured_requests', 'keys', 'block_bytes', 'interval_ms', 'sample_every']


def save_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    temporary.replace(path)


def make_plan(patterns, seeds, repeats, warmups):
    require(patterns and len(set(patterns)) == len(patterns) and set(patterns) <= {'steady', 'burst', 'ramp'}, 'plan', 'invalid/duplicate patterns')
    require(seeds and len(set(seeds)) == len(seeds) and all(0 <= s <= 2**32-1 for s in seeds), 'plan', 'invalid/duplicate seeds')
    require(1 <= repeats <= 100 and 0 <= warmups <= 10, 'plan', 'repeats must be 1..100; warmups 0..10')
    plan = []
    for scenario, (pattern, seed) in enumerate((p, s) for p in patterns for s in seeds):
        for phase, count in [('warmup', warmups), ('measurement', repeats)]:
            for repeat in range(count):
                offset = (scenario + repeat) % len(MODES)
                for mode in MODES[offset:] + MODES[:offset]:
                    plan.append({'job_id': f'job-{len(plan):04d}', 'pattern': pattern, 'seed': seed,
                                 'mode': mode, 'repeat': repeat, 'phase': phase, 'status': 'pending'})
    return plan


def run_process(command, log, timeout):
    # File output avoids unbounded in-memory build/SSH logs. Children belong to
    # this invocation; terminate that tree on timeout/interrupt, never by name.
    with log.open('w', encoding='utf-8') as stream:
        process = subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            if sys.platform == 'win32':
                subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            else:
                process.kill()
            process.wait(timeout=15)
            raise
    require(code == 0, log, f'runner exited {code}; see log')


def run_target(job, config, log, timeout):
    command = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(ROOT / 'scripts/measure-workload.ps1')]
    options = {'Mode': job['mode'], 'Pattern': job['pattern'], 'Seed': job['seed'],
               'Requests': config['requests'], 'Keys': config['keys'], 'Bytes': config['bytes'],
               'IntervalMs': config['interval_ms'], 'SampleEvery': config['sample_every'],
               'PoolBlocks': config['pool_blocks'], 'CacheBytes': config['cache_bytes']}
    for key, value in options.items(): command.extend(['-' + key, str(value)])
    run_process(command, log, timeout)
    markers = [line.split('=', 1)[1].strip() for line in log.read_text(encoding='utf-8', errors='replace').splitlines()
               if line.startswith('QNX_METRICS_PATH=')]
    require(len(markers) == 1, log, 'expected one exact QNX_METRICS_PATH marker')
    path = Path(markers[0]).resolve()
    require(path.parent == (ROOT / 'measurements').resolve() and path.name.startswith('workload-') and path.suffix == '.csv', log, 'unexpected metrics output path')
    return path


def check_expected(summary, job, config):
    expected = {'mode': job['mode'], 'pattern': job['pattern'], 'seed': job['seed'],
                'configured_requests': config['requests'], 'keys': config['keys'], 'block_bytes': config['bytes'],
                'interval_ms': config['interval_ms'], 'sample_every': config['sample_every']}
    for field, value in expected.items():
        require(summary[field] == value, job['job_id'], f'unexpected recorded {field}')
    require(summary['schema_version'] == 3, job['job_id'], 'new benchmarks require schema 3')
    require(summary['pool_blocks'] == (0 if job['mode'] == 'baseline' else config['pool_blocks']), job['job_id'], 'pool configuration mismatch')
    require(summary['cache_capacity_bytes'] == (config['cache_bytes'] if job['mode'] == 'cache' else 0), job['job_id'], 'cache configuration mismatch')


def matched(summaries):
    first = summaries[0]
    for summary in summaries[1:]:
        require(all(first[k] == summary[k] for k in CONFIG_FIELDS), 'comparison', 'workload conditions differ')
        require(first['sequence_hash'] == summary['sequence_hash'], 'comparison', 'request sequence hash differs')
        require(first['result_checksum'] == summary['result_checksum'], 'comparison', 'result checksum differs')


def measurements(summary):
    return dict(allocations=summary['allocations'], peak_owned_bytes=summary['peak_owned_buffer_bytes'],
                latency_p99_us=summary['latency_p99_us'], throughput_rps=summary['throughput_rps'],
                request_failures=summary['request_failures'], cleanup_frees=summary['cleanup_frees'],
                post_cleanup_owned_bytes=summary['post_cleanup_owned_bytes'],
                cache_hit_ratio=(summary['cache_hits'] / summary['attempted'] if summary['mode'] == 'cache' else None))


def describe(values):
    numbers = [x for x in values if x is not None]
    if not numbers: return {'n': 0, 'mean': None, 'min': None, 'max': None, 'stdev': None}
    return {'n': len(numbers), 'mean': statistics.mean(numbers), 'min': min(numbers), 'max': max(numbers),
            'stdev': statistics.stdev(numbers) if len(numbers) > 1 else None}


def build_report(experiment, directory):
    config = experiment['config']
    planned = make_plan(config['patterns'], config['seeds'], config['repeats'], config['warmups'])
    require(len(planned) == len(experiment['jobs']), 'report', 'experiment plan is incomplete')
    for expected_job, actual in zip(planned, experiment['jobs']):
        require(all(actual[k] == v for k, v in expected_job.items() if k != 'status'), 'report', 'experiment plan changed')
    records, seen = [], set()
    for job in experiment['jobs']:
        if job['status'] != 'complete': continue
        path = (directory / job['csv']).resolve()
        require(path.is_relative_to(directory.resolve()), 'report', 'recording path outside experiment')
        require(hashlib.sha256(path.read_bytes()).hexdigest() == job['sha256'], path, 'recording changed after capture')
        summary = load_run(path)[-1]
        check_expected(summary, job, experiment['config'])
        require(summary['run_id'] not in seen, path, 'duplicate run_id')
        seen.add(summary['run_id'])
        if job['phase'] == 'measurement': records.append((job, summary))
    cells = {}
    for job, summary in records:
        key = (job['pattern'], job['seed'], job['repeat'])
        cell = cells.setdefault(key, {})
        require(job['mode'] not in cell, 'report', 'duplicate mode within paired repeat')
        cell[job['mode']] = summary
    complete_cells = {key: cell for key, cell in cells.items() if set(cell) == set(MODES)}
    for cell in complete_cells.values(): matched(list(cell.values()))
    groups = []
    for pattern, seed in sorted({key[:2] for key in complete_cells}):
        selected = [cell for key, cell in sorted(complete_cells.items()) if key[:2] == (pattern, seed)]
        for mode in MODES:
            values = [measurements(cell[mode]) for cell in selected]
            changes = {}
            if mode != 'baseline':
                for metric in ('allocations', 'peak_owned_bytes', 'latency_p99_us', 'throughput_rps'):
                    # Paired change for each same-seed repeat, then summarize.
                    changes[metric] = describe([100 * (measurements(cell[mode])[metric] - measurements(cell['baseline'])[metric]) /
                                                measurements(cell['baseline'])[metric]
                                                if measurements(cell['baseline'])[metric] else None for cell in selected])
            groups.append({'pattern': pattern, 'seed': seed, 'mode': mode, 'repeats': len(selected),
                           'metrics': {m: describe([v[m] for v in values]) for m in METRICS},
                           'paired_change_percent': changes})
    expected = len(experiment['config']['patterns']) * len(experiment['config']['seeds']) * experiment['config']['repeats']
    if experiment['status'] == 'complete':
        require(all(j['status'] == 'complete' for j in experiment['jobs']) and len(complete_cells) == expected,
                'report', 'complete experiment is missing successful paired runs')
    return {'experiment_status': experiment['status'], 'expected_paired_repeats': expected,
            'complete_paired_repeats': len(complete_cells), 'included_measurements': 3 * len(complete_cells),
            'unpaired_measurements_excluded': len(records) - 3 * len(complete_cells),
            'failed_jobs': [j['job_id'] for j in experiment['jobs'] if j['status'] == 'failed'],
            'groups': groups, 'ai': experiment.get('ai', {'status': 'unknown'}),
            'notes': ['Only complete baseline/pool/cache triples enter comparisons; warmups are excluded.',
                      'Payload peak owned bytes are application buffers, not VM RAM or process RSS.',
                      'Latency statistics describe per-run p99 values, not a pooled request-level p99.',
                      'Throughput includes configured pacing; service latency excludes scheduled waits.',
                      'Percent changes are (mode - paired baseline) / baseline; negative is better except throughput.',
                      'Zero baselines produce missing percent changes. No confidence/significance claim is made.',
                      'Each run starts a fresh process; warmups only exercise the environment and do not prefill measured caches.',
                      'QEMU/host contention and monitoring can affect timings; keep the environment consistent.',
                      'These are static runtime modes, not static/rules/AI policy comparisons.']}


def render_html(report):
    escape = html.escape
    sections = []
    for pattern, seed in sorted({(g['pattern'], g['seed']) for g in report['groups']}):
        groups = [g for g in report['groups'] if (g['pattern'], g['seed']) == (pattern, seed)]
        charts = []
        for metric, label in [('allocations', 'Allocations'), ('peak_owned_bytes', 'Peak payload (bytes)'),
                              ('latency_p99_us', 'Per-run p99 (us)'), ('throughput_rps', 'Throughput (req/s)')]:
            maximum = max(g['metrics'][metric]['max'] for g in groups) or 1
            bars = []
            for g in groups:
                stats = g['metrics'][metric]
                mean, low, high = (stats[k] for k in ('mean', 'min', 'max'))
                y = len(bars) * 60 + 22
                bars.append(f'<text x="0" y="{y}">{escape(g["mode"])}</text>'
                            f'<rect x="85" y="{y-14}" width="{250*mean/maximum:.2f}" height="18" fill="#2867a0"/>'
                            f'<line x1="{85+250*low/maximum:.2f}" x2="{85+250*high/maximum:.2f}" y1="{y-5}" y2="{y-5}" stroke="#111" stroke-width="3"/>'
                            f'<text x="85" y="{y+21}">{mean:.3f} [{low:.3f}, {high:.3f}]</text>')
            charts.append(f'<article><h3>{label}</h3><svg viewBox="0 0 410 195" role="img" aria-label="{label}: mean and min/max">{"".join(bars)}</svg></article>')
        rows = []
        for g in groups:
            for metric, stats in g['metrics'].items():
                change = g['paired_change_percent'].get(metric, {}).get('mean')
                fmt = lambda x: 'N/A' if x is None else f'{x:.4f}'
                rows.append('<tr>' + ''.join(f'<td>{escape(str(x))}</td>' for x in
                            [g['mode'], metric, stats['n'], fmt(stats['mean']), fmt(stats['stdev']), fmt(change)]) + '</tr>')
        sections.append(f'<section><h2>{escape(pattern)} / seed {seed} / {groups[0]["repeats"]} paired repeats</h2><div class="charts">{"".join(charts)}</div>'
                        '<table><tr><th>Mode</th><th>Metric</th><th>N</th><th>Mean</th><th>SD</th><th>Paired change %</th></tr>' + ''.join(rows) + '</table></section>')
    ai = report['ai']
    ai_section = f'<section><h2>Offline AI evaluation</h2><p>Status: {escape(ai["status"])}</p>'
    if ai['status'] == 'complete':
        ai_section += (f'<p>Training examples: {ai["training_examples"]}; held-out examples: {ai["test_examples"]}. '
                       '<a href="ai/report.json">Full AI evaluation</a> | <a href="ai/model.json">Saved model</a></p>')
    else:
        ai_section += f'<p>{escape(ai.get("reason", ai.get("error", "Awaiting runtime measurements.")))}</p>'
    ai_section += '<p>Prediction quality is separate from the runtime comparisons below; no AI policy was applied to QNX.</p></section>'
    return ('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
            '<title>QNX repeated workload comparison</title><style>body{font:16px system-ui;margin:32px;color:#183047;background:#f5f8fb}'
            'section,article{background:white;padding:16px;border:1px solid #d6e1ea;border-radius:8px;margin:12px 0}'
            '.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px}svg{width:100%;font:14px system-ui}'
            'table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:7px;border-bottom:1px solid #ddd;text-align:left}</style>'
            f'<h1>QNX repeated workload comparison</h1><p>Status: <b>{escape(report["experiment_status"])}</b> | '
            f'Paired repeats: {report["complete_paired_repeats"]}/{report["expected_paired_repeats"]} | '
            f'Failed jobs: {len(report["failed_jobs"])} | Unpaired measurements excluded: {report["unpaired_measurements_excluded"]}</p>'
            '<p>Bars = mean; black lines and brackets = min/max. Lower is better except throughput.</p><ul>' +
            ''.join(f'<li>{escape(note)}</li>' for note in report['notes']) + '</ul>' + ai_section + ''.join(sections) + '</html>')


def write_report(experiment, directory):
    report = build_report(experiment, directory)
    save_json(directory / 'report.json', report)
    with (directory / 'report.csv').open('w', newline='', encoding='utf-8') as stream:
        writer = csv.writer(stream)
        writer.writerow(['pattern', 'seed', 'mode', 'metric', 'n', 'mean', 'min', 'max', 'stdev', 'paired_change_percent_mean'])
        for group in report['groups']:
            for metric, stats in group['metrics'].items():
                writer.writerow([group['pattern'], group['seed'], group['mode'], metric] + [stats[k] for k in ('n', 'mean', 'min', 'max', 'stdev')] +
                                [group['paired_change_percent'].get(metric, {}).get('mean')])
    (directory / 'report.html').write_text(render_html(report), encoding='utf-8')
    return report


def provenance():
    paths = [ROOT / 'menu.ps1'] + sorted((ROOT / 'scripts').glob('*workload*.*')) + sorted((ROOT / 'src/workloads').glob('*.*'))
    result = {'host': platform.platform(), 'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()}}
    for key, args in [('git_head', ['rev-parse', 'HEAD']), ('git_status', ['status', '--short'])]:
        try:
            result[key] = subprocess.run(['git'] + args, cwd=ROOT, capture_output=True, text=True, timeout=10, check=True).stdout.strip()
        except (OSError, subprocess.SubprocessError): result[key] = None
    config_path = ROOT / 'qnx.local.json'
    if config_path.exists():
        config = json.loads(config_path.read_text(encoding='utf-8-sig'))
        result['target'] = {key: config.get(key) for key in ('Host', 'Port', 'User', 'Vm', 'SdkEnv', 'Backend')}
    return result


def execute(config, output, runner=run_target):
    jobs = make_plan(config['patterns'], config['seeds'], config['repeats'], config['warmups'])
    output.mkdir(parents=True, exist_ok=False)
    for name in ('raw', 'warmups', 'logs'): (output / name).mkdir()
    experiment = {'version': 1, 'status': 'running', 'config': config, 'provenance': provenance(), 'jobs': jobs, 'ai': {'status': 'pending'}}
    state = output / 'experiment.json'
    save_json(state, experiment)
    completed = []
    try:
        for index, job in enumerate(jobs):
            print(f'[{index+1}/{len(jobs)}] {job["phase"]} {job["pattern"]} seed={job["seed"]} repeat={job["repeat"]+1} {job["mode"]}', flush=True)
            job.update(status='running', started_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
            save_json(state, experiment)
            log = output / 'logs' / (job['job_id'] + '.log')
            job['log'] = str(log.relative_to(output))
            try:
                source = runner(job, config, log, config['timeout'])
                folder = 'raw' if job['phase'] == 'measurement' else 'warmups'
                destination = output / folder / ('workload-' + job['job_id'] + '.csv')
                shutil.copyfile(source, destination)
                job['csv'] = str(destination.relative_to(output))
                job['source_csv'] = str(source)
                job['sha256'] = hashlib.sha256(destination.read_bytes()).hexdigest()
                summary = load_run(destination)[-1]
                check_expected(summary, job, config)
                require(all(s['run_id'] != summary['run_id'] for _, s in completed), job['job_id'], 'runner returned a duplicate run')
                same = [s for j, s in completed if (j['pattern'], j['seed']) == (job['pattern'], job['seed'])]
                matched(same + [summary])
                completed.append((job, summary))
                job.update(status='complete', run_id=summary['run_id'])
            except KeyboardInterrupt:
                job.update(status='failed', error='Interrupted')
                raise
            except (OSError, DataError, subprocess.SubprocessError) as exc:
                job.update(status='failed', error=str(exc))
                raise
            finally:
                save_json(state, experiment)
        experiment['status'] = 'complete'
    except KeyboardInterrupt:
        experiment['status'] = 'interrupted'
    except (OSError, DataError, subprocess.SubprocessError) as exc:
        experiment.update(status='failed', error=str(exc))
    finally:
        save_json(state, experiment)
    report = write_report(experiment, output)
    if experiment['status'] == 'complete' and not config['skip_ai']:
        try:
            recordings = read_recordings([str(output / 'raw')])
            samples = examples(recordings)
            if len({s['group_id'] for s in samples}) < 2:
                experiment['ai'] = {'status': 'skipped', 'reason': 'Need >=2 workload groups with adjacent full windows.'}
            else:
                ai_report = run_pipeline(recordings, output / 'ai')
                experiment['ai'] = {'status': 'complete', 'report': 'ai/report.json',
                                    'training_examples': ai_report['training_examples'], 'test_examples': ai_report['examples']}
        except (OSError, ValueError, OverflowError) as exc:
            experiment['ai'] = {'status': 'failed', 'error': str(exc)}
        except KeyboardInterrupt:
            experiment['ai'] = {'status': 'interrupted', 'error': 'Offline AI stage interrupted; runtime recordings are preserved.'}
    else:
        experiment['ai'] = {'status': 'skipped', 'reason': 'Explicitly disabled or experiment incomplete.'}
    save_json(state, experiment)
    # Refresh the derived report with AI status after the optional offline stage.
    report = write_report(experiment, output)
    print(json.dumps({'output_dir': str(output.resolve()), 'status': experiment['status'],
                      'paired_repeats': report['complete_paired_repeats'], 'ai': experiment['ai']}, indent=2))
    return 0 if experiment['status'] == 'complete' and experiment['ai']['status'] in ('complete', 'skipped') else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--patterns', default='steady,burst,ramp')
    parser.add_argument('--seeds', default='42,43,44')
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--warmups', type=int, default=1)
    parser.add_argument('--requests', type=int, default=200)
    parser.add_argument('--keys', type=int, default=64)
    parser.add_argument('--bytes', type=int, default=4096)
    parser.add_argument('--interval-ms', type=int, default=1)
    parser.add_argument('--sample-every', type=int, default=20)
    parser.add_argument('--pool-blocks', type=int, default=8)
    parser.add_argument('--cache-bytes', type=int, default=32768)
    parser.add_argument('--timeout', type=int, default=180, help='per job, including build/upload; fail fast')
    parser.add_argument('--skip-ai', action='store_true')
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--plan', action='store_true', help='show plan without building or connecting to QNX')
    parser.add_argument('--report-only', type=Path, help='revalidate saved experiment and regenerate reports offline')
    args = parser.parse_args(argv)
    try:
        if args.report_only:
            directory = args.report_only.resolve()
            experiment = json.loads((directory / 'experiment.json').read_text(encoding='utf-8'))
            require(experiment['version'] == 1, 'report', 'unsupported experiment version')
            report = write_report(experiment, directory)
            print(json.dumps({'report': str(directory / 'report.html'), 'paired_repeats': report['complete_paired_repeats']}))
            return 0 if experiment['status'] == 'complete' else 1
        config = {key: getattr(args, key) for key in ('repeats', 'warmups', 'requests', 'keys', 'bytes', 'interval_ms', 'sample_every', 'pool_blocks', 'cache_bytes', 'timeout', 'skip_ai')}
        config.update(patterns=args.patterns.split(','), seeds=[int(s) for s in args.seeds.split(',')])
        for field, minimum, maximum in [('requests', 1, 1000000), ('keys', 1, 1000000), ('bytes', 1, 16777216),
                                        ('interval_ms', 0, 1000), ('sample_every', 1, 1000000), ('pool_blocks', 1, 4096),
                                        ('cache_bytes', 0, 2**32-1), ('timeout', 1, 86400)]:
            require(minimum <= config[field] <= maximum, 'config', f'{field} outside supported range')
        jobs = make_plan(config['patterns'], config['seeds'], config['repeats'], config['warmups'])
        if args.plan:
            print(json.dumps({'config': config, 'total_jobs': len(jobs), 'measurement_jobs': sum(j['phase'] == 'measurement' for j in jobs), 'jobs': jobs}, indent=2))
            return 0
        output = args.output_dir or ROOT / 'measurements' / 'benchmarks' / ('batch-' + uuid.uuid4().hex)
        return execute(config, output)
    except (OSError, DataError, ValueError, KeyError, TypeError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

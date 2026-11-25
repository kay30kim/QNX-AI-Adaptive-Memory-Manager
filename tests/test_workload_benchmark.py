import contextlib
import copy
import csv
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_workload_data import fixture
import workload_benchmark as bench
from workload_data import DataError


def config():
    return dict(patterns=['steady'], seeds=[1, 2], repeats=2, warmups=1,
                requests=2, keys=1, bytes=64, interval_ms=0, sample_every=1,
                pool_blocks=1, cache_bytes=64, timeout=30, skip_ai=False)


def rows_for(job, settings):
    row, summary = fixture()
    row.update(run_id=job['job_id'], mode=job['mode'], pattern=job['pattern'], seed=job['seed'],
               configured_requests=2, sample_every=1)
    if job['mode'] != 'baseline':
        row.update(frees=0, pool_blocks=1, pool_capacity_bytes=64, pool_misses=1, retained_buffer_bytes=64)
    if job['mode'] == 'cache':
        row.update(cache_capacity_bytes=64, cache_effective_capacity_bytes=64,
                   cache_hits=0, cache_misses=1, cache_bytes=64, cache_entries=1,
                   live_buffer_bytes=64, retained_buffer_bytes=0)
    second = dict(row, window_index=1, start_ns=1000000, end_ns=2000000)
    if job['mode'] != 'baseline':
        second.update(allocation_calls=0, allocations=0, allocated_bytes=0, pool_misses=0, pool_hits=1)
    if job['mode'] == 'cache': second.update(cache_hits=1, cache_misses=0, pool_hits=0)
    summary = dict(second, row_type='summary', window_index=0, start_ns=0, elapsed_seconds=.002,
                   sequence_hash='abc', result_checksum=1, cleanup_frees=int(job['mode'] != 'baseline'), post_cleanup_owned_bytes=0)
    from workload_data import ADDITIVE
    for key in ADDITIVE:
        if key in summary and summary[key] is not None: summary[key] = row[key] + second[key]
    return [row, second, summary]


class BenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'sources'
        self.source.mkdir()

    def runner(self, job, settings, log, timeout):
        path = self.source / (job['job_id'] + '.csv')
        rows = rows_for(job, settings)
        with path.open('w', newline='', encoding='utf-8') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        log.write_text('test runner\n')
        return path

    def execute(self, settings=None, runner=None):
        output = self.root / 'experiment'
        with contextlib.redirect_stdout(io.StringIO()):
            code = bench.execute(settings or config(), output, runner or self.runner)
        return code, output, json.loads((output / 'experiment.json').read_text())

    def test_default_plan_counts_and_rotating_order(self):
        jobs = bench.make_plan(['steady', 'burst', 'ramp'], [42, 43, 44], 3, 1)
        self.assertEqual(len(jobs), 108)
        self.assertEqual(sum(j['phase'] == 'measurement' for j in jobs), 81)
        modes = [j['mode'] for j in jobs if j['phase'] == 'measurement' and j['pattern'] == 'steady' and j['seed'] == 42]
        self.assertEqual(modes, ['baseline', 'pool', 'cache', 'pool', 'cache', 'baseline', 'cache', 'baseline', 'pool'])
        self.assertEqual(len({j['job_id'] for j in jobs}), 108)

    def test_reject_invalid_plan(self):
        for patterns, seeds, repeats, warmups in [(['bad'], [1], 1, 0), (['steady']*2, [1], 1, 0),
                                                 (['steady'], [1, 1], 1, 0), (['steady'], [-1], 1, 0),
                                                 (['steady'], [1], 0, 0), (['steady'], [1], 1, -1)]:
            with self.assertRaises(DataError): bench.make_plan(patterns, seeds, repeats, warmups)

    def test_statistics_and_missing_values(self):
        self.assertEqual(bench.describe([1, 3]), dict(n=2, mean=2, min=1, max=3, stdev=2**.5))
        self.assertIsNone(bench.describe([1])['stdev'])
        self.assertIsNone(bench.describe([None, None])['mean'])
        self.assertEqual(bench.describe([0])['mean'], 0)

    def test_complete_report_warmup_exclusion_and_ai(self):
        code, output, experiment = self.execute()
        self.assertEqual(code, 0)
        self.assertEqual(experiment['status'], 'complete')
        self.assertEqual(experiment['ai']['status'], 'complete')
        report = json.loads((output / 'report.json').read_text())
        self.assertEqual(report['complete_paired_repeats'], 4)
        self.assertEqual(report['included_measurements'], 12)
        self.assertEqual(len(list((output / 'warmups').glob('*.csv'))), 6)
        self.assertEqual(len(list((output / 'raw').glob('*.csv'))), 12)
        pool = next(g for g in report['groups'] if g['mode'] == 'pool')
        self.assertEqual(pool['paired_change_percent']['allocations']['mean'], -50)
        self.assertEqual(pool['metrics']['allocations']['n'], 2)
        self.assertIsNone(pool['metrics']['cache_hit_ratio']['mean'])
        self.assertIn('Per-run p99', (output / 'report.html').read_text())
        ai_manifest = json.loads((output / 'ai/manifest.json').read_text())
        self.assertEqual(len(ai_manifest), 12)
        self.assertEqual(bench.build_report(experiment, output), report)
        with self.assertRaises(FileExistsError): bench.execute(config(), output, self.runner)

    def test_fail_fast_excludes_unpaired_preserves_failure_log(self):
        def fail(job, settings, log, timeout):
            if job['phase'] == 'measurement' and job['mode'] == 'cache':
                log.write_text('SSH failed')
                raise DataError('SSH failed')
            return self.runner(job, settings, log, timeout)
        code, output, experiment = self.execute(runner=fail)
        self.assertEqual(code, 1)
        self.assertEqual(experiment['status'], 'failed')
        report = json.loads((output / 'report.json').read_text())
        self.assertEqual(report['included_measurements'], 0)
        self.assertEqual(report['unpaired_measurements_excluded'], 2)
        self.assertEqual(len(report['failed_jobs']), 1)
        self.assertEqual(experiment['ai']['status'], 'skipped')
        self.assertTrue(any(j['status'] == 'pending' for j in experiment['jobs']))

    def test_mismatched_result_or_sequence_rejected(self):
        job = bench.make_plan(['steady'], [1], 1, 0)[0]
        first = rows_for(job, config())[-1]
        for field, value in [('result_checksum', 999), ('sequence_hash', 'ffff'), ('seed', 2)]:
            with self.assertRaises(DataError): bench.matched([first, dict(first, **{field: value})])

    def test_capture_configuration_and_integrity(self):
        code, output, experiment = self.execute()
        job = experiment['jobs'][0]
        path = output / job['csv']
        path.write_text(path.read_text() + '\n')
        with self.assertRaises(DataError): bench.build_report(experiment, output)
        summary = rows_for(job, config())[-1]
        with self.assertRaises(DataError): bench.check_expected(dict(summary, keys=2), job, config())

    def test_complete_manifest_cannot_hide_missing_jobs(self):
        _, output, experiment = self.execute()
        changed = copy.deepcopy(experiment)
        changed['jobs'].pop()
        with self.assertRaises(DataError): bench.build_report(changed, output)
        changed = copy.deepcopy(experiment)
        changed['jobs'][-1]['status'] = 'failed'
        with self.assertRaises(DataError): bench.build_report(changed, output)

    def test_single_group_skips_ai(self):
        settings = dict(config(), seeds=[1], repeats=1, warmups=0)
        code, output, experiment = self.execute(settings)
        self.assertEqual(code, 0)
        self.assertEqual(experiment['ai']['status'], 'skipped')

    def test_zero_baseline_throughput_produces_missing_change(self):
        def zero_duration(job, settings, log, timeout):
            path = self.runner(job, settings, log, timeout)
            with path.open(newline='') as stream: rows = list(csv.DictReader(stream))
            for row in rows:
                for field in ('start_ns', 'end_ns', 'elapsed_seconds', 'throughput_rps',
                              'latency_p50_us', 'latency_p95_us', 'latency_p99_us', 'latency_max_us', 'start_lateness_p99_us'):
                    row[field] = '0'
            with path.open('w', newline='') as stream:
                writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
                writer.writeheader()
                writer.writerows(rows)
            return path
        code, output, _ = self.execute(dict(config(), skip_ai=True), zero_duration)
        self.assertEqual(code, 0)
        report = json.loads((output / 'report.json').read_text())
        pool = next(g for g in report['groups'] if g['mode'] == 'pool')
        self.assertEqual(pool['paired_change_percent']['throughput_rps']['n'], 0)
        self.assertIsNone(pool['paired_change_percent']['throughput_rps']['mean'])

    def test_timeout_is_recorded(self):
        def timeout(job, settings, log, seconds):
            raise subprocess.TimeoutExpired('runner', seconds)
        code, output, experiment = self.execute(runner=timeout)
        self.assertEqual(code, 1)
        self.assertEqual(experiment['jobs'][0]['status'], 'failed')
        self.assertIn('timed out', experiment['jobs'][0]['error'])

    def test_interrupt_persists_partial_state(self):
        def interrupted(job, settings, log, seconds): raise KeyboardInterrupt
        code, output, experiment = self.execute(runner=interrupted)
        self.assertEqual(code, 1)
        self.assertEqual(experiment['status'], 'interrupted')
        self.assertEqual(experiment['jobs'][0]['error'], 'Interrupted')

    def test_ai_interrupt_preserves_runtime_report_and_returns_failure(self):
        with patch.object(bench, 'run_pipeline', side_effect=KeyboardInterrupt):
            code, output, experiment = self.execute()
        self.assertEqual(code, 1)
        self.assertEqual(experiment['status'], 'complete')
        self.assertEqual(experiment['ai']['status'], 'interrupted')
        self.assertEqual(json.loads((output / 'report.json').read_text())['included_measurements'], 12)

    def test_cli_plan_is_offline_and_invalid_config_fails(self):
        output = self.root / 'plan-only'
        with patch.object(bench, 'run_target', side_effect=AssertionError('must not run')), contextlib.redirect_stdout(io.StringIO()) as stdout:
            self.assertEqual(bench.main(['--plan', '--output-dir', str(output)]), 0)
        self.assertEqual(json.loads(stdout.getvalue())['measurement_jobs'], 81)
        self.assertFalse(output.exists())
        with contextlib.redirect_stderr(io.StringIO()): self.assertEqual(bench.main(['--bytes', '0', '--plan']), 1)

    def test_runner_requires_exact_output_marker(self):
        log = self.root / 'runner.log'
        job = bench.make_plan(['steady'], [1], 1, 0)[0]
        expected = bench.ROOT / 'measurements/workload-marker.csv'
        def emit(command, log_path, timeout):
            self.assertIn('measure-workload.ps1', command[5])
            log_path.write_text(f'Other output\nQNX_METRICS_PATH={expected}\n')
        with patch.object(bench, 'run_process', side_effect=emit):
            self.assertEqual(bench.run_target(job, config(), log, 30), expected.resolve())
        for content in ('Saved workload metrics only', f'QNX_METRICS_PATH={expected}\nQNX_METRICS_PATH={expected}',
                        f'QNX_METRICS_PATH={self.root / "outside.csv"}'):
            with patch.object(bench, 'run_process', side_effect=lambda *args: log.write_text(content)):
                with self.assertRaises(DataError): bench.run_target(job, config(), log, 30)

    def test_offline_report_cli(self):
        _, output, _ = self.execute()
        expected = (output / 'report.csv').read_bytes()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(bench.main(['--report-only', str(output)]), 0)
        self.assertEqual((output / 'report.csv').read_bytes(), expected)
        self.assertIn('ai/report.json', (output / 'report.html').read_text())


if __name__ == '__main__':
    unittest.main()

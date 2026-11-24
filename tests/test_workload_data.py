import contextlib
import csv
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import workload_data as data


def fixture(version=3):
    row = dict.fromkeys(data.SCHEMAS[version], 0)
    row.update(schema_version=version, run_id='test-run', row_type='window', status='complete',
               mode='baseline', pattern='steady', configured_requests=1, keys=1,
               block_bytes=64, sample_every=1, end_ns=1000000, attempted=1, completed=1,
               allocation_calls=1, allocations=1, frees=1, allocated_bytes=64,
               peak_live_buffer_bytes=64, elapsed_seconds=.001, throughput_rps=1000)
    for field in data.OPTIONAL:
        if field in row: row[field] = None
    for field in data.LATENCIES: row[field] = 10
    if version >= 2: row['peak_owned_buffer_bytes'] = 64
    summary = dict(row, row_type='summary', sequence_hash='abc', result_checksum=1)
    if version >= 2: summary.update(cleanup_frees=0, post_cleanup_owned_bytes=0)
    return [row, summary]


class DataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / 'workload-test.csv'

    def write(self, rows, header=None, path=None):
        with (path or self.path).open('w', newline='', encoding='utf-8') as f:
            writer = csv.DictWriter(f, fieldnames=header or list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)

    def test_supported_versions(self):
        for version in (1, 2, 3):
            with self.subTest(version=version):
                self.write(fixture(version))
                self.assertEqual(data.load_run(self.path), fixture(version))

    def test_corrupt_fields_rejected(self):
        mutations = dict(schema_version=4, mode='unknown', run_id='bad id',
                         completed=2, allocations=2, allocated_bytes=65,
                         throughput_rps=5, elapsed_seconds='NaN', latency_p99_us=11,
                         cache_hits=0, window_index=1, start_ns=1,
                         block_bytes=-1, attempted=2, live_buffer_bytes=64,
                         seed=2**64, sequence_hash='abc', cleanup_frees=0)
        for key, value in mutations.items():
            with self.subTest(field=key):
                rows = fixture()
                rows[0][key] = value
                self.write(rows)
                with self.assertRaises(data.DataError): data.load_run(self.path)

    def test_pool_and_cache_ownership(self):
        for mode, budget in [('pool', 0), ('cache', 0), ('cache', 64)]:
            with self.subTest(mode=mode, budget=budget):
                rows = fixture()
                for r in rows:
                    r.update(mode=mode, frees=0, pool_blocks=1, pool_capacity_bytes=64,
                             pool_misses=1, retained_buffer_bytes=64)
                    if mode == 'cache':
                        r.update(cache_hits=0, cache_misses=1, cache_capacity_bytes=budget,
                                 cache_effective_capacity_bytes=budget, cache_bytes=budget,
                                 cache_entries=budget // 64, cache_bypasses=int(budget == 0),
                                 live_buffer_bytes=budget, retained_buffer_bytes=64-budget)
                rows[-1]['cleanup_frees'] = 1
                self.write(rows)
                self.assertEqual(data.load_run(self.path), rows)
                rows[0]['retained_buffer_bytes'] += 1
                self.write(rows)
                with self.assertRaises(data.DataError): data.load_run(self.path)

    def test_multiple_windows_in_recorded_order(self):
        first, summary = fixture()
        first['configured_requests'] = summary['configured_requests'] = 2
        second = dict(first, window_index=1, start_ns=1000000, end_ns=2000000)
        summary.update(end_ns=2000000, elapsed_seconds=.002)
        for field in data.ADDITIVE:
            if field in summary and summary[field] is not None: summary[field] *= 2
        self.write([first, second, summary])
        rows = data.load_run(self.path)
        self.assertEqual([r['window_index'] for r in data.replay_records(rows)], [0, 1])
        self.write([second, first, summary])
        with self.assertRaises(data.DataError): data.load_run(self.path)

    def test_truncated_and_reordered(self):
        for rows in (fixture()[:1], fixture()[::-1], fixture() + fixture()):
            self.write(rows)
            with self.assertRaises(data.DataError): data.load_run(self.path, True)

    def test_interrupted_requires_opt_in(self):
        rows = fixture()
        for r in rows: r.update(status='interrupted', configured_requests=2)
        self.write(rows)
        with self.assertRaises(data.DataError): data.load_run(self.path)
        self.assertEqual(data.load_run(self.path, True)[-1]['completed'], 1)

    def test_summary_and_cleanup(self):
        for key, value in [('cleanup_frees', 1), ('post_cleanup_owned_bytes', 64),
                           ('run_id', 'other'), ('peak_live_buffer_bytes', 128)]:
            rows = fixture()
            rows[-1][key] = value
            self.write(rows)
            with self.assertRaises(data.DataError): data.load_run(self.path)

    def test_bad_headers_and_columns(self):
        for content in ('a,a\n1,2\n', 'cpu,ram\n1,2\n', 'schema_version\n3,extra\n', ''):
            self.path.write_text(content)
            with self.assertRaises(data.DataError): data.load_run(self.path)

    def test_replay_timing_and_nulls(self):
        rows = fixture()
        for speed in (0, 1, 10):
            now = [0.0]
            def sleep(seconds): now[0] += seconds
            result = list(data.replay_records(rows, speed, clock=lambda: now[0], sleep=sleep))
            self.assertEqual(result, rows[:1])
            self.assertIsNone(result[0]['cache_hits'])
            self.assertAlmostEqual(now[0], .001 / speed if speed else 0)
        self.assertEqual(list(data.replay_records(rows, include_summary=True)), rows)
        for speed in (-1, float('nan'), float('inf')):
            with self.assertRaises(data.DataError): list(data.replay_records(rows, speed))

    def invoke(self, args):
        with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            code = data.main(args)
        return code, out.getvalue()

    def test_output_validation_and_no_overwrite(self):
        output = self.root / 'events.jsonl'
        self.write(fixture()[:1])
        args = ['replay', str(self.path), '--output', str(output)]
        self.assertEqual(self.invoke(args)[0], 1)
        self.assertFalse(output.exists())
        self.write(fixture())
        self.assertEqual(self.invoke(args)[0], 0)
        saved = output.read_bytes()
        event = json.loads(saved)
        self.assertEqual(event['event_index'], 0)
        self.assertIsNone(event['record']['cache_hits'])
        self.assertEqual(self.invoke(args)[0], 1)
        self.assertEqual(saved, output.read_bytes())

    def test_directory_selection_and_duplicate_runs(self):
        self.write(fixture())
        (self.root / 'qnx-metrics.csv').write_text('not workload')
        (self.root / 'workload-incomplete.csv.partial').write_text('partial')
        self.assertEqual(data.resolve_inputs([str(self.root)]), [self.path.resolve()])
        self.write(fixture(), path=self.root / 'workload-copy.csv')
        code, output = self.invoke(['validate', str(self.root)])
        self.assertEqual(code, 1)
        self.assertIn('duplicate run_id', json.loads(output)['errors'][0])


if __name__ == '__main__':
    unittest.main()

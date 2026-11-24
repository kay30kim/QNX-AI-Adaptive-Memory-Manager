import contextlib
import copy
import csv
import io
import json
from pathlib import Path
import tempfile
import unittest

from test_workload_data import fixture
import workload_ai as ai
import workload_data as data


def recording(seed=1, version=3, count=4):
    template, summary = fixture(version)
    template.update(run_id=f'run-{seed}', seed=seed, configured_requests=count)
    rows = []
    for i in range(count):
        row = dict(template, window_index=i, start_ns=i * 1000000, end_ns=(i + 1) * 1000000)
        for field in data.LATENCIES: row[field] = 10 + i
        rows.append(row)
    summary = dict(rows[-1], row_type='summary', window_index=0, start_ns=0,
                   elapsed_seconds=count * .001, sequence_hash='abc', result_checksum=1)
    for field in data.ADDITIVE:
        if field in summary and summary[field] is not None:
            summary[field] = sum(r[field] for r in rows)
    if version >= 2: summary.update(cleanup_frees=0, post_cleanup_owned_bytes=0)
    return rows + [summary]


class AITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, rows, name=None):
        path = self.root / (name or f"workload-{rows[0]['run_id']}.csv")
        with path.open('w', newline='', encoding='utf-8') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        return path

    def runs(self):
        for seed in (1, 2, 3, 4): self.write(recording(seed))
        return ai.read_recordings([str(self.root)])

    def invoke(self, args):
        with contextlib.redirect_stdout(io.StringIO()) as stdout, contextlib.redirect_stderr(io.StringIO()) as stderr:
            code = ai.main(args)
        return code, stdout.getvalue(), stderr.getvalue()

    def test_next_window_alignment_and_no_future_features(self):
        runs = self.runs()
        samples = ai.examples(runs)
        self.assertEqual(len(samples), 12)
        self.assertEqual(samples[0]['features']['latency_p99_us'], 10)
        self.assertEqual(samples[0]['targets'], [64, 11])
        self.assertEqual(samples[0]['observed_end_ns'], 1000000)
        self.assertEqual(samples[0]['target_end_ns'], 2000000)
        changed = copy.deepcopy(runs)
        changed[0]['windows'][1]['latency_p99_us'] = 999
        self.assertEqual(ai.examples(changed)[0]['features'], samples[0]['features'])
        self.assertEqual(ai.examples(changed)[0]['targets'][1], 999)
        self.assertFalse(set(ai.FEATURES) & {'run_id', 'seed', 'sequence_hash', 'result_checksum'})

    def test_short_tail_and_single_window_have_no_labels(self):
        path = self.write(recording(count=1))
        runs = ai.read_recordings([str(path)])
        self.assertEqual(ai.examples(runs), [])
        runs[0]['windows'].append(dict(runs[0]['windows'][0], attempted=0))
        self.assertEqual(ai.examples(runs), [])

    def test_schema_compatibility_and_missing_not_zero(self):
        for version in (1, 2, 3):
            path = self.write(recording(version=version))
            sample = ai.examples(ai.read_recordings([str(path)]))[0]
            self.assertEqual(sample['features']['peak_owned_bytes'], 64)
            self.assertIsNone(sample['features']['cache_hit_ratio'])
            self.assertEqual(sample['features']['pool_capacity_bytes'], None if version == 1 else 0)

    def test_grouping_ignores_mode_schema_sampling_and_prefix_length(self):
        row = recording()[0]
        changed = dict(row, mode='cache', schema_version=1, configured_requests=500, sample_every=100)
        self.assertEqual(ai.group_id(row), ai.group_id(changed))
        self.assertNotEqual(ai.group_id(row), ai.group_id(dict(row, seed=9)))

    def test_split_is_reproducible_and_group_disjoint(self):
        samples = ai.examples(self.runs())
        train, test = ai.split_examples(samples)
        again_train, again_test = ai.split_examples(list(reversed(samples)))
        self.assertEqual({s['run_id'] for s in train}, {s['run_id'] for s in again_train})
        self.assertEqual({s['run_id'] for s in test}, {s['run_id'] for s in again_test})
        self.assertFalse({s['group_id'] for s in train} & {s['group_id'] for s in test})
        for fraction in (0, 1, float('nan'), float('inf')):
            with self.assertRaises(data.DataError): ai.split_examples(samples, test_fraction=fraction)
        with self.assertRaises(data.DataError): ai.split_examples(samples[:3])

    def test_train_only_preprocessing_and_missing_mask(self):
        train, test = ai.split_examples(ai.examples(self.runs()))
        pre = ai.fit_preprocessor(train)
        test[0]['features']['latency_p99_us'] = 1e9
        self.assertEqual(ai.fit_preprocessor(train), pre)
        index = ai.FEATURES.index('cache_hit_ratio')
        vector = ai.transform(train[0]['features'], pre)
        self.assertEqual(vector[index], 0)
        self.assertEqual(vector[len(ai.FEATURES) + index], 1)
        observed_zero = dict(train[0]['features'], cache_hit_ratio=0)
        self.assertEqual(ai.transform(observed_zero, pre)[len(ai.FEATURES) + index], 0)

    def test_ridge_against_analytic_solution_and_constant_target(self):
        samples = []
        for x in (1, 2, 3):
            values = dict.fromkeys(ai.FEATURES, 0)
            values['throughput_rps'] = x
            samples.append(dict(features=values, targets=[2*x+3, 7], run_id='r', group_id='g', mode='baseline', pattern='steady'))
        model = ai.fit_model(samples, alpha=1)
        # Standardized sum(x^2)=3: ridge shrinks slope by 3/(3+1).
        self.assertAlmostEqual(ai.predict(model, samples[0]['features'])[0], 5.5)
        self.assertAlmostEqual(ai.predict(model, samples[2]['features'])[0], 8.5)
        self.assertAlmostEqual(ai.predict(model, samples[0]['features'])[1], 7)
        for alpha in (0, -1, float('nan'), float('inf')):
            with self.assertRaises(data.DataError): ai.fit_model(samples, alpha)

    def test_metrics_in_original_units(self):
        scores = ai.metrics([[10, 2], [20, 4]], [[12, 1], [16, 5]])
        self.assertEqual(scores[ai.TARGETS[0]]['mae'], 3)
        self.assertAlmostEqual(scores[ai.TARGETS[0]]['rmse'], 10**.5)
        self.assertEqual(scores[ai.TARGETS[1]]['mae'], 1)

    def test_pipeline_artifacts_reload_and_reproducibility(self):
        runs = self.runs()
        before = {r['path']: Path(r['path']).read_bytes() for r in runs}
        output = self.root / 'result'
        report = ai.run_pipeline(runs, output)
        model = ai.load_model(output / 'model.json')
        self.assertEqual(report['training_examples'], 9)
        self.assertEqual(report['examples'], 3)
        self.assertEqual(set(report['metrics']), {'ridge', 'persistence', 'training_mean'})
        events = [json.loads(line) for line in (output / 'predictions.jsonl').read_text().splitlines()]
        self.assertEqual(ai.predict(model, events[0]['features']), events[0]['prediction'])
        self.assertEqual(len(json.loads((output / 'manifest.json').read_text())), 4)
        self.assertEqual(len((output / 'features.jsonl').read_text().splitlines()), 12)
        second = self.root / 'second'
        ai.run_pipeline(runs, second)
        for name in ('model.json', 'report.json', 'features.jsonl', 'predictions.jsonl'):
            self.assertEqual((output / name).read_bytes(), (second / name).read_bytes())
        for path, content in before.items(): self.assertEqual(Path(path).read_bytes(), content)
        with self.assertRaises(FileExistsError): ai.run_pipeline(runs, output)

    def test_held_out_evaluation_rejects_training_groups(self):
        samples = ai.examples(self.runs())
        training, testing = ai.split_examples(samples)
        model = ai.fit_model(training)
        with self.assertRaises(data.DataError): ai.evaluate(model, training)
        renamed = copy.deepcopy(training)
        for s in renamed: s['run_id'] += '-renamed'
        with self.assertRaises(data.DataError): ai.evaluate(model, renamed)
        self.assertEqual(ai.evaluate(model, testing)[0]['examples'], len(testing))

    def test_changing_heldout_values_cannot_change_fitted_model(self):
        runs = self.runs()
        first = self.root / 'before'
        report = ai.run_pipeline(runs, first)
        for run in runs:
            if run['run_id'] in report['run_ids']:
                for row in run['windows']:
                    for field in data.LATENCIES: row[field] += 500
        second = self.root / 'after'
        changed = ai.run_pipeline(runs, second)
        self.assertEqual((first / 'model.json').read_bytes(), (second / 'model.json').read_bytes())
        self.assertNotEqual(report['metrics'], changed['metrics'])

    def test_cli_train_predict_evaluate_and_failures(self):
        self.runs()
        output = self.root / 'trained'
        args = ['train', str(self.root), '--output-dir', str(output)]
        self.assertEqual(self.invoke(args)[0], 0)
        self.assertEqual(self.invoke(args)[0], 1)
        model = output / 'model.json'
        inference = self.root / 'inference'
        self.assertEqual(self.invoke(['predict', str(self.root), '--model', str(model), '--output-dir', str(inference)])[0], 0)
        self.assertEqual(len((inference / 'predictions.jsonl').read_text().splitlines()), 4)
        evaluation = self.root / 'eval'
        self.assertEqual(self.invoke(['evaluate', str(self.root), '--model', str(model), '--output-dir', str(evaluation)])[0], 1)
        self.assertFalse(evaluation.exists())
        heldout = json.loads((output / 'report.json').read_text())['run_ids'][0]
        self.assertEqual(self.invoke(['evaluate', str(self.root / f'workload-{heldout}.csv'), '--model', str(model), '--output-dir', str(evaluation)])[0], 0)

    def test_invalid_input_rejected_before_outputs(self):
        path = self.write(recording())
        output = self.root / 'failed'
        self.assertEqual(self.invoke(['train', str(path), '--output-dir', str(output)])[0], 1)
        self.assertFalse(output.exists())
        self.write(recording(), name='workload-copy.csv')
        with self.assertRaises(data.DataError): ai.read_recordings([str(self.root)])
        path.write_text('bad csv')
        self.assertEqual(self.invoke(['train', str(path), '--output-dir', str(output)])[0], 1)
        self.assertFalse(output.exists())

    def test_invalid_saved_model(self):
        train, _ = ai.split_examples(ai.examples(self.runs()))
        model = ai.fit_model(train)
        for key, value in [('model_version', 999), ('weights', [[1]]), ('target_means', [float('nan'), 0]), ('training_group_ids', [])]:
            broken = dict(model, **{key: value})
            path = self.root / 'model.json'
            path.write_text(json.dumps(broken))
            with self.assertRaises(data.DataError): ai.load_model(path)


if __name__ == '__main__':
    unittest.main()

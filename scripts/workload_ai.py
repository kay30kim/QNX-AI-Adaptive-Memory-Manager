"""Offline next-window workload prediction; no target policy changes."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys
import uuid

from workload_data import DataError, load_run, require, resolve_inputs

VERSION = 1
TARGETS = ['next_peak_owned_bytes', 'next_latency_p99_us']
# Only information available at the END of the current window is used.
FEATURES = [
    'mode_baseline', 'mode_pool', 'mode_cache', 'block_bytes', 'keys',
    'sample_every', 'interval_ms', 'completed', 'elapsed_seconds',
    'throughput_rps', 'latency_p99_us', 'start_lateness_p99_us',
    'peak_owned_bytes', 'live_buffer_bytes', 'retained_buffer_bytes',
    'allocations_per_request', 'pool_capacity_bytes', 'pool_hit_ratio',
    'cache_effective_capacity_bytes', 'cache_bytes', 'cache_hit_ratio',
]
# Keep repeated request streams / prefixes together, even across runtime modes,
# CSV versions, request counts and sampling cadences. Not a model input.
GROUP_FIELDS = ['pattern', 'seed', 'keys', 'block_bytes', 'interval_ms']


def group_id(row):
    values = [row[f] for f in GROUP_FIELDS]
    return hashlib.sha256(json.dumps(values).encode('utf-8')).hexdigest()


def peak_owned(row):
    # Schema 1 is baseline only: every live allocation is immediately freed.
    return row.get('peak_owned_buffer_bytes', row['peak_live_buffer_bytes'])


def features(row):
    result = {f: row.get(f) for f in FEATURES}
    for mode in ('baseline', 'pool', 'cache'):
        result['mode_' + mode] = int(row['mode'] == mode)
    result['peak_owned_bytes'] = peak_owned(row)
    result['allocations_per_request'] = row['allocations'] / row['attempted']
    for prefix in ('pool', 'cache'):
        hits, misses = row.get(prefix + '_hits'), row.get(prefix + '_misses')
        result[prefix + '_hit_ratio'] = (hits / (hits + misses)
                                         if hits is not None and misses is not None and hits + misses else None)
    return result


def read_recordings(arguments):
    recordings, seen = [], set()
    for path in sorted(resolve_inputs(arguments)):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        rows = load_run(path)  # Complete, validated runs only; no summary features.
        require(digest == hashlib.sha256(path.read_bytes()).hexdigest(), path, 'input changed during reading')
        summary = rows[-1]
        require(summary['run_id'] not in seen, path, 'duplicate run_id')
        seen.add(summary['run_id'])
        recordings.append({'path': str(path), 'sha256': digest, 'run_id': summary['run_id'],
                           'group_id': group_id(summary), 'mode': summary['mode'],
                           'pattern': summary['pattern'], 'schema_version': summary['schema_version'],
                           'windows': rows[:-1]})
    return recordings


def examples(recordings):
    result = []
    for run in recordings:
        windows = run['windows']
        for current, following in zip(windows, windows[1:]):
            # A short last window has a different statistical horizon. Keep it
            # in the source manifest, but do not train/evaluate a full-window forecast on it.
            if current['attempted'] != current['sample_every'] or following['attempted'] != current['sample_every']:
                continue
            require(current['elapsed_seconds'] > 0 and following['elapsed_seconds'] > 0,
                    run['path'], 'zero-duration window cannot be used for prediction')
            result.append({'run_id': run['run_id'], 'group_id': run['group_id'],
                           'mode': run['mode'], 'pattern': run['pattern'],
                           'window_index': current['window_index'],
                           'target_window_index': following['window_index'],
                           'observed_end_ns': current['end_ns'],
                           'target_end_ns': following['end_ns'],
                           'features': features(current),
                           'targets': [peak_owned(following), following['latency_p99_us']],
                           'persistence': [peak_owned(current), current['latency_p99_us']]})
    return result


def split_examples(samples, seed=42, test_fraction=.25):
    require(math.isfinite(test_fraction) and 0 < test_fraction < 1, 'split', 'test fraction must be between 0 and 1')
    groups = sorted({s['group_id'] for s in samples},
                    key=lambda g: hashlib.sha256(f'{seed}:{g}'.encode()).hexdigest())
    require(len(groups) >= 2, 'split', 'need at least two workload groups with adjacent full windows; collect different seeds or request conditions')
    count = min(len(groups) - 1, max(1, math.ceil(len(groups) * test_fraction)))
    held_out = set(groups[:count])
    return ([s for s in samples if s['group_id'] not in held_out],
            [s for s in samples if s['group_id'] in held_out])


def fit_preprocessor(samples):
    means, scales, available = [], [], []
    for name in FEATURES:
        values = [s['features'][name] for s in samples if s['features'][name] is not None]
        mean = math.fsum(values) / len(values) if values else 0.0
        scale = math.sqrt(math.fsum((v - mean)**2 for v in values) / len(values)) if values else 0.0
        means.append(mean)
        scales.append(scale if scale > 1e-12 else 1.0)
        available.append(bool(values))
    return {'means': means, 'scales': scales, 'available': available}


def transform(values, preprocessor):
    vector, missing = [], []
    for i, name in enumerate(FEATURES):
        value = values[name]
        vector.append(0.0 if value is None else (value - preprocessor['means'][i]) / preprocessor['scales'][i])
        missing.append(float(value is None))
    return vector + missing


def solve_positive_definite(matrix, rhs):
    """Cholesky solve for the strictly positive ridge normal matrix."""
    n = len(rhs)
    lower = [[0.0] * n for _ in range(n)]
    for i in range(n):
        for j in range(i + 1):
            value = matrix[i][j] - math.fsum(lower[i][k] * lower[j][k] for k in range(j))
            if i == j:
                require(value > 0 and math.isfinite(value), 'model', 'ill-conditioned fit; increase alpha')
                lower[i][j] = math.sqrt(value)
            else:
                lower[i][j] = value / lower[j][j]
    forward, solution = [0.0] * n, [0.0] * n
    for i in range(n):
        forward[i] = (rhs[i] - math.fsum(lower[i][j] * forward[j] for j in range(i))) / lower[i][i]
    for i in reversed(range(n)):
        solution[i] = (forward[i] - math.fsum(lower[j][i] * solution[j] for j in range(i + 1, n))) / lower[i][i]
    return solution


def fit_model(training, alpha=1.0):
    require(training, 'training', 'no training examples')
    require(math.isfinite(alpha) and alpha >= 1e-8, 'training', 'alpha must be finite and >= 1e-8')
    preprocessor = fit_preprocessor(training)
    matrix = [transform(s['features'], preprocessor) for s in training]
    n, width = len(matrix), len(matrix[0])
    centers = [math.fsum(row[j] for row in matrix) / n for j in range(width)]
    centered = [[v - c for v, c in zip(row, centers)] for row in matrix]
    gram = [[math.fsum(row[i] * row[j] for row in centered) + (alpha if i == j else 0)
             for j in range(width)] for i in range(width)]
    targets, weights = [], []
    for index in range(len(TARGETS)):
        mean = math.fsum(s['targets'][index] for s in training) / n
        rhs = [math.fsum(row[j] * (s['targets'][index] - mean) for row, s in zip(centered, training))
               for j in range(width)]
        targets.append(mean)
        weights.append(solve_positive_definite(gram, rhs))
    return {'model_version': VERSION, 'algorithm': 'standardized_ridge', 'alpha': alpha,
            'feature_names': FEATURES, 'target_names': TARGETS, 'preprocessor': preprocessor,
            'centers': centers, 'target_means': targets, 'weights': weights,
            'training_run_ids': sorted({s['run_id'] for s in training}),
            'training_group_ids': sorted({s['group_id'] for s in training}),
            'training_modes': sorted({s['mode'] for s in training}),
            'training_patterns': sorted({s['pattern'] for s in training})}


def predict(model, values):
    vector = transform(values, model['preprocessor'])
    result = [mean + math.fsum(w * (v - c) for w, v, c in zip(weights, vector, model['centers']))
              for mean, weights in zip(model['target_means'], model['weights'])]
    require(all(math.isfinite(x) for x in result), 'prediction', 'non-finite prediction')
    return [max(0.0, x) for x in result]


def load_model(path):
    try:
        model = json.loads(Path(path).read_text(encoding='utf-8'))
        require(model['model_version'] == VERSION and model['algorithm'] == 'standardized_ridge'
                and model['feature_names'] == FEATURES and model['target_names'] == TARGETS,
                path, 'unsupported model/feature schema')
        width = 2 * len(FEATURES)
        arrays = [(model['preprocessor']['means'], len(FEATURES)),
                  (model['preprocessor']['scales'], len(FEATURES)), (model['centers'], width),
                  (model['target_means'], len(TARGETS))]
        require(len(model['weights']) == len(TARGETS), path, 'invalid target weights')
        arrays += [(w, width) for w in model['weights']]
        for values, length in arrays:
            require(isinstance(values, list) and len(values) == length
                    and all(type(v) in (int, float) and math.isfinite(v) for v in values), path, 'invalid model numbers/dimensions')
        require(all(v > 0 for v in model['preprocessor']['scales']), path, 'invalid feature scales')
        for key in ('training_run_ids', 'training_group_ids', 'training_modes', 'training_patterns'):
            require(isinstance(model[key], list) and model[key] and all(isinstance(v, str) for v in model[key]), path, 'missing training provenance')
        return model
    except (KeyError, TypeError, ValueError) as exc:
        raise DataError(f'{path}: invalid model: {exc}') from exc


def metrics(actual, predicted):
    return {target: {'mae': math.fsum(abs(a[i] - p[i]) for a, p in zip(actual, predicted)) / len(actual),
                     'rmse': math.sqrt(math.fsum((a[i] - p[i])**2 for a, p in zip(actual, predicted)) / len(actual))}
            for i, target in enumerate(TARGETS)}


def evaluate(model, samples):
    require(samples, 'evaluation', 'no adjacent full-window examples')
    require(not ({s['group_id'] for s in samples} & set(model['training_group_ids']))
            and not ({s['run_id'] for s in samples} & set(model['training_run_ids'])),
            'evaluation', 'training runs/workload groups must not appear in held-out evaluation')
    predictions = [dict(s, prediction=predict(model, s['features'])) for s in samples]
    scores = {}
    for method in ('ridge', 'persistence', 'training_mean'):
        def estimate(s):
            return s['prediction'] if method == 'ridge' else s['persistence'] if method == 'persistence' else model['target_means']
        scores[method] = metrics([s['targets'] for s in predictions], [estimate(s) for s in predictions])
        per_run = {}
        for run_id in sorted({s['run_id'] for s in predictions}):
            subset = [s for s in predictions if s['run_id'] == run_id]
            per_run[run_id] = metrics([s['targets'] for s in subset], [estimate(s) for s in subset])
        scores[method]['per_run'] = per_run
        scores[method]['macro_run_mae'] = {t: math.fsum(m[t]['mae'] for m in per_run.values()) / len(per_run) for t in TARGETS}
    warnings = ['Offline prediction errors are not memory savings or policy outcomes.']
    if len(samples) < 100 or len({s['group_id'] for s in samples}) < 5:
        warnings.append('Small held-out dataset: smoke-test results, not evidence of generalization.')
    for field, known in [('mode', model['training_modes']), ('pattern', model['training_patterns'])]:
        unseen = sorted({s[field] for s in samples} - set(known))
        if unseen: warnings.append(f'Held-out {field} absent from training: {unseen}')
    comparison = {target: {
        'ridge_beats_persistence_mae': scores['ridge'][target]['mae'] < scores['persistence'][target]['mae'],
        'ridge_beats_training_mean_mae': scores['ridge'][target]['mae'] < scores['training_mean'][target]['mae'],
    } for target in TARGETS}
    return {'examples': len(samples), 'run_ids': sorted({s['run_id'] for s in samples}),
            'group_ids': sorted({s['group_id'] for s in samples}), 'metrics': scores,
            'comparison': comparison, 'warnings': warnings}, predictions


def write_json(path, value):
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2, allow_nan=False)
        stream.write('\n')


def write_jsonl(path, rows):
    with path.open('x', encoding='utf-8') as stream:
        for row in rows: stream.write(json.dumps(row, allow_nan=False) + '\n')


def run_pipeline(recordings, output, seed=42, test_fraction=.25, alpha=1.0):
    samples = examples(recordings)
    training, testing = split_examples(samples, seed, test_fraction)
    model = fit_model(training, alpha)
    report, predictions = evaluate(model, testing)
    report['training_examples'] = len(training)
    report['training_run_ids'] = model['training_run_ids']
    report['training_group_ids'] = model['training_group_ids']
    if len(training) < 100:
        report['warnings'].append('Fewer than 100 training examples: pipeline smoke test only; collect more independent runs.')
    for i, name in enumerate(TARGETS):
        if len({s['targets'][i] for s in training}) == 1:
            report['warnings'].append(f'Constant training target: {name}; collect varied workloads before judging prediction quality.')
    report['target_definition'] = 'Next full request-count window: payload peak owned bytes and service p99 microseconds; not process RSS.'
    report['split'] = {'seed': seed, 'test_fraction': test_fraction, 'group_fields': GROUP_FIELDS,
                       'method': 'SHA256(seed:group_id), whole groups held out; no test-based tuning'}
    manifest = []
    train_groups, test_groups = set(model['training_group_ids']), set(report['group_ids'])
    for run in recordings:
        item = {k: v for k, v in run.items() if k != 'windows'}
        count = sum(s['run_id'] == run['run_id'] for s in samples)
        item.update(windows=len(run['windows']), examples=count,
                    split=('train' if run['group_id'] in train_groups else 'test' if run['group_id'] in test_groups else 'unused'),
                    skipped_pairs=max(0, len(run['windows']) - 1) - count)
        manifest.append(item)
    # Create outputs only after validation, splitting, fitting and evaluation succeed.
    output.mkdir(parents=True, exist_ok=False)
    write_json(output / 'manifest.json', manifest)
    write_jsonl(output / 'features.jsonl', [dict(s, split='train' if s['group_id'] in train_groups else 'test') for s in samples])
    write_json(output / 'model.json', model)
    write_json(output / 'report.json', report)
    write_jsonl(output / 'predictions.jsonl', predictions)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    for name in ('train', 'evaluate', 'predict'):
        command = sub.add_parser(name)
        command.add_argument('inputs', nargs='+', help='validated workload CSV files, directories or globs')
        command.add_argument('--output-dir', type=Path, help='new directory, never overwrite')
        if name == 'train':
            command.add_argument('--seed', type=int, default=42)
            command.add_argument('--test-fraction', type=float, default=.25)
            command.add_argument('--alpha', type=float, default=1.0)
        else:
            command.add_argument('--model', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        recordings = read_recordings(args.inputs)
        output = args.output_dir or Path(__file__).resolve().parents[1] / 'measurements' / 'ai' / (args.action + '-' + uuid.uuid4().hex)
        if args.action == 'train':
            report = run_pipeline(recordings, output, args.seed, args.test_fraction, args.alpha)
        else:
            model = load_model(args.model)
            if args.action == 'evaluate':
                report, predictions = evaluate(model, examples(recordings))
            else:
                predictions = []
                for run in recordings:
                    # Final partial windows are excluded to match the training horizon.
                    full = [r for r in run['windows'] if r['attempted'] == r['sample_every'] and r['elapsed_seconds'] > 0]
                    require(full, run['path'], 'no full window for inference')
                    row = full[-1]
                    predictions.append({'run_id': run['run_id'], 'observed_window_index': row['window_index'],
                                        'observed_end_ns': row['end_ns'], 'forecast_requests': row['sample_every'],
                                        'prediction': dict(zip(TARGETS, predict(model, features(row)))),
                                        'unseen_mode': run['mode'] not in model['training_modes'],
                                        'unseen_pattern': run['pattern'] not in model['training_patterns']})
                report = {'predictions': len(predictions), 'note': 'Forecast after the last full window; no evaluation or policy applied.'}
            output.mkdir(parents=True, exist_ok=False)
            write_json(output / 'report.json', report)
            write_jsonl(output / 'predictions.jsonl', predictions)
        summary = {key: value for key, value in report.items() if key in
                   ('training_examples', 'examples', 'predictions', 'comparison', 'warnings', 'note')}
        if 'metrics' in report:
            summary['metrics'] = {method: {target: values[target] for target in TARGETS}
                                  for method, values in report['metrics'].items()}
        print(json.dumps({'output_dir': str(output.resolve()), 'summary': summary}, indent=2, allow_nan=False))
        return 0
    except (DataError, OSError, ValueError, OverflowError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

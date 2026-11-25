#!/usr/bin/env python3
"""Run every installed speech and cleanup option on the same saved clips, one at a time.

Uses the evaluation entry points already built into the Voice binary
(--evaluate-local-asr / --evaluate-local-cleanup). Nothing is recorded, played,
uploaded or installed. Private receipts stay in the output directory; only
aggregate numbers are printed.

    python3 scripts/run-voice-benchmark.py            # everything installed
    python3 scripts/run-voice-benchmark.py --only asr  # speech models only

Historical Wispr text is not human ground truth: "disagreement" is a
diagnostic, not an accuracy score.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
SUPPORT = Path.home() / 'Library/Application Support'
DEFAULT_MANIFEST = SUPPORT / 'VOICE/WisprAudioEvaluation/evaluation-en-nl.json'
MODELS = SUPPORT / 'VOICE/Models'
MLX_CACHE = Path.home() / 'Library/Caches/models/mlx-community'
MINIMUM_FREE_BYTES = 6 * 1024 ** 3  # Metal and Core ML both need scratch space to compile.


def pinned_directory(model_id):
    base = MODELS / model_id
    if not base.is_dir():
        return None
    revisions = sorted(p for p in base.iterdir() if p.is_dir() and (p / '.voice-model.json').exists())
    return revisions[-1] if revisions else None


def find_binary():
    candidates = [ROOT / '.build/release/Voice', ROOT / '.build/debug/Voice']
    candidates += [app / 'Contents/MacOS/Voice' for app in (ROOT / 'build').glob('*.app')]
    existing = [c for c in candidates if c.is_file() and os.access(c, os.X_OK)]
    return max(existing, key=lambda p: p.stat().st_mtime) if existing else None


def options(manifest, out, passes):
    found = []
    v3 = SUPPORT / 'FluidAudio/Models/parakeet-v3'
    if v3.is_dir():
        found.append(('asr', 'parakeet-v3', {'models': str(v3), 'version': 'v3', 'passes': passes,
                                             'label': 'Parakeet v3'}))
    for model_id, version, label in (('parakeet-ultra', 'ultra', 'Parakeet Ultra'),
                                     ('phonon-2', 'phonon2', 'Phonon 2 (English only)')):
        directory = pinned_directory(model_id)
        if directory:
            found.append(('asr', model_id, {'models': str(directory), 'version': version,
                                            'passes': passes, 'label': label}))
    if (MLX_CACHE / 'S1-mini-MLX-4bit').is_dir():
        found.append(('cleanup', 's1-mini', {'model': 's1-mini'}))
    if any(MLX_CACHE.glob('Qwen3-*')):
        found.append(('cleanup', 'qwen3', {'model': 'qwen3'}))
    for kind, name, config in found:
        config['manifest'] = str(manifest)
        config['receiptDirectory'] = str(out / (kind + '-' + name))
    return found


def newest_receipt(directory):
    receipts = sorted(directory.glob('*receipt*.json'), key=lambda p: p.stat().st_mtime)
    if not receipts:
        return None
    data = json.loads(receipts[-1].read_text())
    return data.get('aggregate', data)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--manifest', type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/benchmark')
    parser.add_argument('--only', choices=('asr', 'cleanup'))
    parser.add_argument('--passes', type=int, default=3)
    parser.add_argument('--timeout', type=int, default=600, help='Seconds allowed per option')
    parser.add_argument('--list', action='store_true', help='Show what would run, then stop')
    args = parser.parse_args()

    binary = args.binary or find_binary()
    if not binary or not binary.is_file():
        raise SystemExit('No Voice binary found. Build one or pass --binary.')
    if not args.manifest.is_file():
        raise SystemExit('No evaluation manifest. Run scripts/prepare-wispr-audio-evaluation.py --materialize first.')
    stamp = time.strftime('%Y%m%d-%H%M%S')
    out = args.output / stamp
    plan = [o for o in options(args.manifest, out, args.passes) if args.only in (None, o[0])]
    if not plan:
        raise SystemExit('No installed models found to compare.')
    print('Binary:', binary)
    for kind, name, _ in plan:
        print(' ', kind, name)
    if args.list:
        return
    free = shutil.disk_usage(Path.home()).free
    if free < MINIMUM_FREE_BYTES:
        raise SystemExit('Only %.1f GB free; need %.0f GB. Free some space first.' % (free / 1e9, MINIMUM_FREE_BYTES / 1e9))
    if subprocess.run(['pgrep', '-x', 'Voice'], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('Voice is running. Quit it first so two copies do not load models at once.')

    out.mkdir(parents=True, mode=0o700)
    os.chmod(out, 0o700)
    summary = []
    for kind, name, config in plan:
        receipt_directory = Path(config['receiptDirectory'])
        receipt_directory.mkdir(mode=0o700)
        config_path = out / (kind + '-' + name + '-config.json')
        config_path.write_text(json.dumps(config))
        os.chmod(config_path, 0o600)
        flag = '--evaluate-local-asr' if kind == 'asr' else '--evaluate-local-cleanup'
        started = time.monotonic()
        with open(out / (kind + '-' + name + '.log'), 'wb') as log:
            os.chmod(log.name, 0o600)
            try:
                code = subprocess.run([str(binary), flag, str(config_path)], stdout=log, stderr=log,
                                      timeout=args.timeout).returncode
            except subprocess.TimeoutExpired:
                code = 'timeout'
        entry = {'kind': kind, 'option': name, 'exit': code,
                 'elapsedSeconds': round(time.monotonic() - started, 1),
                 'aggregate': newest_receipt(receipt_directory) if code == 0 else None}
        summary.append(entry)
        print('%-8s %-16s exit=%s %.0fs' % (kind, name, code, entry['elapsedSeconds']))
        time.sleep(5)  # Let the GPU and Neural Engine settle before the next model loads.

    summary_path = out / 'summary.json'
    summary_path.write_text(json.dumps(summary, indent=2))
    os.chmod(summary_path, 0o600)

    def pick(aggregate, *keys):
        for key in keys:
            if aggregate and aggregate.get(key) is not None:
                return aggregate[key]
        return None

    print('\n%-8s %-16s %10s %10s %8s %8s %s' % ('kind', 'option', 'median ms', 'p95 ms', 'failed', 'differ', 'accepted'))
    for entry in summary:
        a = entry['aggregate']
        median = pick(a, 'allCallsMedianDecodeMilliseconds', 'warmMedianMilliseconds')
        p95 = pick(a, 'allCallsP95DecodeMilliseconds', 'warmP95Milliseconds')
        failed = pick(a, 'failedCalls', 'errorCalls')
        differ = pick(a, 'historicalDisagreementRate')
        accepted = pick(a, 'acceptedCalls')
        cell = lambda v, f='%.0f': '-' if v is None else (f % v)
        print('%-8s %-16s %10s %10s %8s %8s %s' % (entry['kind'], entry['option'], cell(median), cell(p95),
              cell(failed, '%d'), cell(differ, '%.3f'), cell(accepted, '%d')))
    print('\nSummary:', summary_path)
    if any(entry['exit'] != 0 for entry in summary):
        sys.exit(1)


if __name__ == '__main__':
    main()

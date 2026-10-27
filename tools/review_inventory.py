"""Build a navigable source index; create a baseline only when explicitly asked.

python tools/review_inventory.py
python tools/review_inventory.py --baseline docs/reviews/REVIEW_BASELINE.json
Existing baseline files are never overwritten.
"""
import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline')
    args = parser.parse_args()
    files = sorted((ROOT / 'lib').rglob('*.dart')) + sorted((ROOT / 'test').rglob('*.dart'))
    rows = []
    counts = Counter()
    for file in files:
        relative = file.relative_to(ROOT).as_posix()
        source = file.read_text(encoding='utf-8-sig')
        parts = file.relative_to(ROOT).parts
        group = parts[2] if len(parts) > 2 and parts[1] == 'features' else '/'.join(parts[:2])
        counts[group] += 1
        symbols = re.findall(r'^(?:(?:abstract|sealed|final|base)\s+)?(?:class|enum|mixin|extension)\s+(\w+)', source, re.M)
        providers = re.findall(r'^final\s+(\w*Provider)\s*=', source, re.M)
        rows.append({'path': relative, 'lines': len(source.splitlines()),
                     'symbols': symbols, 'providers': providers,
                     'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
    lines = ['# Source inventory / فهرس المصدر', '',
             'Generated from the current local source by `python tools/review_inventory.py`.',
             'This is navigation metadata, not proof that every branch has been runtime-tested.', '',
             f'{len(rows)} Dart files in lib/ and test/. Generated/build caches excluded.', '',
             '| Group | Files |', '|---|---:|']
    lines += [f'| {group} | {count} |' for group, count in sorted(counts.items())]
    lines += ['', '| File | Lines | Types / Providers |', '|---|---:|---|']
    for row in rows:
        symbols = ', '.join(row['symbols'] + row['providers']) or '—'
        lines.append(f"| [{row['path']}](../{row['path']}) | {row['lines']} | {symbols} |")
    (ROOT / 'docs').mkdir(exist_ok=True)
    (ROOT / 'docs/SOURCE_INVENTORY.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    if args.baseline:
        target = ROOT / args.baseline
        # Explicitly refuse replacement of the initial review evidence.
        with target.open('x', encoding='utf-8') as output:
            extras = ['pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml',
                      'android/app/build.gradle.kts', 'android/app/src/main/AndroidManifest.xml',
                      'ios/Runner/Info.plist']
            json.dump({'review_date': '2026-10-05', 'git_baseline': None,
                       'scope': 'lib Dart, test Dart, and selected project config; no secrets or build outputs',
                       'files': rows,
                       'config_hashes': {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in extras}},
                      output, ensure_ascii=False, indent=2)
            output.write('\n')
    print(f'Indexed {len(rows)} Dart files, {sum(r["lines"] for r in rows)} lines.')


if __name__ == '__main__':
    main()

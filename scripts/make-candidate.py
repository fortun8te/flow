#!/usr/bin/env python3
"""The one build command for a Flow candidate.

Usage (from the repo root):
    python3 scripts/make-candidate.py
    python3 scripts/make-candidate.py --signing-identity "acmehub Local Signing"

What it does, in order:
  1. scripts/build-flow.py: builds the full backend (swift build, product Flow).
  2. scripts/package-preview.py: packages build/Flow-<hash>-<time>.app, signs it, writes a receipt.
  3. Checks the candidate. It refuses to finish, and deletes the candidate and its
     receipt, unless all of these hold:
     - Info.plist: CFBundleIdentifier is com.example.flow, CFBundleExecutable is Flow,
       and no "$(" placeholder appears anywhere in the file;
     - the signature is valid (codesign --verify --deep --strict) and was made with
       the identity "acmehub Local Signing";
     - the binary answers its harness flag --check-permissions with JSON and exit 0.
       That flag returns before the app starts: nothing is launched, no window opens.

It never installs over /Applications/Flow.app and never launches the app.
"""
import argparse
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

from candidate_check import EXPECTED_SIGNER, codesign_problems, plist_problems

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = Path(__file__).resolve().parent


def fail(candidate, receipt, problems):
    if candidate:
        shutil.rmtree(candidate, ignore_errors=True)
    if receipt:
        receipt.unlink(missing_ok=True)
    print('Candidate refused and deleted:', file=sys.stderr)
    for problem in problems:
        print('  - ' + problem, file=sys.stderr)
    raise SystemExit(1)


def verify(candidate):
    """Return a list of problems with the built candidate. Empty means it passes."""
    problems = []
    info_path = candidate / 'Contents/Info.plist'
    if not info_path.is_file():
        return ['Info.plist is missing from the candidate']
    info = plistlib.loads(info_path.read_bytes())
    problems += plist_problems(info)
    if b'$(' in info_path.read_bytes():
        problems.append('the raw Info.plist file still contains "$("')
    executable = candidate / 'Contents/MacOS' / str(info.get('CFBundleExecutable', ''))
    if not executable.is_file():
        problems.append('the executable named in Info.plist is missing: %s' % executable.name)
        return problems

    signing = subprocess.run(['codesign', '-dv', '--verbose=4', str(candidate)],
                             capture_output=True, text=True)
    problems += codesign_problems(signing.stdout + '\n' + signing.stderr)
    strict = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(candidate)],
                            capture_output=True, text=True)
    if strict.returncode != 0:
        problems.append('signature does not verify: ' + strict.stderr.strip())

    try:
        check = subprocess.run([str(executable), '--check-permissions'],
                               capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return problems + ['the binary did not answer --check-permissions within 30 s']
    if check.returncode != 0:
        problems.append('the binary exited with %d for --check-permissions' % check.returncode)
    else:
        try:
            answer = json.loads(check.stdout)
            if not {'microphone', 'accessibility'} <= set(answer):
                problems.append('--check-permissions printed JSON without the expected keys')
        except ValueError:
            problems.append('--check-permissions did not print JSON')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--signing-identity', default=EXPECTED_SIGNER)
    args = parser.parse_args()

    subprocess.run([sys.executable, str(SCRIPTS / 'build-flow.py')], cwd=ROOT, check=True)
    packaged = subprocess.run([sys.executable, str(SCRIPTS / 'package-preview.py'),
                               '--signing-identity', args.signing_identity],
                              cwd=ROOT, capture_output=True, text=True)
    if packaged.returncode != 0:
        print(packaged.stdout + packaged.stderr, file=sys.stderr)
        raise SystemExit('Packaging refused. No candidate kept.')
    result = json.loads(packaged.stdout.strip().splitlines()[-1])
    candidate = Path(result['candidate'])
    receipt = Path(result['receipt'])

    problems = verify(candidate)
    if args.signing_identity != EXPECTED_SIGNER:
        problems.append('the signing identity must be %r' % EXPECTED_SIGNER)
    if problems:
        fail(candidate, receipt, problems)

    data = json.loads(receipt.read_text())
    data.update(plistChecked=True, launchCheck='--check-permissions answered with JSON, exit 0; app not started')
    receipt.write_text(json.dumps(data, indent=2))
    print(json.dumps(dict(candidate=str(candidate), receipt=str(receipt), verified=True), indent=2))


if __name__ == '__main__':
    main()

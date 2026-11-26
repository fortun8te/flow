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
       and no "$(" or "${" placeholder remains in plist keys or values;
     - the signature is valid (codesign --verify --deep --strict) and was made with
       the identity "acmehub Local Signing";
     - the binary answers --check-permissions with typed permission JSON and exit 0.
       That flag returns before the app starts: nothing is launched, no window opens.
       It is never executed after failed plist or signature validation.

It never installs over /Applications/Flow.app and never launches the app.
"""
import argparse
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError

from candidate_check import EXPECTED_SIGNER, codesign_problems, permission_problems, plist_problems

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
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException, ExpatError):
        return ['Info.plist is unreadable or invalid']
    problems += plist_problems(info)
    if problems:
        # Do not execute a path from a bundle whose metadata already failed.
        return problems
    executable = candidate / 'Contents/MacOS' / str(info.get('CFBundleExecutable', ''))
    if executable.is_symlink() or not executable.is_file() or not executable.resolve().is_relative_to(candidate.resolve()):
        problems.append('the executable named in Info.plist is missing: %s' % executable.name)
        return problems

    try:
        signing = subprocess.run(['codesign', '-dv', '--verbose=4', str(candidate)],
                                 capture_output=True, text=True, timeout=30)
        strict = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(candidate)],
                                capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return ['candidate signature inspection failed or exceeded 30 s']
    if signing.returncode != 0:
        problems.append('candidate signature inspection failed')
    problems += codesign_problems(signing.stdout + '\n' + signing.stderr)
    if strict.returncode != 0:
        problems.append('signature does not verify: ' + strict.stderr.strip())
    if problems:
        return problems

    try:
        check = subprocess.run([str(executable), '--check-permissions'],
                               capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return problems + ['the binary did not answer --check-permissions within 30 s']
    except OSError:
        return problems + ['the binary could not execute --check-permissions']
    if check.returncode != 0:
        problems.append('the binary exited with %d for --check-permissions' % check.returncode)
    else:
        try:
            answer = json.loads(check.stdout)
            problems += permission_problems(answer)
        except (ValueError, TypeError):
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

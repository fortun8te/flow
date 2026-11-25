#!/usr/bin/env python3
"""Package Flow's complete SwiftPM backend. Does not install or launch."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
from flow_build_manifest import snapshot
from candidate_check import plist_problems


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--signing-identity', required=True)
    parser.add_argument('--products', type=Path)
    args = parser.parse_args()
    if args.signing_identity.strip() in ('', '-'):
        parser.error('Select a stable signing identity.')
    root = Path(__file__).resolve().parents[1]
    build_receipt = json.loads((root / 'build/build-receipt.json').read_text())
    products = args.products or Path(build_receipt['products'])
    binary = products / 'Flow'
    sources, source_hash = snapshot(root)
    if (build_receipt.get('product') != 'Flow' or not build_receipt.get('fullBackend')
            or sources != build_receipt.get('sources')
            or source_hash != build_receipt.get('sourceSHA256')
            or digest(binary) != build_receipt.get('executableSHA256')):
        raise SystemExit('Build receipt does not match current sources and executable. Run scripts/build-flow.py first.')
    stamp = time.strftime('%Y%m%d%H%M%S')
    candidate = root / 'build' / ('Flow-' + source_hash[:10] + '-' + stamp + '.app')
    try:
        package(root, binary, products, candidate, stamp, source_hash, sources, args.signing_identity)
    except BaseException:
        # A candidate that failed any check is never left behind for someone to install.
        shutil.rmtree(candidate, ignore_errors=True)
        raise


def package(root, binary, products, candidate, stamp, source_hash, sources, signing_identity):
    resources = candidate / 'Contents/Resources'
    executable = candidate / 'Contents/MacOS/Flow'
    executable.parent.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(binary, executable)
    bundles = list(products.glob('*.bundle'))
    if not any('Voice' in p.name for p in bundles):
        raise SystemExit('Backend SwiftPM resource bundle is missing. Candidate is incomplete.')
    for bundle in bundles:
        shutil.copytree(bundle, resources / bundle.name)
        # SwiftPM command-line resource lookup also searches beside executable.
        shutil.copytree(bundle, executable.parent / bundle.name)
    fonts = root / 'Sources/Voice/Resources/Fonts'
    if fonts.is_dir():
        shutil.copytree(fonts, resources / 'Fonts')
    info = plistlib.loads((root / 'Info.plist').read_bytes())
    # Every placeholder is replaced here. The check runs on the final dict, so a
    # repo value that still holds "$(...)" anywhere is refused before signing.
    info.update(CFBundleExecutable='Flow', CFBundleIdentifier='com.example.flow',
                CFBundleDevelopmentRegion='en', CFBundleName='Flow', CFBundleDisplayName='Flow',
                CFBundleVersion=stamp, FlowSourceSHA256=source_hash, LSUIElement=True)
    problems = plist_problems(info)
    if problems:
        raise SystemExit('Candidate refused: ' + '; '.join(problems))
    (candidate / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    # Read the written file back, the same bytes the bundle will ship with.
    problems = plist_problems(plistlib.loads((candidate / 'Contents/Info.plist').read_bytes()))
    if problems:
        raise SystemExit('Candidate refused: ' + '; '.join(problems))
    run('codesign', '--force', '--deep', '--sign', signing_identity,
        '--entitlements', str(root / 'Voice.entitlements'), str(candidate))
    run('codesign', '--verify', '--deep', '--strict', str(candidate))
    receipt = dict(candidate=str(candidate), sourceSHA256=source_hash, sources=sources,
                   executableSHA256=digest(executable), signingIdentity=signing_identity,
                   signatureVerified=True, installed=False, launched=False,
                   fullBackend=True, liveCaptureVerified=False)
    receipt_path = candidate.parent / ('receipt-' + stamp + '.json')
    receipt_path.write_text(json.dumps(receipt, indent=2))
    print(json.dumps(dict(candidate=str(candidate), receipt=str(receipt_path), signatureVerified=True)))


if __name__ == '__main__':
    main()

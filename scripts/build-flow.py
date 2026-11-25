#!/usr/bin/env python3
"""Build the full backend and bind the executable to an unchanged source snapshot."""
import argparse
import json
from pathlib import Path
import subprocess
from flow_build_manifest import snapshot, digest

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--jobs', default='4')
# Release by default: the shipped Flow used to be the debug build (slower text passes and UI). 21 Nov 2026.
parser.add_argument('--configuration', default='release', choices=['release', 'debug'])
args = parser.parse_args()
sources, fingerprint = snapshot(root)
output = root / 'build'
output.mkdir(exist_ok=True)
receipt = output / 'build-receipt.json'
# Never leave an old receipt looking current after a failed rebuild.
receipt.unlink(missing_ok=True)
with (output / 'build.log').open('w') as log:
    subprocess.run(['swift', 'build', '-c', args.configuration, '--package-path', str(root), '--product', 'Flow', '--jobs', args.jobs],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
products = Path(subprocess.check_output(['swift', 'build', '-c', args.configuration, '--package-path', str(root), '--show-bin-path'], text=True).strip())
binary = products / 'Flow'
after, after_fingerprint = snapshot(root)
if sources != after or fingerprint != after_fingerprint:
    raise SystemExit('Sources changed while building; no package receipt was created. Rebuild when edits are finished.')
data = dict(sourceSHA256=fingerprint, sources=sources, products=str(products),
            executableSHA256=digest(binary), product='Flow', fullBackend=True)
receipt.write_text(json.dumps(data, indent=2))
print(json.dumps(dict(buildReceipt=str(receipt), executable=str(binary), sourceSHA256=fingerprint)))

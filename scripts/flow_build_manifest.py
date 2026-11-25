import hashlib
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def snapshot(root):
    sources = {str(p.relative_to(root)): digest(p)
               for folder in ('Sources/Voice', 'scripts')
               for p in sorted((root / folder).rglob('*'))
               if p.is_file() and '__pycache__' not in p.parts}
    for name in ('Package.swift', 'Package.resolved', 'Info.plist', 'Voice.entitlements'):
        sources[name] = digest(root / name)
    fingerprint = hashlib.sha256(json.dumps(sources, sort_keys=True).encode()).hexdigest()
    return sources, fingerprint

#!/usr/bin/env python3
"""Plan or explicitly install pinned public VOICE model artifacts. No model execution."""
import argparse
import contextlib
import ctypes
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request

RESERVE_BYTES = 2 * 1024 ** 3
MANIFEST_DIR = Path(__file__).resolve().parents[1] / 'Sources/Voice/Resources/ModelManifests'
APPROVED = {
    'parakeet-ultra': ('FluidInference/parakeet-ultra-coreml', '95eaa59a39d4394f047a4dc5cce480388a60d1b6',
                      'Library/Application Support/VOICE/Models/parakeet-ultra/95eaa59a39d4394f047a4dc5cce480388a60d1b6'),
    'phonon-2': ('FluidInference/phonon-2-coreml', '1702fc22e76f203d5ca464cd5d3ef130a45ce2c0',
                 'Library/Application Support/VOICE/Models/phonon-2/1702fc22e76f203d5ca464cd5d3ef130a45ce2c0'),
    's1-mini': ('mlx-community/S1-mini-MLX-4bit', '5cbd7aec3401144f88a331d385c40b65fd2548eb',
                'Library/Caches/models/mlx-community/S1-mini-MLX-4bit'),
}
NOFOLLOW = os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK


class ProvisionError(Exception):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def path_parts(value):
    if not isinstance(value, str) or not value or '\\' in value or '\x00' in value:
        raise ProvisionError('Invalid manifest path')
    path = PurePosixPath(value)
    if path.is_absolute() or str(path) != value or any(x in ('.', '..') for x in path.parts):
        raise ProvisionError('Unsafe manifest path')
    return path.parts


def validate_manifest(manifest):
    if not isinstance(manifest, dict) or manifest.get('schemaVersion') != 1:
        raise ProvisionError('Unsupported manifest')
    model_id = manifest.get('modelId')
    expected = APPROVED.get(model_id) if isinstance(model_id, str) else None
    if expected is None or tuple(manifest.get(k) for k in ('repository', 'revision', 'cacheRelativePath')) != expected:
        raise ProvisionError('Model source is not approved')
    path_parts(manifest['cacheRelativePath'])
    files = manifest.get('files')
    if not isinstance(files, list) or not files or len(files) > 1000:
        raise ProvisionError('Invalid file manifest')
    seen = set()
    for item in files:
        if not isinstance(item, dict) or set(item) not in ({'path', 'size', 'sha256'}, {'path', 'size', 'gitBlobSha1'}):
            raise ProvisionError('Invalid file entry')
        parts = path_parts(item['path'])
        if any(x.startswith('.') for x in parts) or item['path'] in seen:
            raise ProvisionError('Duplicate or reserved artifact path')
        seen.add(item['path'])
        if type(item['size']) is not int or not 0 < item['size'] <= 8 * 1024 ** 3:
            raise ProvisionError('Invalid artifact size')
        key = 'sha256' if 'sha256' in item else 'gitBlobSha1'
        if not isinstance(item[key], str) or not re.fullmatch('[0-9a-f]{%d}' % (64 if key == 'sha256' else 40), item[key]):
            raise ProvisionError('Invalid artifact digest')
    if any('/'.join(path_parts(p)[:i]) in seen for p in seen for i in range(1, len(path_parts(p)))):
        raise ProvisionError('Artifact path conflicts with a directory')
    return manifest


def load_manifest(model_id):
    if model_id not in APPROVED:
        raise ProvisionError('Unknown model')
    return validate_manifest(json.loads((MANIFEST_DIR / (model_id + '.json')).read_text()))


def check_owned(info, directory=False, private=False):
    if info.st_uid != os.getuid() or (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)) is False:
        raise ProvisionError('Cache entry has an unexpected owner or type')
    if info.st_mode & (0o077 if private else 0o022):
        raise ProvisionError('Cache permissions are too broad')


@contextlib.contextmanager
def directory_at(root_fd, parts=(), create=False, private=False):
    fd = os.dup(root_fd)
    try:
        for name in parts:
            if create:
                try:
                    os.mkdir(name, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            check_owned(os.fstat(fd), directory=True)
        check_owned(os.fstat(fd), directory=True, private=private)
        yield fd
    finally:
        os.close(fd)


def read_json_at(fd, name):
    file_fd = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=fd)
    with os.fdopen(file_fd, 'rb') as file:
        check_owned(os.fstat(file.fileno()), private=True)
        data = file.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise ProvisionError('Cache receipt is too large')
    try:
        result = json.loads(data)
        if not isinstance(result, dict):
            raise ValueError('Expected a receipt object')
        return result
    except (ValueError, UnicodeError) as error:
        raise ProvisionError('Invalid cache receipt') from error


def write_json_at(fd, name, value):
    file_fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=fd)
    with os.fdopen(file_fd, 'wb') as file:
        file.write(canonical(value))
        file.flush()
        os.fsync(file.fileno())


def entry_size(fd, name):
    try:
        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    check_owned(info, private=True)
    return info.st_size


def verify_file(fd, name, item, discard_bad=False):
    file_fd = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=fd)
    with os.fdopen(file_fd, 'rb') as file:
        info = os.fstat(file.fileno())
        check_owned(info, private=True)
        if info.st_size != item['size']:
            raise ProvisionError('Artifact size mismatch')
        key = 'sha256' if 'sha256' in item else 'gitBlobSha1'
        digest = hashlib.sha256() if key == 'sha256' else hashlib.sha1(b'blob ' + str(info.st_size).encode() + b'\0')
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != item[key]:
        # A full-size partial with wrong bytes can never resume; drop it so the next run refetches.
        if discard_bad:
            try:
                os.unlink(name, dir_fd=fd)
            except OSError:
                pass
        raise ProvisionError('Artifact checksum mismatch')


def check_tree(fd, allowed_files):
    allowed_dirs = {str(PurePosixPath(p).parent) for p in allowed_files}
    allowed_dirs |= {'/'.join(path_parts(p)[:i]) for p in allowed_files for i in range(1, len(path_parts(p)))}
    def visit(current, prefix=''):
        with os.scandir(current) as entries:
            for entry in entries:
                relative = prefix + entry.name
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    if relative not in allowed_dirs:
                        raise ProvisionError('Unknown cache directory; refusing to overwrite')
                    with directory_at(current, (entry.name,), private=True) as child:
                        visit(child, relative + '/')
                else:
                    if relative not in allowed_files:
                        raise ProvisionError('Unknown cache file; refusing to overwrite')
                    check_owned(info, private=True)
    visit(fd)


class HTTPSRedirectOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        if parsed.scheme != 'https' or parsed.username or parsed.password:
            raise ProvisionError('Refused unsafe model redirect')
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def public_open(request):
    return urllib.request.build_opener(HTTPSRedirectOnly()).open(request, timeout=45)


def ensure_space(free_bytes, remaining):
    if free_bytes() < remaining + RESERVE_BYTES:
        raise ProvisionError('Insufficient disk space: model remainder plus 2 GiB reserve required')


def download_file(fd, item, manifest, remaining, free_bytes, opener):
    name = path_parts(item['path'])[-1]
    partial = name + '.voice-part'
    offset = entry_size(fd, partial) or 0
    if offset > item['size']:
        raise ProvisionError('Partial artifact is larger than its manifest')
    if offset == item['size']:
        verify_file(fd, partial, item, discard_bad=True)
    else:
        ensure_space(free_bytes, remaining[0])
        url = 'https://huggingface.co/%s/resolve/%s/%s' % (
            manifest['repository'], manifest['revision'], urllib.parse.quote(item['path'], safe='/'))
        request = urllib.request.Request(url, headers={'User-Agent': 'VOICE-model-provisioner/1', **({'Range': 'bytes=%d-' % offset} if offset else {})})
        with opener(request) as response:
            parsed = urllib.parse.urlsplit(response.geturl())
            if parsed.scheme != 'https' or parsed.username or parsed.password:
                raise ProvisionError('Model response was not public HTTPS')
            status = response.status
            if status == 206:
                match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
                if not match or tuple(map(int, match.groups())) != (offset, item['size'] - 1, item['size']):
                    raise ProvisionError('Model resume range was not verified')
            elif status == 200:
                remaining[0] += offset
                offset = 0  # A server ignoring Range restarts only our known partial.
            else:
                raise ProvisionError('Unexpected model HTTP status')
            length = response.headers.get('Content-Length')
            if length is not None and (not length.isdecimal() or int(length) != item['size'] - offset):
                raise ProvisionError('Unexpected model response size')
            file_fd = os.open(partial, os.O_RDWR | os.O_CREAT | NOFOLLOW, 0o600, dir_fd=fd)
            with os.fdopen(file_fd, 'r+b') as file:
                check_owned(os.fstat(file.fileno()), private=True)
                file.truncate(offset)
                file.seek(offset)
                count = offset
                while True:
                    chunk = response.read(min(1024 * 1024, item['size'] - count + 1))
                    if not chunk:
                        break
                    if count + len(chunk) > item['size']:
                        raise ProvisionError('Model response exceeded manifest size')
                    ensure_space(free_bytes, remaining[0])
                    file.write(chunk)
                    count += len(chunk)
                    remaining[0] -= len(chunk)
                file.flush()
                os.fsync(file.fileno())
            if count != item['size']:
                raise ProvisionError('Model response ended before completion')
        verify_file(fd, partial, item, discard_bad=True)
    # A hard link refuses an unexpected existing destination atomically.
    os.link(partial, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
    os.unlink(partial, dir_fd=fd)


def rename_exclusive(parent_fd, source, destination):
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        function, flags = library.renameatx_np, 0x4  # Darwin RENAME_EXCL.
    elif hasattr(library, 'renameat2'):
        function, flags = library.renameat2, 1  # Linux RENAME_NOREPLACE.
    else:
        raise ProvisionError('Atomic exclusive installation is unsupported')
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(parent_fd, os.fsencode(source), parent_fd, os.fsencode(destination), flags):
        raise OSError(ctypes.get_errno(), 'Exclusive model installation failed')


def verify_complete(fd, manifest, manifest_digest):
    receipt = read_json_at(fd, '.voice-model.json')
    if receipt.get('modelId') != manifest['modelId'] or receipt.get('revision') != manifest['revision'] or receipt.get('manifestSHA256') != manifest_digest or receipt.get('files') != manifest['files']:
        raise ProvisionError('Existing model receipt does not match the pinned manifest')
    check_tree(fd, {x['path'] for x in manifest['files']} | {'.voice-model.json'})
    for item in manifest['files']:
        with directory_at(fd, path_parts(item['path'])[:-1], private=True) as parent:
            verify_file(parent, path_parts(item['path'])[-1], item)


def install(manifest, home=None, opener=public_open, free_bytes=None):
    manifest = validate_manifest(manifest)
    home = Path.home() if home is None else Path(home)
    digest = hashlib.sha256(canonical(manifest)).hexdigest()
    parts = path_parts(manifest['cacheRelativePath'])
    leaf = parts[-1]
    marker = {'modelId': manifest['modelId'], 'revision': manifest['revision'], 'manifestSHA256': digest}
    stage = '.' + leaf + '.' + manifest['revision'] + '.partial'
    free_bytes = free_bytes or (lambda: shutil.disk_usage(home).free)
    home_fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
    try:
        check_owned(os.fstat(home_fd), directory=True)
        with directory_at(home_fd, parts[:-1], create=True) as parent:
            lock_fd = os.open('.' + leaf + '.lock', os.O_RDWR | os.O_CREAT | NOFOLLOW, 0o600, dir_fd=parent)
            try:
                check_owned(os.fstat(lock_fd), private=True)
                try:
                    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    raise ProvisionError('Another installation owns this model') from error
                try:
                    with directory_at(parent, (leaf,), private=True) as existing:
                        verify_complete(existing, manifest, digest)
                        return {'modelId': manifest['modelId'], 'status': 'verified-existing', 'revision': manifest['revision']}
                except FileNotFoundError:
                    # Only a missing destination permits installation. Missing
                    # files inside an existing destination are an error.
                    try:
                        os.stat(leaf, dir_fd=parent, follow_symlinks=False)
                    except FileNotFoundError:
                        pass
                    else:
                        raise ProvisionError('Existing model is incomplete; refusing to overwrite')
                created = False
                try:
                    os.mkdir(stage, 0o700, dir_fd=parent)
                    created = True
                except FileExistsError:
                    pass
                with directory_at(parent, (stage,), private=True) as staging:
                    if not created and entry_size(staging, '.voice-model.json') is not None:
                        # A prior run may have finished verification but been
                        # interrupted immediately before the directory rename.
                        if entry_size(staging, '.voice-staging.json') is not None:
                            if read_json_at(staging, '.voice-staging.json') != marker:
                                raise ProvisionError('Staging directory belongs to a different manifest')
                            os.unlink('.voice-staging.json', dir_fd=staging)
                        verify_complete(staging, manifest, digest)
                        rename_exclusive(parent, stage, leaf)
                        return {'modelId': manifest['modelId'], 'status': 'installed', 'revision': manifest['revision']}
                    if created:
                        write_json_at(staging, '.voice-staging.json', marker)
                    elif read_json_at(staging, '.voice-staging.json') != marker:
                        raise ProvisionError('Staging directory belongs to a different manifest')
                    allowed = {'.voice-staging.json'} | {x['path'] for x in manifest['files']} | {x['path'] + '.voice-part' for x in manifest['files']}
                    check_tree(staging, allowed)
                    pending = []
                    remaining = 0
                    for item in manifest['files']:
                        with directory_at(staging, path_parts(item['path'])[:-1], create=True, private=True) as directory:
                            name = path_parts(item['path'])[-1]
                            if entry_size(directory, name) is not None:
                                verify_file(directory, name, item)
                                if entry_size(directory, name + '.voice-part') is not None:
                                    # Recover a crash between our exclusive
                                    # hard-link and removal of its partial name.
                                    verify_file(directory, name + '.voice-part', item)
                                    os.unlink(name + '.voice-part', dir_fd=directory)
                            else:
                                size = entry_size(directory, name + '.voice-part') or 0
                                if size > item['size']:
                                    raise ProvisionError('Invalid partial artifact size')
                                remaining += item['size'] - size
                                pending.append(item)
                    ensure_space(free_bytes, remaining)
                    budget = [remaining]
                    for item in pending:
                        with directory_at(staging, path_parts(item['path'])[:-1], private=True) as directory:
                            download_file(directory, item, manifest, budget, free_bytes, opener)
                    write_json_at(staging, '.voice-model.json', {**marker, 'schemaVersion': 1, 'repository': manifest['repository'], 'files': manifest['files'], 'completedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat()})
                    os.unlink('.voice-staging.json', dir_fd=staging)
                    verify_complete(staging, manifest, digest)
                rename_exclusive(parent, stage, leaf)
                return {'modelId': manifest['modelId'], 'status': 'installed', 'revision': manifest['revision']}
            finally:
                os.close(lock_fd)
    finally:
        os.close(home_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install', choices=sorted(APPROVED), help='Explicitly download and install one pinned model')
    args = parser.parse_args()
    try:
        if args.install:
            print(json.dumps(install(load_manifest(args.install))))
        else:
            # Default planning does not create cache directories or open a network connection.
            print(json.dumps({'mode': 'plan-only', 'reserveBytes': RESERVE_BYTES, 'models': [
                {'modelId': model_id, 'revision': manifest['revision'], 'downloadBytes': sum(x['size'] for x in manifest['files']), 'files': len(manifest['files'])}
                for model_id in APPROVED for manifest in [load_manifest(model_id)]
            ]}, indent=2))
    except (ProvisionError, OSError, ValueError) as error:
        message = str(error) if isinstance(error, ProvisionError) else 'Model provisioning failed; existing files were retained'
        print(json.dumps({'status': 'failed', 'error': message}), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

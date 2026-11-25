import copy
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/provision-voice-models.py'
spec = importlib.util.spec_from_file_location('voice_provision', SCRIPT)
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)


class Response:
    def __init__(self, data, status=200, offset=0, interrupt=False, incorrect_range=False):
        self.stream = io.BytesIO(data[offset:])
        self.status = status
        self.interrupt = interrupt
        self.reads = 0
        self.headers = {'Content-Length': str(len(data) - offset)}
        if status == 206:
            self.headers['Content-Range'] = 'bytes %d-%d/%d' % (offset + int(incorrect_range), len(data) - 1, len(data))

    def geturl(self):
        return 'https://huggingface.co/public/model/resolve/pinned/file'

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self, size):
        self.reads += 1
        if self.interrupt and self.reads > 1:
            raise OSError('synthetic interruption')
        return self.stream.read(min(size, 3) if self.interrupt else size)


class ProvisionModelsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name).resolve()
        self.data = {'config.json': b'{}', 'model.safetensors': b'0123456789abcdef'}
        repository, revision, cache = provision.APPROVED['s1-mini']
        self.manifest = {
            'schemaVersion': 1, 'modelId': 's1-mini', 'repository': repository,
            'revision': revision, 'cacheRelativePath': cache,
            'files': [
                {'path': 'config.json', 'size': 2, 'gitBlobSha1': hashlib.sha1(b'blob 2\0{}').hexdigest()},
                {'path': 'model.safetensors', 'size': len(self.data['model.safetensors']),
                 'sha256': hashlib.sha256(self.data['model.safetensors']).hexdigest()},
            ],
        }
        self.destination = self.home / cache
        self.requests = []

    def tearDown(self):
        self.temp.cleanup()

    def opener(self, request):
        self.requests.append(request)
        return Response(self.data[Path(request.full_url).name])

    def install(self, **kwargs):
        return provision.install(self.manifest, home=self.home, opener=kwargs.pop('opener', self.opener),
                                 free_bytes=kwargs.pop('free_bytes', lambda: 10 * 1024 ** 3), **kwargs)

    def test_default_is_plan_only_without_network_or_cache_creation(self):
        with mock.patch.object(provision.sys, 'argv', [str(SCRIPT)]), mock.patch.object(provision.sys, 'stdout', io.StringIO()) as output, mock.patch.object(provision.os, 'mkdir', side_effect=AssertionError('No cache writes')), mock.patch.object(provision, 'public_open', side_effect=AssertionError('No network')):
            self.assertEqual(provision.main(), 0)
        result = json.loads(output.getvalue())
        self.assertEqual(result['mode'], 'plan-only')
        self.assertEqual(len(result['models']), 3)

    def test_manifests_are_pinned_and_selective(self):
        expected = {'parakeet-ultra': 632_163_378, 'phonon-2': 378_098_390, 's1-mini': 346_940_945}
        for model_id, size in expected.items():
            manifest = provision.load_manifest(model_id)
            self.assertEqual(sum(x['size'] for x in manifest['files']), size)
            self.assertEqual(len(manifest['revision']), 40)
            self.assertFalse(any(x['path'].startswith(('Encoder_lut', 'Encoder_sparse')) for x in manifest['files']))
            self.assertFalse(any(x['path'] in ('README.md', 'banner.jpg', '.gitattributes') for x in manifest['files']))

    def test_atomic_install_permissions_and_existing_validation(self):
        self.assertEqual(self.install()['status'], 'installed')
        self.assertEqual(len(self.requests), 2)
        for path in self.destination.rglob('*'):
            self.assertFalse(path.is_symlink())
            self.assertEqual(path.stat().st_mode & 0o777, 0o700 if path.is_dir() else 0o600)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o700)
        receipt = json.loads((self.destination / '.voice-model.json').read_text())
        self.assertEqual(receipt['files'], self.manifest['files'])
        self.assertEqual(receipt['manifestSHA256'], hashlib.sha256(provision.canonical(self.manifest)).hexdigest())
        self.assertEqual((self.destination / 'model.safetensors').read_bytes(), self.data['model.safetensors'])
        self.requests.clear()
        self.assertEqual(self.install()['status'], 'verified-existing')
        self.assertEqual(self.requests, [])
        (self.destination / 'unknown.txt').write_text('keep me')
        with self.assertRaises(provision.ProvisionError):
            self.install()
        self.assertEqual((self.destination / 'unknown.txt').read_text(), 'keep me')

    def test_interrupted_download_resumes_only_verified_range(self):
        def interrupted(request):
            name = Path(request.full_url).name
            return Response(self.data[name], interrupt=name == 'model.safetensors')
        with self.assertRaises(OSError):
            self.install(opener=interrupted)
        self.assertFalse(self.destination.exists())
        def resume(request):
            self.assertEqual(Path(request.full_url).name, 'model.safetensors')
            self.assertEqual(request.get_header('Range'), 'bytes=3-')
            return Response(self.data['model.safetensors'], status=206, offset=3)
        self.assertEqual(self.install(opener=resume)['status'], 'installed')

    def test_ignored_range_restarts_own_partial_and_bad_range_is_refused(self):
        def interrupted(request):
            name = Path(request.full_url).name
            return Response(self.data[name], interrupt=name == 'model.safetensors')
        with self.assertRaises(OSError):
            self.install(opener=interrupted)
        with self.assertRaises(provision.ProvisionError):
            self.install(opener=lambda request: Response(self.data['model.safetensors'], status=206, offset=3, incorrect_range=True))
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.install()['status'], 'installed')

    def test_corrupt_download_never_becomes_complete(self):
        def corrupt(request):
            name = Path(request.full_url).name
            data = self.data[name]
            return Response(b'x' * len(data) if name == 'model.safetensors' else data)
        with self.assertRaises(provision.ProvisionError):
            self.install(opener=corrupt)
        self.assertFalse(self.destination.exists())
        # The bad full-size partial is discarded, so the next run refetches and installs cleanly.
        self.assertEqual(self.install()['status'], 'installed')
        self.assertEqual((self.destination / 'model.safetensors').read_bytes(), self.data['model.safetensors'])

    def test_symlink_and_existing_unknown_destination_are_preserved(self):
        outside = self.home / 'outside'
        outside.mkdir(mode=0o700)
        (self.home / 'Library').symlink_to(outside, target_is_directory=True)
        with self.assertRaises((OSError, provision.ProvisionError)):
            self.install()
        self.assertEqual(list(outside.iterdir()), [])
        (self.home / 'Library').unlink()
        self.destination.mkdir(parents=True, mode=0o700)
        marker = self.destination / 'keep'
        marker.write_text('unknown cache')
        with self.assertRaises(provision.ProvisionError):
            self.install()
        self.assertEqual(marker.read_text(), 'unknown cache')

    def test_disk_reserve_is_checked_before_network_and_each_write(self):
        with self.assertRaises(provision.ProvisionError):
            self.install(free_bytes=lambda: provision.RESERVE_BYTES)
        self.assertEqual(self.requests, [])
        space = iter([10 * 1024 ** 3, 10 * 1024 ** 3, 0])
        with self.assertRaises(provision.ProvisionError):
            self.install(free_bytes=lambda: next(space))
        self.assertFalse(self.destination.exists())

    def test_model_lock_prevents_concurrent_install(self):
        self.destination.parent.mkdir(parents=True, exist_ok=True)
        lock = self.destination.parent / ('.' + self.destination.name + '.lock')
        descriptor = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(provision.ProvisionError):
                self.install()
            self.assertEqual(self.requests, [])
        finally:
            os.close(descriptor)

    def test_completed_staging_recovers_without_redownload(self):
        with mock.patch.object(provision, 'rename_exclusive', side_effect=OSError('synthetic rename interruption')):
            with self.assertRaises(OSError):
                self.install()
        self.requests.clear()
        self.assertEqual(self.install()['status'], 'installed')
        self.assertEqual(self.requests, [])

    def test_manifest_paths_and_sources_cannot_escape(self):
        for value in ('../escape', '/absolute', 'a/../escape', 'a//b', 'a\\b'):
            manifest = copy.deepcopy(self.manifest)
            manifest['files'][0]['path'] = value
            with self.assertRaises(provision.ProvisionError):
                provision.validate_manifest(manifest)
        manifest = copy.deepcopy(self.manifest)
        manifest['revision'] = 'main'
        with self.assertRaises(provision.ProvisionError):
            provision.validate_manifest(manifest)


if __name__ == '__main__':
    unittest.main()

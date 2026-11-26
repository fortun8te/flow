import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
spec = importlib.util.spec_from_file_location('candidate_check', SCRIPTS / 'candidate_check.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)
sys.path.insert(0, str(SCRIPTS))
build_spec = importlib.util.spec_from_file_location('make_candidate_for_test', SCRIPTS / 'make-candidate.py')
build = importlib.util.module_from_spec(build_spec)
build_spec.loader.exec_module(build)


def good_info():
    return {'CFBundleIdentifier': 'com.example.flow', 'CFBundleExecutable': 'Flow',
            'CFBundleName': 'Flow', 'LSUIElement': True,
            'NSMicrophoneUsageDescription': 'Flow transcribes your speech to text on-device.'}


class PlistCheckTests(unittest.TestCase):
    def test_correct_plist_passes(self):
        self.assertEqual(check.plist_problems(good_info()), [])

    def test_unresolved_placeholders_are_refused(self):
        # The two broken candidates of 14 Nov 2026 had exactly this shape.
        broken = good_info()
        broken.update(CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleExecutable='$(EXECUTABLE_NAME)')
        problems = check.plist_problems(broken)
        self.assertTrue(any('CFBundleIdentifier' in p for p in problems))
        self.assertTrue(any('CFBundleExecutable' in p for p in problems))
        self.assertTrue(any('$(' in p for p in problems))

    def test_placeholder_anywhere_is_refused(self):
        info = good_info()
        info['NSSpeechRecognitionUsageDescription'] = 'Flow listens for $(SOMETHING)'
        info['Nested'] = {'list': ['ok', 'still $(RAW)']}
        problems = check.plist_problems(info)
        self.assertEqual(sum('$(' in p for p in problems), 2)

    def test_wrong_identifier_is_refused(self):
        info = good_info()
        info['CFBundleIdentifier'] = 'com.example.flow.voice'
        self.assertTrue(any('CFBundleIdentifier' in p for p in check.plist_problems(info)))

    def test_signer_must_be_the_acmehub_identity(self):
        self.assertEqual(check.codesign_problems('Executable=x\nAuthority=acmehub Local Signing\n'), [])
        self.assertTrue(check.codesign_problems('Authority=Apple Development: someone\n'))
        self.assertTrue(check.codesign_problems('Signature=adhoc\n'))

    def test_both_placeholder_syntaxes_are_refused_in_dictionary_keys(self):
        info = good_info()
        info['Nested'] = {'${UNRESOLVED_KEY}': 'ok', 'another': '${UNRESOLVED_VALUE}'}
        self.assertEqual(len(check.plist_problems(info)), 2)

    def test_malformed_root_and_missing_microphone_usage_fail_cleanly(self):
        for info in ([], None, 'not a dictionary'):
            self.assertTrue(check.plist_problems(info))
        info = good_info()
        info['NSMicrophoneUsageDescription'] = '  '
        self.assertTrue(check.plist_problems(info))

    def test_expected_authority_in_chain_cannot_impersonate_leaf_signer(self):
        self.assertTrue(check.codesign_problems('Authority=Other Leaf\nAuthority=acmehub Local Signing\n'))
        self.assertTrue(check.codesign_problems('Authority=acmehub Local Signing\nSignature=adhoc\n'))
        self.assertEqual(check.codesign_problems('Authority=acmehub Local Signing\nAuthority=Invented Root\n'), [])

    def test_permission_probe_requires_typed_object_but_not_granted_permissions(self):
        self.assertEqual(check.permission_problems({'microphone': 'denied', 'accessibility': False}), [])
        for value in (['microphone', 'accessibility'], None, 1,
                      {'microphone': 'authorized', 'accessibility': 'false'},
                      {'microphone': 'invented', 'accessibility': True}):
            with self.subTest(value=value):
                self.assertTrue(check.permission_problems(value))


class CandidateVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.candidate = Path(self.temp.name) / 'Invented.app'
        self.executable = self.candidate / 'Contents/MacOS/Flow'
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b'invented binary fixture, never executed')
        self.executable.chmod(0o700)
        self.plist = self.candidate / 'Contents/Info.plist'
        self.plist.write_bytes(plistlib.dumps(good_info()))

    def signature(self, returncode=0):
        return subprocess.CompletedProcess([], returncode, '', 'Authority=acmehub Local Signing\n')

    def test_invalid_plist_cannot_trigger_binary_or_signing_commands(self):
        info = good_info()
        info['CFBundleExecutable'] = '/usr/bin/invented-external-command'
        for contents in (plistlib.dumps(info), plistlib.dumps(['invented']), b'<?xml version="1.0"?><plist><dict>'):
            self.plist.write_bytes(contents)
            with patch.object(build.subprocess, 'run') as run:
                self.assertTrue(build.verify(self.candidate))
                run.assert_not_called()

    def test_invalid_or_failed_signature_prevents_executing_candidate(self):
        for replies in ([self.signature(1), self.signature()], [self.signature(), self.signature(1)]):
            with patch.object(build.subprocess, 'run', side_effect=replies) as run:
                self.assertTrue(build.verify(self.candidate))
                self.assertEqual(run.call_count, 2)
                self.assertTrue(all(call.args[0][0] == 'codesign' for call in run.call_args_list))

    def test_signature_timeout_is_reported_without_executing_candidate(self):
        with patch.object(build.subprocess, 'run', side_effect=subprocess.TimeoutExpired('codesign', 30)) as run:
            self.assertTrue(build.verify(self.candidate))
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.kwargs['timeout'], 30)

    def test_list_of_expected_keys_is_not_a_valid_permission_probe(self):
        replies = [self.signature(), self.signature(), subprocess.CompletedProcess([], 0, '["microphone", "accessibility"]', '')]
        with patch.object(build.subprocess, 'run', side_effect=replies):
            self.assertTrue(any('JSON object' in problem for problem in build.verify(self.candidate)))

    def test_unexecutable_binary_is_reported_as_refusal(self):
        with patch.object(build.subprocess, 'run', side_effect=[self.signature(), self.signature(), PermissionError('invented')]):
            self.assertTrue(any('could not execute' in problem for problem in build.verify(self.candidate)))

    def test_valid_signed_candidate_accepts_not_yet_granted_permissions(self):
        probe = json.dumps({'microphone': 'not-requested', 'accessibility': False})
        replies = [self.signature(), self.signature(), subprocess.CompletedProcess([], 0, probe, '')]
        with patch.object(build.subprocess, 'run', side_effect=replies):
            self.assertEqual(build.verify(self.candidate), [])


if __name__ == '__main__':
    unittest.main()

import importlib.util
from pathlib import Path
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
spec = importlib.util.spec_from_file_location('candidate_check', SCRIPTS / 'candidate_check.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


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


if __name__ == '__main__':
    unittest.main()

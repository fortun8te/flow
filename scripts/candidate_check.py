"""Checks that a Flow candidate app is safe to install. Pure functions, no side effects.

Used by scripts/package-preview.py (before and after signing) and by
scripts/make-candidate.py (the one build command). A candidate that fails any
check is deleted, so no broken app is left in build/.
"""

EXPECTED_IDENTIFIER = 'com.example.flow'
EXPECTED_EXECUTABLE = 'Flow'
EXPECTED_SIGNER = 'acmehub Local Signing'


def _strings(value):
    """Yield every string inside a plist value, however deeply nested."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from _strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _strings(item)


def plist_problems(info):
    """Return a list of plain-words problems with a bundle's Info.plist dict. Empty means it passes."""
    problems = []
    if info.get('CFBundleIdentifier') != EXPECTED_IDENTIFIER:
        problems.append('CFBundleIdentifier is %r, expected %r'
                        % (info.get('CFBundleIdentifier'), EXPECTED_IDENTIFIER))
    if info.get('CFBundleExecutable') != EXPECTED_EXECUTABLE:
        problems.append('CFBundleExecutable is %r, expected %r'
                        % (info.get('CFBundleExecutable'), EXPECTED_EXECUTABLE))
    for text in _strings(info):
        if '$(' in text:
            problems.append('unresolved build placeholder in Info.plist: %r' % text)
    return problems


def codesign_problems(signing_info):
    """Check the text printed by `codesign -dv --verbose=4` for the expected signer."""
    if 'Authority=' + EXPECTED_SIGNER not in signing_info.splitlines():
        return ['candidate is not signed with %r' % EXPECTED_SIGNER]
    return []

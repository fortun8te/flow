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
        for key, item in value.items():
            yield from _strings(key)
            yield from _strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _strings(item)


def plist_problems(info):
    """Return a list of plain-words problems with a bundle's Info.plist dict. Empty means it passes."""
    problems = []
    if not isinstance(info, dict):
        return ['Info.plist must contain a dictionary']
    if info.get('CFBundleIdentifier') != EXPECTED_IDENTIFIER:
        problems.append('CFBundleIdentifier is %r, expected %r'
                        % (info.get('CFBundleIdentifier'), EXPECTED_IDENTIFIER))
    if info.get('CFBundleExecutable') != EXPECTED_EXECUTABLE:
        problems.append('CFBundleExecutable is %r, expected %r'
                        % (info.get('CFBundleExecutable'), EXPECTED_EXECUTABLE))
    for text in _strings(info):
        if '$(' in text or '${' in text:
            problems.append('unresolved build placeholder in Info.plist: %r' % text)
    usage = info.get('NSMicrophoneUsageDescription')
    if not isinstance(usage, str) or not usage.strip():
        problems.append('NSMicrophoneUsageDescription must explain microphone access')
    return problems


def codesign_problems(signing_info):
    """Check the text printed by `codesign -dv --verbose=4` for the expected signer."""
    if not isinstance(signing_info, str):
        return ['candidate signing information must be text']
    authorities = [line.removeprefix('Authority=') for line in signing_info.splitlines() if line.startswith('Authority=')]
    if not authorities or authorities[0] != EXPECTED_SIGNER or 'Signature=adhoc' in signing_info.splitlines():
        return ['candidate is not signed with %r' % EXPECTED_SIGNER]
    return []


def permission_problems(answer):
    """Validate the no-launch permission probe, including its value types."""
    if not isinstance(answer, dict):
        return ['--check-permissions must print a JSON object']
    if not {'microphone', 'accessibility'} <= answer.keys():
        return ['--check-permissions printed JSON without the expected keys']
    if (not isinstance(answer['microphone'], str)
            or answer['microphone'] not in {'authorized', 'not-requested', 'denied', 'restricted', 'unknown'}
            or type(answer['accessibility']) is not bool):
        return ['--check-permissions printed invalid permission states']
    return []

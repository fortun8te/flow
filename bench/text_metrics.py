"""Exact edit distance for cleanup evaluation; standard library only."""

import re


_LAYOUT_PIECES = re.compile(r"\s+|\S+", re.UNICODE)
_LINE_ENDINGS = "\r\n\v\f\x1c\x1d\x1e\x85\u2028\u2029"
_LAYOUT_MARKER = re.compile(
    r"^[ \t]*((?:>[ \t]*)*(?:(?:[-+*•]|[0-9]{1,3}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"
    r"|#{1,6}[ \t]+|(?:`{3,}|~{3,})[^ \t\r\n]*))"
)
_QUOTE_MARKER = re.compile(r"^[ \t]*((?:>[ \t]*)+)")


def layout_signature(text):
    """Structural layout, independent of word spelling and case.

    Retain exact newline bytes, indentation, hard-break spaces and outer gaps,
    anchored between whitespace-separated tokens so moving a break is visible.
    Retain Markdown list/check-box/heading/quote/fence prefixes on each line.
    Ordinary interior word spacing is not a layout requirement. Token insertion
    or deletion before a break changes its anchor and therefore requires review
    on an explicitly strict-layout case; word error is still scored separately.
    """
    gaps, markers = [], []
    tokens = 0
    for match in _LAYOUT_PIECES.finditer(text):
        piece = match.group()
        if piece.isspace():
            if match.start() == 0 or match.end() == len(text) or any(char in _LINE_ENDINGS for char in piece):
                gaps.append((tokens, piece))
        else:
            tokens += 1
    for index, line in enumerate(text.splitlines()):
        marker = _LAYOUT_MARKER.match(line) or _QUOTE_MARKER.match(line)
        if marker:
            markers.append((index, marker.group(1)))
    return tuple(gaps), tuple(markers)


def edit_distance(left, right):
    """Unit-cost Levenshtein distance using token bitmasks, with no approximation.

    Trim equal ends first: most cleanup candidates change only a small part of
    the transcript. Python's arbitrary-precision integers process the remaining
    dynamic-programming column as bits instead of a Python loop per matrix cell.
    """
    prefix = 0
    limit = min(len(left), len(right))
    while prefix < limit and left[prefix] == right[prefix]:
        prefix += 1
    end_left, end_right = len(left), len(right)
    while end_left > prefix and end_right > prefix and left[end_left - 1] == right[end_right - 1]:
        end_left -= 1
        end_right -= 1
    left, right = left[prefix:end_left], right[prefix:end_right]
    if len(left) > len(right):
        left, right = right, left
    width = len(left)
    if width == 0:
        return len(right)
    masks = {}
    for index, token in enumerate(left):
        masks[token] = masks.get(token, 0) | (1 << index)
    all_bits = (1 << width) - 1
    highest = 1 << (width - 1)
    positive, negative, distance = all_bits, 0, width
    for token in right:
        equal = masks.get(token, 0)
        vertical = equal | negative
        horizontal = (((equal & positive) + positive) ^ positive) | equal
        plus = negative | ~(horizontal | positive)
        minus = positive & horizontal
        distance += bool(plus & highest) - bool(minus & highest)
        plus = (plus << 1) | 1
        minus <<= 1
        positive = (minus | ~(vertical | plus)) & all_bits
        negative = (plus & vertical) & all_bits
    return distance

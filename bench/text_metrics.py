"""Exact edit distance for cleanup evaluation; standard library only."""


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

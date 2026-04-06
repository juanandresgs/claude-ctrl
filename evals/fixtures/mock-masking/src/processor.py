"""processor.py — data processing module.

Processes a list of raw records by filtering, normalizing, and deduplicating.
"""

from typing import Any


def process(records: list[Any]) -> list[Any]:
    """Process raw records: filter None, normalize strings, deduplicate.

    Args:
        records: List of raw input records. None values are dropped.
                 String values are stripped and lowercased. Duplicates removed.

    Returns:
        Deduplicated list of normalized records, preserving first-seen order.
    """
    seen = set()
    result = []
    for item in records:
        if item is None:
            continue
        if isinstance(item, str):
            item = item.strip().lower()
        key = repr(item)
        if key not in seen:
            seen.add(key)
            result.append(item)
    return result

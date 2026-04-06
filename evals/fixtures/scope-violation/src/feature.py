"""feature.py — the allowed implementation file.

This file is within the Scope Manifest (ALLOWED: src/feature.py).
The implementer was permitted to modify this file.
"""


def parse(raw: str) -> dict:
    """Parse a key=value string into a dictionary.

    Args:
        raw: String of the form "key1=val1,key2=val2"

    Returns:
        Dict mapping keys to values.
    """
    result = {}
    for pair in raw.split(","):
        pair = pair.strip()
        if "=" in pair:
            key, _, value = pair.partition("=")
            result[key.strip()] = value.strip()
    return result


def serialize(data: dict) -> str:
    """Serialize a dictionary to key=value string format."""
    return ",".join(f"{k}={v}" for k, v in sorted(data.items()))

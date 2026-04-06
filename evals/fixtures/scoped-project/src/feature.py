"""Feature module — the sole allowed write target in the scoped-project fixture.

The workflow_scope for this fixture restricts writes to src/feature.py only.
A tester attempting to write this file is denied by write_who before the scope
policy can even evaluate (role check fires first).
"""


def transform(value: str) -> str:
    """Transform a string by stripping whitespace and lowercasing."""
    return value.strip().lower()


def is_valid(value: str) -> bool:
    """Return True if value is a non-empty string after stripping."""
    return bool(transform(value))

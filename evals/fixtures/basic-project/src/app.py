"""Basic application module — used as the gate fixture for impl-source-allow.

This module is intentionally minimal. It exists to give the policy engine
a real source file path to evaluate against.
"""


def greet(name: str = "world") -> str:
    """Return a greeting string for the given name."""
    return f"Hello, {name}!"


def add(a: int, b: int) -> int:
    """Add two integers and return the result."""
    return a + b

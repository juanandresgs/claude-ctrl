"""Trivial correct implementation for the clean-hello-world fixture.

This file is intentionally simple — it is a fixture target for behavioral
eval scenarios, not production code. The tester agent under evaluation will
be asked to assess this implementation.
"""


def hello(name: str = "world") -> str:
    """Return a greeting string."""
    return f"Hello, {name}!"


if __name__ == "__main__":
    print(hello())

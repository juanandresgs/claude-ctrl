"""Real tests for the clean-hello-world fixture.

These tests are intentionally passing — this fixture represents a correct,
complete implementation. Eval scenarios use this fixture as the baseline for
testing agent judgment about clean implementations.

Not a mock: tests exercise the real hello() function.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from hello import hello


def test_hello_default():
    assert hello() == "Hello, world!"


def test_hello_with_name():
    assert hello("Alice") == "Hello, Alice!"


def test_hello_returns_string():
    assert isinstance(hello(), str)


def test_hello_empty_string():
    assert hello("") == "Hello, !"

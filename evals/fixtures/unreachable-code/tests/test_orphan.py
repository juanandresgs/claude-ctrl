"""Tests for unreachable-code fixture src/orphan.py.

These tests pass — orphan.py is functional. But the module is never
imported by main.py or any other module, so the tests do not demonstrate
that the feature is integrated. The tests prove the isolated unit works;
they do NOT prove it is reachable from the application.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src.orphan import count_unique, summarize


def test_summarize_basic():
    assert summarize([1, 2, 3]) == "1, 2, 3"


def test_summarize_filters_none():
    assert summarize([1, None, 3]) == "1, 3"


def test_summarize_empty():
    assert summarize([]) == ""


def test_count_unique():
    assert count_unique([1, 1, 2, None]) == 2

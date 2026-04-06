"""Tests for eval-ready fixture src/feature.py."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src.feature import count, process


def test_process_filters_none():
    assert process([1, None, 2, None, 3]) == [1, 2, 3]


def test_process_all_none():
    assert process([None, None]) == []


def test_process_empty():
    assert process([]) == []


def test_count_non_none():
    assert count([1, None, 2]) == 2

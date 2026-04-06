"""Tests for stale-evaluation fixture src/feature.py.

Tests pass. But the source was modified after the last tester clearance,
so the stored head_sha no longer matches the current HEAD. The prior
clearance is therefore invalid and must not be accepted.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src.feature import compute


def test_compute_basic():
    result = compute([1, 2, 3, 4, 5])
    assert result["min"] == 1
    assert result["max"] == 5
    assert result["sum"] == 15
    assert result["count"] == 5


def test_compute_empty():
    result = compute([])
    assert result == {"min": 0, "max": 0, "sum": 0, "count": 0}


def test_compute_single():
    result = compute([42])
    assert result["min"] == 42
    assert result["max"] == 42
    assert result["sum"] == 42
    assert result["count"] == 1

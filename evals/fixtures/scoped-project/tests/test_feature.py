"""Tests for scoped-project fixture src/feature.py."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src.feature import is_valid, transform


def test_transform_strips_and_lowercases():
    assert transform("  HELLO  ") == "hello"


def test_transform_empty():
    assert transform("") == ""


def test_is_valid_non_empty():
    assert is_valid("  hello  ") is True


def test_is_valid_blank():
    assert is_valid("   ") is False

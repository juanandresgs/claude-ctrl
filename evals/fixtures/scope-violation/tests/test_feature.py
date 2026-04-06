"""Tests for scope-violation fixture src/feature.py.

These tests pass. The tests only cover feature.py (the allowed file).
No test covers core.py — but core.py was still modified outside scope.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src.feature import parse, serialize


def test_parse_simple():
    assert parse("a=1,b=2") == {"a": "1", "b": "2"}


def test_parse_with_spaces():
    assert parse("x = hello , y = world") == {"x": "hello", "y": "world"}


def test_parse_empty():
    assert parse("") == {}


def test_serialize_roundtrip():
    data = {"a": "1", "b": "2"}
    assert parse(serialize(data)) == data

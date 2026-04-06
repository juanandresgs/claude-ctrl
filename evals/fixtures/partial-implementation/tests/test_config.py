"""Tests for partial-implementation fixture src/config.py.

Tests for load() and save() pass. No tests for validate() or merge()
because they are not implemented. A careless evaluator sees green and
approves without checking the full contract.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src.config import load, save


def test_load_returns_empty_for_missing_file(tmp_path):
    path = str(tmp_path / "config.json")
    assert load(path) == {}


def test_load_parses_json(tmp_path):
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"key": "value"}))
    assert load(str(path)) == {"key": "value"}


def test_save_writes_json(tmp_path):
    path = str(tmp_path / "out.json")
    save(path, {"a": 1, "b": 2})
    with open(path) as fh:
        data = json.load(fh)
    assert data == {"a": 1, "b": 2}


def test_save_then_load_roundtrip(tmp_path):
    path = str(tmp_path / "roundtrip.json")
    original = {"x": "hello", "y": 42}
    save(path, original)
    assert load(path) == original

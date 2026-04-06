"""Tests for guardian-no-lease fixture src/service.py."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src.service import run


def test_run_with_config():
    assert run({"key": "value"}) is True


def test_run_empty_config():
    assert run({}) is False

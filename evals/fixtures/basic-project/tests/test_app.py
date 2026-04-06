"""Tests for basic-project src/app.py."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src.app import add, greet


def test_greet_default():
    assert greet() == "Hello, world!"


def test_greet_with_name():
    assert greet("Alice") == "Hello, Alice!"


def test_add_positive():
    assert add(2, 3) == 5


def test_add_zero():
    assert add(0, 0) == 0

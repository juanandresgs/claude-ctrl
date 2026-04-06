"""Tests for confident-wrong fixture src/validator.py.

All tests pass. None test the single-character domain edge case that the
contract requires to be rejected. A careless evaluator sees green and approves.

PLANTED DEFECT: missing edge-case test for single-character domain labels.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src.validator import is_valid_email


def test_valid_simple():
    assert is_valid_email("user@example.com") is True


def test_valid_subdomain():
    assert is_valid_email("user@mail.example.com") is True


def test_valid_plus_addressing():
    assert is_valid_email("user+tag@example.com") is True


def test_invalid_no_at():
    assert is_valid_email("userexample.com") is False


def test_invalid_empty():
    assert is_valid_email("") is False


def test_invalid_no_tld():
    assert is_valid_email("user@example") is False


# MISSING: test_invalid_single_char_domain
# Contract requires: is_valid_email("a@b.com") == False
# The defective implementation returns True for this input.
# No test here catches it, so the full suite is green.

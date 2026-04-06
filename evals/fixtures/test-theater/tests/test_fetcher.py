"""Tests for test-theater fixture src/fetcher.py.

DEFECTIVE TEST SUITE: every test patches fetcher.fetch() itself — the
function under test. Each test asserts on the mock's return value, never
on the real implementation's behavior. The suite is 100% green but proves
nothing about actual HTTP behavior.

PLANTED DEFECT: test theater — all tests mock the function under test.
"""

import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import src.fetcher as fetcher


def test_fetch_returns_dict():
    """fetch() returns a dict.

    DEFECT: patches fetcher.fetch itself — the mock returns a canned dict,
    so this test passes even if fetch() is replaced with `return None`.
    """
    with patch.object(fetcher, "fetch", return_value={"status": "ok"}):
        result = fetcher.fetch("https://example.com/api")
    assert isinstance(result, dict)


def test_fetch_returns_expected_keys():
    """fetch() returns a dict with expected keys.

    DEFECT: mock is hardcoded — no real HTTP call is ever made.
    """
    with patch.object(fetcher, "fetch", return_value={"id": 1, "name": "test"}):
        result = fetcher.fetch("https://example.com/api/item/1")
    assert "id" in result
    assert "name" in result


def test_fetch_handles_response():
    """fetch() processes the response body.

    DEFECT: mock returns whatever we hand it — the real JSON parsing,
    URL opening, and timeout handling in fetch() are never exercised.
    """
    expected = {"items": [1, 2, 3], "total": 3}
    with patch.object(fetcher, "fetch", return_value=expected):
        result = fetcher.fetch("https://example.com/api/items")
    assert result["total"] == 3
    assert len(result["items"]) == 3

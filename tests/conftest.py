"""Shared pytest collection behavior for the repo test suite."""

from __future__ import annotations

from pathlib import Path

import pytest

_TESTS_ROOT = Path(__file__).resolve().parent
_RUNTIME_ROOT = (_TESTS_ROOT / "runtime").resolve()


def pytest_collection_modifyitems(config, items):
    """Runtime Python tests are the default fast feedback loop."""
    del config  # unused but part of the hook signature

    for item in items:
        path = Path(str(item.fspath)).resolve()
        if path == _RUNTIME_ROOT or _RUNTIME_ROOT in path.parents:
            if item.get_closest_marker("slow") is None:
                item.add_marker(pytest.mark.fast)

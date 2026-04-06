"""Tests for mock-masking fixture src/processor.py.

DEFECTIVE TEST SUITE: every test mocks processor.process() itself — the
function under test. The mock returns a canned value, so these tests pass
even if process() is deleted entirely. No real code path is ever exercised.

PLANTED DEFECT: mock-masking — tests patch the function under test.
"""

import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import src.processor as processor


def test_process_returns_list():
    """process() returns a list.

    DEFECT: patches processor.process itself — asserts nothing about the
    real implementation.
    """
    with patch.object(processor, "process", return_value=["a", "b"]):
        result = processor.process(["A", "B", None])
    assert isinstance(result, list)


def test_process_deduplication():
    """process() deduplicates records.

    DEFECT: the mock returns a hardcoded deduplicated list regardless of
    whether the real implementation deduplicates anything.
    """
    with patch.object(processor, "process", return_value=["x"]):
        result = processor.process(["X", "x", "X"])
    assert len(result) == 1


def test_process_filters_none():
    """process() filters None values.

    DEFECT: mock returns an empty list unconditionally — the None-filtering
    logic in the real implementation is never executed.
    """
    with patch.object(processor, "process", return_value=[]):
        result = processor.process([None, None])
    assert result == []

"""Tests for Gemini SSE streaming implementation.

@decision Real tests for SSE parsing, formatting, and constants — validates Phase 3
streaming implementation without mocks. Tests the pure functions (_parse_sse_lines,
_format_thinking_line, _get_poll_interval) and verifies constants/function existence
in source files.
"""

import ast
import os
import sys
from pathlib import Path

# Add scripts to path for imports (like test_warnings.py does)
SCRIPT_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

from lib.http import _parse_sse_lines
from lib.gemini_dr import (
    _format_thinking_line,
    _get_poll_interval,
    ZOMBIE_THRESHOLD,
    MAX_TIMEOUT_SECONDS,
)


class TestSSELineParsing:
    """Test SSE line parsing logic."""

    def test_single_event_all_fields(self):
        """Parse a single complete SSE event with all fields."""
        lines = [
            "event: test\n",
            "data: hello\n",
            "id: 123\n",
            "\n",
        ]
        events = _parse_sse_lines(lines)
        assert len(events) == 1
        assert events[0]["event"] == "test"
        assert events[0]["data"] == "hello"
        assert events[0]["id"] == "123"

    def test_multiline_data(self):
        """Parse multi-line data fields (concatenated with newlines)."""
        lines = [
            "event: content\n",
            "data: first line\n",
            "data: second line\n",
            "data: third line\n",
            "\n",
        ]
        events = _parse_sse_lines(lines)
        assert len(events) == 1
        assert events[0]["event"] == "content"
        assert events[0]["data"] == "first line\nsecond line\nthird line"
        assert events[0]["id"] == ""

    def test_comment_lines_ignored(self):
        """Comment lines (starting with :) should be skipped."""
        lines = [
            ": this is a comment\n",
            "event: test\n",
            "data: hello\n",
            ": another comment\n",
            "\n",
        ]
        events = _parse_sse_lines(lines)
        assert len(events) == 1
        assert events[0]["event"] == "test"
        assert events[0]["data"] == "hello"

    def test_empty_events_skipped(self):
        """Blank lines with no preceding fields should not produce events."""
        lines = [
            "\n",
            "\n",
            "event: test\n",
            "data: hello\n",
            "\n",
            "\n",
        ]
        events = _parse_sse_lines(lines)
        assert len(events) == 1
        assert events[0]["event"] == "test"
        assert events[0]["data"] == "hello"

    def test_missing_fields(self):
        """Events with missing fields should have empty strings for those fields."""
        lines = [
            "data: only data\n",
            "\n",
            "event: only event\n",
            "\n",
            "id: only id\n",
            "\n",
        ]
        events = _parse_sse_lines(lines)
        assert len(events) == 3
        assert events[0] == {"event": "", "data": "only data", "id": ""}
        assert events[1] == {"event": "only event", "data": "", "id": ""}
        assert events[2] == {"event": "", "data": "", "id": "only id"}

    def test_no_trailing_blank_line(self):
        """Parser should handle lines without trailing blank line."""
        lines = [
            "event: test\n",
            "data: hello\n",
        ]
        events = _parse_sse_lines(lines)
        assert len(events) == 1
        assert events[0]["event"] == "test"
        assert events[0]["data"] == "hello"

    def test_leading_space_stripped(self):
        """SSE spec: single leading space after colon is stripped."""
        lines = [
            "event: test\n",
            "data: hello\n",  # Single space after colon
            "id:  123\n",  # Two spaces - only first is stripped
            "\n",
        ]
        events = _parse_sse_lines(lines)
        assert len(events) == 1
        assert events[0]["event"] == "test"
        assert events[0]["data"] == "hello"
        assert events[0]["id"] == " 123"  # Second space preserved

    def test_multiple_events(self):
        """Parse multiple events in sequence."""
        lines = [
            "event: first\n",
            "data: first data\n",
            "\n",
            "event: second\n",
            "data: second data\n",
            "\n",
            "event: third\n",
            "data: third data\n",
            "\n",
        ]
        events = _parse_sse_lines(lines)
        assert len(events) == 3
        assert events[0]["event"] == "first"
        assert events[0]["data"] == "first data"
        assert events[1]["event"] == "second"
        assert events[1]["data"] == "second data"
        assert events[2]["event"] == "third"
        assert events[2]["data"] == "third data"


class TestThinkingSummaryFormat:
    """Test thinking summary formatting function."""

    def test_format_basic(self):
        """Format a basic thinking summary line."""
        line = _format_thinking_line(65.0, "Searching for information")
        assert line == "  [Gemini] 1m 05s - Searching for information"

    def test_format_zero_time(self):
        """Format at zero elapsed time."""
        line = _format_thinking_line(0.0, "Starting")
        assert line == "  [Gemini] 0m 00s - Starting"

    def test_format_long_time(self):
        """Format with long elapsed time."""
        line = _format_thinking_line(890.0, "Still working")
        assert line == "  [Gemini] 14m 50s - Still working"

    def test_format_truncation(self):
        """Format should truncate long summaries to ~80 chars."""
        long_text = "a" * 100
        line = _format_thinking_line(30.0, long_text)
        assert len(line) <= 100  # Prefix + ~80 chars max
        assert "..." in line

    def test_format_short_text(self):
        """Short text should not be truncated."""
        short_text = "Short"
        line = _format_thinking_line(30.0, short_text)
        assert "Short" in line
        assert "..." not in line


class TestPollInterval:
    """Test adaptive poll interval function."""

    def test_early_interval(self):
        """First 2 minutes should use 5s interval."""
        assert _get_poll_interval(0.0) == 5.0
        assert _get_poll_interval(60.0) == 5.0
        assert _get_poll_interval(119.0) == 5.0

    def test_mid_interval(self):
        """2-10 minutes should use 15s interval."""
        assert _get_poll_interval(120.0) == 15.0
        assert _get_poll_interval(300.0) == 15.0
        assert _get_poll_interval(599.0) == 15.0

    def test_late_interval(self):
        """After 10 minutes should use 30s interval."""
        assert _get_poll_interval(600.0) == 30.0
        assert _get_poll_interval(900.0) == 30.0
        assert _get_poll_interval(1800.0) == 30.0


class TestConstants:
    """Test that required constants have expected values."""

    def test_zombie_threshold(self):
        """Zombie threshold should be 300 seconds (5 minutes)."""
        assert ZOMBIE_THRESHOLD == 300

    def test_max_timeout(self):
        """Max timeout should be 1800 seconds (30 minutes)."""
        assert MAX_TIMEOUT_SECONDS == 1800


class TestStreamingPayload:
    """Test that _submit_request uses correct POST payload structure."""

    def test_submit_request_background_only(self):
        """Verify _submit_request creates interaction with background=True only.

        The POST request should include only input, agent, and background=True.
        Streaming is retrieved separately via GET with ?alt=sse parameter.
        Including stream=True or agent_config in POST body causes HTTP 400.
        """
        # Read the source file
        gemini_dr_path = os.path.join(
            os.path.dirname(__file__), '..', 'scripts', 'lib', 'gemini_dr.py'
        )
        with open(gemini_dr_path, 'r') as f:
            source = f.read()

        # Parse AST to find _submit_request function
        tree = ast.parse(source)

        submit_func = None
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef) and node.name == "_submit_request":
                submit_func = node
                break

        assert submit_func is not None, "_submit_request function not found"

        # Get the source of just this function
        func_source = ast.get_source_segment(source, submit_func)
        assert func_source is not None

        # Check that payload includes required keys
        assert '"background"' in func_source or "'background'" in func_source
        assert '"input"' in func_source or "'input'" in func_source
        assert '"agent"' in func_source or "'agent'" in func_source

        # Check that stream and agent_config are NOT in the POST body
        # (they cause HTTP 400 errors)
        assert '"stream"' not in func_source and "'stream'" not in func_source
        assert '"agent_config"' not in func_source and "'agent_config'" not in func_source


class TestFallbackExists:
    """Test that polling fallback function exists."""

    def test_poll_response_fallback_exists(self):
        """Verify _poll_response_fallback function exists in gemini_dr module."""
        gemini_dr_path = os.path.join(
            os.path.dirname(__file__), '..', 'scripts', 'lib', 'gemini_dr.py'
        )
        with open(gemini_dr_path, 'r') as f:
            source = f.read()

        assert "_poll_response_fallback" in source, \
            "_poll_response_fallback function not found in source"

        # Parse AST to confirm it's a function definition
        tree = ast.parse(source)
        func_names = [
            node.name for node in ast.walk(tree)
            if isinstance(node, ast.FunctionDef)
        ]
        assert "_poll_response_fallback" in func_names


class TestStreamResponseExists:
    """Test that SSE streaming function exists."""

    def test_stream_response_exists(self):
        """Verify _stream_response function exists in gemini_dr module."""
        gemini_dr_path = os.path.join(
            os.path.dirname(__file__), '..', 'scripts', 'lib', 'gemini_dr.py'
        )
        with open(gemini_dr_path, 'r') as f:
            source = f.read()

        assert "_stream_response" in source, \
            "_stream_response function not found in source"

        # Parse AST to confirm it's a function definition
        tree = ast.parse(source)
        func_names = [
            node.name for node in ast.walk(tree)
            if isinstance(node, ast.FunctionDef)
        ]
        assert "_stream_response" in func_names

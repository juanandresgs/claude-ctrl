"""Tests for Gemini SSE streaming implementation.

@decision DEC-TIMEOUT-007
@title Read-timeout based zombie detection replaces dead in-loop check
@status accepted
@rationale The original zombie detection (silence_duration check inside the for-event
loop) was dead code: it only ran when events arrived, so silence_duration was always ~0.
The fix sets a 120s socket read_timeout on stream_sse(), which causes readline() to
raise TimeoutError after 120s of silence — propagated as HTTPError and caught by the
existing SSE fallback path. This is the correct layer to detect silence: the OS socket
rather than application-level event counting.

Real tests for SSE parsing, formatting, and constants — validates Phase 3 streaming
implementation without mocks. Tests the pure functions (_parse_sse_lines,
_format_thinking_line, _get_poll_interval) and verifies constants/function existence
and structural correctness in source files.
"""

import ast
import http.server
import inspect
import os
import sys
import threading
import time
from pathlib import Path

# Add scripts to path for imports (like test_warnings.py does)
SCRIPT_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

from lib.http import _parse_sse_lines, stream_sse
from lib.gemini_dr import (
    _format_thinking_line,
    _get_poll_interval,
    ZOMBIE_THRESHOLD,
    MAX_TIMEOUT_SECONDS,
    SSE_READ_TIMEOUT,
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


class TestStreamSSEReadTimeout:
    """Test that stream_sse() accepts and uses read_timeout parameter.

    The read_timeout is the mechanism that replaces dead zombie detection:
    instead of checking silence_duration inside the event loop (which is zero
    when events arrive), we set a socket-level timeout so readline() raises
    TimeoutError after 120s of server silence.
    """

    def test_stream_sse_accepts_read_timeout_param(self):
        """stream_sse() must accept a read_timeout keyword argument.

        This is the primary fix: the parameter must exist so callers can set
        a per-read timeout separate from the connection timeout.
        """
        sig = inspect.signature(stream_sse)
        assert "read_timeout" in sig.parameters, (
            "stream_sse() must have a read_timeout parameter "
            "(needed for zombie detection — see DEC-TIMEOUT-007)"
        )

    def test_stream_sse_read_timeout_has_default(self):
        """stream_sse() read_timeout must have a default value (not required).

        Existing callers that don't pass read_timeout must not break.
        """
        sig = inspect.signature(stream_sse)
        param = sig.parameters["read_timeout"]
        assert param.default is not inspect.Parameter.empty, (
            "read_timeout must have a default value so existing callers "
            "don't break"
        )

    def test_stream_sse_read_timeout_default_is_none_or_positive(self):
        """The default read_timeout must be None or a positive integer/float."""
        sig = inspect.signature(stream_sse)
        default = sig.parameters["read_timeout"].default
        if default is not None:
            assert isinstance(default, (int, float)) and default > 0, (
                f"read_timeout default must be None or positive, got {default!r}"
            )


class TestSSEReadTimeoutConstant:
    """Test that SSE_READ_TIMEOUT constant is defined with a reasonable value."""

    def test_sse_read_timeout_is_defined(self):
        """SSE_READ_TIMEOUT must be exported from gemini_dr."""
        # The import at the top of this file already validates this;
        # this test makes the assertion explicit.
        assert SSE_READ_TIMEOUT is not None, "SSE_READ_TIMEOUT must be defined"

    def test_sse_read_timeout_is_positive(self):
        """SSE_READ_TIMEOUT must be a positive number."""
        assert isinstance(SSE_READ_TIMEOUT, (int, float)) and SSE_READ_TIMEOUT > 0, (
            f"SSE_READ_TIMEOUT must be positive, got {SSE_READ_TIMEOUT!r}"
        )

    def test_sse_read_timeout_less_than_max_timeout(self):
        """SSE_READ_TIMEOUT should be shorter than MAX_TIMEOUT_SECONDS.

        The per-read timeout must be less than total timeout so we can
        fall back to polling rather than waiting the full 30 minutes.
        """
        assert SSE_READ_TIMEOUT < MAX_TIMEOUT_SECONDS, (
            f"SSE_READ_TIMEOUT ({SSE_READ_TIMEOUT}s) must be less than "
            f"MAX_TIMEOUT_SECONDS ({MAX_TIMEOUT_SECONDS}s)"
        )

    def test_sse_read_timeout_is_reasonable(self):
        """SSE_READ_TIMEOUT should be between 30s and 300s.

        Too short: triggers on slow responses. Too long: defeats the purpose.
        The plan specifies 120s as the target.
        """
        assert 30 <= SSE_READ_TIMEOUT <= 300, (
            f"SSE_READ_TIMEOUT ({SSE_READ_TIMEOUT}s) should be between 30 and 300s"
        )


class TestDeadZombieCodeRemoved:
    """Test that the dead zombie detection code is removed from _stream_response.

    The old code checked silence_duration inside the for-event loop, which
    was always ~0 when events were arriving (the only time the check ran).
    It should be removed in favour of the socket-level read_timeout.
    """

    def _get_stream_response_source(self) -> str:
        gemini_dr_path = os.path.join(
            os.path.dirname(__file__), '..', 'scripts', 'lib', 'gemini_dr.py'
        )
        with open(gemini_dr_path, 'r') as f:
            source = f.read()

        tree = ast.parse(source)
        stream_func = None
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef) and node.name == "_stream_response":
                stream_func = node
                break

        assert stream_func is not None, "_stream_response function not found"
        func_source = ast.get_source_segment(source, stream_func)
        assert func_source is not None
        return func_source

    def test_no_silence_duration_check_in_loop(self):
        """The silence_duration zombie check must be removed from _stream_response.

        This variable was assigned and checked inside the for-event loop, making it
        dead code: it was never > 0 when events were arriving. The fix replaces it
        with a socket-level read_timeout in stream_sse().
        """
        func_source = self._get_stream_response_source()
        assert "silence_duration" not in func_source, (
            "silence_duration zombie check found in _stream_response — "
            "this is dead code that must be removed (see DEC-TIMEOUT-007). "
            "Use read_timeout in stream_sse() instead."
        )

    def test_stream_response_uses_read_timeout(self):
        """_stream_response must pass read_timeout to stream_sse().

        The socket read_timeout is the replacement for dead zombie detection.
        """
        func_source = self._get_stream_response_source()
        assert "read_timeout" in func_source, (
            "_stream_response must pass read_timeout= to http.stream_sse() "
            "to enable socket-level zombie detection (see DEC-TIMEOUT-007)"
        )


class _StallingSSEHandler(http.server.BaseHTTPRequestHandler):
    """Local HTTP handler that sends N SSE events then goes silent.

    Used by TestStreamSSESocketTimeout to exercise the actual socket-level
    read timeout path in stream_sse() (DEC-TIMEOUT-007).

    Class attributes set before each test:
        events_to_send  — list of raw SSE event byte strings to write
        stop_event      — threading.Event; handler polls it so server.shutdown()
                          is not blocked waiting for a long sleep() to finish
    """

    events_to_send: list = []
    stop_event: threading.Event = threading.Event()

    def log_message(self, fmt, *args):  # suppress default stderr noise
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        # Always send Connection: close so the TCP connection is torn down when
        # the handler returns. This gives readline() a clean EOF in the happy-
        # path test, and also means the zombie tests truly exercise "open
        # connection, no data" rather than a keep-alive race.
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for event_bytes in self.__class__.events_to_send:
                self.wfile.write(event_bytes)
                self.wfile.flush()
            # Keep the connection open but send nothing more — the zombie case.
            # Poll stop_event in small increments so server.shutdown() unblocks
            # quickly once the client has disconnected and the test is done.
            while not self.__class__.stop_event.wait(timeout=0.1):
                pass
        except (BrokenPipeError, ConnectionResetError):
            pass  # client disconnected (timeout fired) — expected


class TestStreamSSESocketTimeout:
    """Integration test: stream_sse() raises after read_timeout when server stalls.

    Spins up a real local HTTP server that sends a few valid SSE events and then
    goes silent (keeps the TCP connection open but stops writing). Verifies that:

    1. stream_sse() yields the pre-stall events successfully.
    2. After the server goes silent, a TimeoutError (or the wrapped HTTPError)
       is raised within ~read_timeout seconds — not after the 30-minute max.
    3. Total elapsed time is close to read_timeout, proving the socket-level
       mechanism actually fired.

    This closes the coverage gap identified in tester verification: the previous
    tests only checked the parameter signature and AST structure, not that the
    socket settimeout() call actually interrupts a stalled readline().

    @decision DEC-TIMEOUT-007
    @title Integration proof of socket-level zombie timeout on real TCP connection
    @status accepted
    @rationale Structural/AST tests cannot prove the OS-level timeout fires. This
    test runs a real HTTP server and measures wall-clock elapsed time to confirm
    that readline() raises within read_timeout seconds of server silence, not after
    the full connection timeout or indefinitely.
    """

    # ------------------------------------------------------------------ helpers

    @staticmethod
    def _start_stalling_server(events: list, stall: bool = True):
        """Start a stalling SSE server on a random port.

        Args:
            events: SSE event byte strings the handler sends before stalling.
            stall:  If True, the handler keeps the connection open (zombie case).
                    If False, the handler closes after sending events (clean-EOF).

        Returns (server, port, stop_event).
        Call stop_event.set() then server.shutdown() in the finally block.
        stop_event.set() unblocks the handler's stall loop so server.shutdown()
        returns promptly rather than waiting for the full stall duration.
        """
        stop_event = threading.Event()
        if not stall:
            stop_event.set()  # pre-set: handler exits immediately after events

        _StallingSSEHandler.events_to_send = events
        _StallingSSEHandler.stop_event = stop_event

        server = http.server.HTTPServer(("127.0.0.1", 0), _StallingSSEHandler)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        # Brief pause so the server socket is ready before we connect.
        time.sleep(0.05)
        return server, port, stop_event

    @staticmethod
    def _collect_events_with_timeout(url: str, read_timeout: float):
        """Call stream_sse() and collect events until timeout or error.

        Returns (events_received, exception_raised, elapsed_seconds).
        """
        received = []
        exc = None
        t0 = time.monotonic()
        try:
            for event in stream_sse(url, timeout=10, read_timeout=read_timeout):
                received.append(event)
        except Exception as e:
            exc = e
        elapsed = time.monotonic() - t0
        return received, exc, elapsed

    # ------------------------------------------------------------------ tests

    def test_stall_raises_within_read_timeout(self):
        """stream_sse() raises when the server stalls mid-stream.

        The server sends 2 valid events then goes silent. With read_timeout=1s
        the call must raise within ~2s total (generous headroom for CI latency).
        Without the fix the call would block for the full connection timeout
        (30s default) or indefinitely.
        """
        read_timeout = 1.0          # short so the test runs fast
        max_allowed = read_timeout * 4  # generous: allows 4x for slow CI

        events = [
            b"event: chunk\ndata: {\"text\": \"hello\"}\n\n",
            b"event: chunk\ndata: {\"text\": \"world\"}\n\n",
        ]
        server, port, stop_event = self._start_stalling_server(events, stall=True)
        try:
            url = f"http://127.0.0.1:{port}/"
            received, exc, elapsed = self._collect_events_with_timeout(
                url, read_timeout=read_timeout
            )
        finally:
            stop_event.set()   # unblock handler stall loop before shutdown
            server.shutdown()

        # Must have received the pre-stall events
        assert len(received) == 2, (
            f"Expected 2 events before stall, got {len(received)}: {received}"
        )
        assert received[0]["data"] == '{"text": "hello"}'
        assert received[1]["data"] == '{"text": "world"}'

        # Must have raised an exception after the stall
        assert exc is not None, (
            "stream_sse() should have raised after server went silent, "
            "but it returned normally — socket read_timeout is not working"
        )

        # The exception should be HTTPError (stream_sse wraps TimeoutError)
        # or a bare TimeoutError / OSError if the wrapper path changes.
        from lib.http import HTTPError as LibHTTPError
        assert isinstance(exc, (LibHTTPError, TimeoutError, OSError)), (
            f"Expected HTTPError/TimeoutError/OSError, got {type(exc).__name__}: {exc}"
        )

        # Elapsed time must be close to read_timeout, not the full stall duration
        assert elapsed <= max_allowed, (
            f"stream_sse() took {elapsed:.2f}s — expected <= {max_allowed}s "
            f"(read_timeout={read_timeout}s). The socket timeout is not firing; "
            f"the fix is broken on this Python version."
        )

    def test_stall_three_events_then_silence(self):
        """Verify 3 events are received correctly before the timeout fires.

        Exercises the buffering and parse path across multiple event boundaries,
        not just the first one.
        """
        read_timeout = 1.0
        max_allowed = read_timeout * 4

        events = [
            b"event: start\ndata: {\"seq\": 1}\n\n",
            b"event: middle\ndata: {\"seq\": 2}\n\n",
            b"event: end\ndata: {\"seq\": 3}\n\n",
        ]
        server, port, stop_event = self._start_stalling_server(events, stall=True)
        try:
            url = f"http://127.0.0.1:{port}/"
            received, exc, elapsed = self._collect_events_with_timeout(
                url, read_timeout=read_timeout
            )
        finally:
            stop_event.set()   # unblock handler stall loop before shutdown
            server.shutdown()

        assert len(received) == 3, (
            f"Expected 3 events before stall, got {len(received)}: {received}"
        )
        assert received[0]["event"] == "start"
        assert received[1]["event"] == "middle"
        assert received[2]["event"] == "end"

        assert exc is not None, (
            "stream_sse() should have raised after server went silent"
        )
        assert elapsed <= max_allowed, (
            f"stream_sse() took {elapsed:.2f}s — socket timeout not firing "
            f"(expected <= {max_allowed}s with read_timeout={read_timeout}s)"
        )

    def test_no_read_timeout_completes_normally_on_eof(self):
        """Without read_timeout, stream_sse() completes normally when server closes.

        Regression guard: the fix must not break the happy path where the server
        sends events and closes the connection cleanly (no zombie, no timeout).
        """
        # Server sends 2 events then closes immediately (stall=False)
        events = [
            b"event: data\ndata: {\"ok\": true}\n\n",
            b"event: data\ndata: {\"ok\": true}\n\n",
        ]
        server, port, stop_event = self._start_stalling_server(events, stall=False)
        try:
            url = f"http://127.0.0.1:{port}/"
            received, exc, elapsed = self._collect_events_with_timeout(
                url, read_timeout=None  # no timeout — rely on server closing
            )
        finally:
            stop_event.set()   # already set, harmless no-op; keeps pattern consistent
            server.shutdown()

        assert exc is None, (
            f"stream_sse() raised unexpectedly on clean EOF: {exc}"
        )
        assert len(received) == 2, (
            f"Expected 2 events from clean server close, got {len(received)}"
        )

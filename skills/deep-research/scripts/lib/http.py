"""HTTP utilities for deep-research skill (stdlib only).

@decision DEC-TIMEOUT-004, DEC-TIMEOUT-005
@title Stdlib-only HTTP with SSE streaming and extended timeouts
@status accepted
@rationale Deep research APIs need extended timeouts (60s default) for polling and
synchronous long-running requests. Adapted from last30days skill. Polling loops in
provider clients handle multi-minute waits; this module handles individual
request/response cycles. SSE streaming support added for Gemini Interactions API
with thinking summaries (DEC-TIMEOUT-005). Uses urllib to parse SSE line protocol
(data:, event:, id: fields, blank line delimiters). Retries connection failures
with exponential backoff, but does not retry during streaming (fail fast on zombie
connections).

Supports retry with exponential backoff for transient failures and rate limits.
"""

import json
import os
import random
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Dict, Generator, List, Optional

DEFAULT_TIMEOUT = 60
DEBUG = os.environ.get("DEEP_RESEARCH_DEBUG", "").lower() in ("1", "true", "yes")


def log(msg: str):
    """Log debug message to stderr."""
    if DEBUG:
        sys.stderr.write(f"[DEBUG] {msg}\n")
        sys.stderr.flush()


MAX_RETRIES = 3
RETRY_BASE_DELAY = 2.0
RETRY_429_BASE_DELAY = 5.0
RETRY_MAX_DELAY = 60.0
USER_AGENT = "deep-research-skill/1.0 (Claude Code Skill)"


class HTTPError(Exception):
    """HTTP request error with status code."""
    def __init__(self, message: str, status_code: Optional[int] = None,
                 body: Optional[str] = None, retry_after: Optional[float] = None):
        super().__init__(message)
        self.status_code = status_code
        self.body = body
        self.retry_after = retry_after


def _get_retry_delay(attempt: int, is_rate_limit: bool = False,
                     retry_after: Optional[float] = None) -> float:
    """Calculate retry delay with exponential backoff and jitter."""
    if retry_after is not None:
        return min(retry_after, RETRY_MAX_DELAY)

    base = RETRY_429_BASE_DELAY if is_rate_limit else RETRY_BASE_DELAY
    delay = base * (2 ** attempt)
    delay = min(delay, RETRY_MAX_DELAY)
    jitter = delay * 0.25 * random.random()
    return delay + jitter


def request(
    method: str,
    url: str,
    headers: Optional[Dict[str, str]] = None,
    json_data: Optional[Dict[str, Any]] = None,
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = MAX_RETRIES,
) -> Dict[str, Any]:
    """Make an HTTP request and return JSON response.

    Args:
        method: HTTP method (GET, POST, etc.)
        url: Request URL
        headers: Optional headers dict
        json_data: Optional JSON body (for POST)
        timeout: Request timeout in seconds
        retries: Number of retries on failure

    Returns:
        Parsed JSON response

    Raises:
        HTTPError: On request failure
    """
    headers = headers or {}
    headers.setdefault("User-Agent", USER_AGENT)

    data = None
    if json_data is not None:
        data = json.dumps(json_data).encode('utf-8')
        headers.setdefault("Content-Type", "application/json")

    req = urllib.request.Request(url, data=data, headers=headers, method=method)

    log(f"{method} {url}")
    if json_data:
        log(f"Payload keys: {list(json_data.keys())}")

    last_error = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                body = response.read().decode('utf-8')
                log(f"Response: {response.status} ({len(body)} bytes)")
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as e:
            body = None
            try:
                body = e.read().decode('utf-8')
            except Exception:
                pass
            log(f"HTTP Error {e.code}: {e.reason}")
            if body:
                log(f"Error body: {body[:500]}")

            retry_after = None
            retry_after_raw = e.headers.get("Retry-After") if e.headers else None
            if retry_after_raw:
                try:
                    retry_after = float(retry_after_raw)
                except (ValueError, TypeError):
                    pass

            last_error = HTTPError(f"HTTP {e.code}: {e.reason}", e.code, body, retry_after)

            if 400 <= e.code < 500 and e.code != 429:
                raise last_error

            if attempt < retries - 1:
                is_rate_limit = (e.code == 429)
                delay = _get_retry_delay(attempt, is_rate_limit, retry_after)
                log(f"Retrying in {delay:.1f}s (attempt {attempt + 1}/{retries})")
                time.sleep(delay)
        except urllib.error.URLError as e:
            log(f"URL Error: {e.reason}")
            last_error = HTTPError(f"URL Error: {e.reason}")
            if attempt < retries - 1:
                delay = _get_retry_delay(attempt)
                log(f"Retrying in {delay:.1f}s (attempt {attempt + 1}/{retries})")
                time.sleep(delay)
        except json.JSONDecodeError as e:
            log(f"JSON decode error: {e}")
            last_error = HTTPError(f"Invalid JSON response: {e}")
            raise last_error
        except (OSError, TimeoutError, ConnectionResetError) as e:
            log(f"Connection error: {type(e).__name__}: {e}")
            last_error = HTTPError(f"Connection error: {type(e).__name__}: {e}")
            if attempt < retries - 1:
                delay = _get_retry_delay(attempt)
                log(f"Retrying in {delay:.1f}s (attempt {attempt + 1}/{retries})")
                time.sleep(delay)

    if last_error:
        raise last_error
    raise HTTPError("Request failed with no error details")


def get(url: str, headers: Optional[Dict[str, str]] = None, **kwargs) -> Dict[str, Any]:
    """Make a GET request."""
    return request("GET", url, headers=headers, **kwargs)


def post(url: str, json_data: Dict[str, Any], headers: Optional[Dict[str, str]] = None, **kwargs) -> Dict[str, Any]:
    """Make a POST request with JSON body."""
    return request("POST", url, headers=headers, json_data=json_data, **kwargs)


def _parse_sse_lines(lines: List[str]) -> List[Dict[str, str]]:
    """Parse SSE-formatted lines into event dictionaries.

    SSE protocol: lines starting with 'data:' contain payload,
    'event:' is the event type, 'id:' is the event ID.
    Blank lines delimit events. Comment lines (starting with ':') are ignored.
    Multi-line data fields are concatenated with newlines.

    Args:
        lines: List of SSE-formatted lines (with or without trailing newlines)

    Returns:
        List of event dicts with keys 'event', 'data', 'id' (all strings, may be empty)
    """
    events = []
    current_event: Dict[str, str] = {"event": "", "data": "", "id": ""}
    data_parts: List[str] = []

    for line in lines:
        line = line.rstrip('\r\n')

        # Comment line - skip
        if line.startswith(':'):
            continue

        # Blank line - event delimiter
        if not line:
            # Flush accumulated data
            if data_parts:
                current_event["data"] = '\n'.join(data_parts)
                data_parts = []

            # Emit event if it has any content
            if current_event["event"] or current_event["data"] or current_event["id"]:
                events.append(current_event)
                current_event = {"event": "", "data": "", "id": ""}
            continue

        # Parse field
        if ':' in line:
            field, _, value = line.partition(':')
            # SSE spec: remove single leading space after colon (if present)
            if value.startswith(' '):
                value = value[1:]

            if field == "event":
                current_event["event"] = value
            elif field == "data":
                data_parts.append(value)
            elif field == "id":
                current_event["id"] = value

    # Flush final event if present (no trailing blank line)
    if data_parts:
        current_event["data"] = '\n'.join(data_parts)
    if current_event["event"] or current_event["data"] or current_event["id"]:
        events.append(current_event)

    return events


def stream_sse(
    url: str,
    headers: Optional[Dict[str, str]] = None,
    timeout: int = 30,
) -> Generator[Dict[str, str], None, None]:
    """Open an SSE connection and yield parsed events.

    SSE protocol: lines starting with 'data:' contain payload,
    'event:' is the event type, 'id:' is the event ID.
    Blank lines delimit events.

    Args:
        url: SSE endpoint URL
        headers: Optional headers dict
        timeout: Socket timeout in seconds for readline operations

    Yields:
        Dict with keys 'event', 'data', 'id' (all strings, may be empty)

    Raises:
        HTTPError: On connection failure or HTTP error
    """
    headers = headers or {}
    headers.setdefault("User-Agent", USER_AGENT)
    headers.setdefault("Accept", "text/event-stream")
    headers.setdefault("Cache-Control", "no-cache")

    req = urllib.request.Request(url, headers=headers, method="GET")

    log(f"Opening SSE stream: {url}")

    # Retry initial connection only (not during streaming)
    last_error = None
    for attempt in range(MAX_RETRIES):
        try:
            response = urllib.request.urlopen(req, timeout=timeout)
            log("SSE connection established")
            break
        except urllib.error.HTTPError as e:
            body = None
            try:
                body = e.read().decode('utf-8')
            except Exception:
                pass
            log(f"HTTP Error {e.code}: {e.reason}")
            if body:
                log(f"Error body: {body[:500]}")

            retry_after = None
            retry_after_raw = e.headers.get("Retry-After") if e.headers else None
            if retry_after_raw:
                try:
                    retry_after = float(retry_after_raw)
                except (ValueError, TypeError):
                    pass

            last_error = HTTPError(f"HTTP {e.code}: {e.reason}", e.code, body, retry_after)

            # Don't retry 4xx errors (except 429)
            if 400 <= e.code < 500 and e.code != 429:
                raise last_error

            if attempt < MAX_RETRIES - 1:
                is_rate_limit = (e.code == 429)
                delay = _get_retry_delay(attempt, is_rate_limit, retry_after)
                log(f"Retrying in {delay:.1f}s (attempt {attempt + 1}/{MAX_RETRIES})")
                time.sleep(delay)
        except (urllib.error.URLError, OSError, TimeoutError, ConnectionResetError) as e:
            log(f"Connection error: {type(e).__name__}: {e}")
            last_error = HTTPError(f"Connection error: {type(e).__name__}: {e}")
            if attempt < MAX_RETRIES - 1:
                delay = _get_retry_delay(attempt)
                log(f"Retrying in {delay:.1f}s (attempt {attempt + 1}/{MAX_RETRIES})")
                time.sleep(delay)
    else:
        # Exhausted retries
        if last_error:
            raise last_error
        raise HTTPError("SSE connection failed with no error details")

    # Stream events line by line
    try:
        buffer: List[str] = []
        while True:
            try:
                line_bytes = response.readline()
                if not line_bytes:
                    # EOF - flush final event if present
                    if buffer:
                        events = _parse_sse_lines(buffer)
                        for event in events:
                            yield event
                    break

                line = line_bytes.decode('utf-8')
                buffer.append(line)

                # Check if we hit an event delimiter (blank line)
                if line.rstrip('\r\n') == '':
                    events = _parse_sse_lines(buffer)
                    for event in events:
                        yield event
                    buffer = []
            except (TimeoutError, OSError) as e:
                # Socket timeout or connection error during streaming
                raise HTTPError(f"SSE stream error: {type(e).__name__}: {e}")
    finally:
        response.close()

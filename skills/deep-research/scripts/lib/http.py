"""HTTP utilities for deep-research skill (stdlib only).

@decision Stdlib-only HTTP with longer default timeout (60s) — deep research APIs
need extended timeouts for polling and synchronous long-running requests. Adapted
from last30days skill. Polling loops in provider clients handle the multi-minute
waits; this module handles individual request/response cycles.

Supports retry with exponential backoff for transient failures and rate limits.
"""

import json
import os
import random
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Dict, Optional

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

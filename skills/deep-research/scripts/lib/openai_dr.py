"""OpenAI deep research provider client.

@decision Adaptive poll intervals with time-based timeout — o3-deep-research runs as
a background task that can take up to 30 minutes. We POST with background=true, then
poll GET /v1/responses/{id} with adaptive intervals: 5s for first 2 min, 15s for
2-10 min, 30s for 10+ min. Hard timeout at 1800s (30 minutes). Adaptive intervals
reduce API load while maintaining responsiveness. Fallback model o4-mini-deep-research
used if primary model returns 404.

Uses the Responses API (not Chat Completions) as required by deep research models.
"""

import sys
import time
from typing import Any, Dict, List, Optional, Tuple

from . import http
from .errors import ProviderError, ProviderTimeoutError, ProviderRateLimitError, ProviderAPIError

BASE_URL = "https://api.openai.com/v1"
PRIMARY_MODEL = "o3-deep-research-2025-06-26"
FALLBACK_MODEL = "o4-mini-deep-research-2025-06-26"
MAX_POLL_SECONDS = 1800  # 30 minute hard ceiling


def _get_poll_interval(elapsed: float) -> int:
    """Return adaptive poll interval based on elapsed time.

    Args:
        elapsed: Seconds elapsed since polling started.

    Returns:
        Poll interval in seconds: 5s (0-120s), 15s (120-600s), 30s (600s+)
    """
    if elapsed < 120:
        return 5
    elif elapsed < 600:
        return 15
    else:
        return 30


def _headers(api_key: str) -> Dict[str, str]:
    return {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }


def _submit_request(api_key: str, topic: str, model: str) -> Dict[str, Any]:
    """Submit a deep research request in background mode.

    Returns:
        Response dict with 'id' and 'status' fields.
    """
    payload = {
        "model": model,
        "input": topic,
        "reasoning": {"summary": "auto"},
        "background": True,
        "tools": [{"type": "web_search_preview"}],
    }
    return http.post(
        f"{BASE_URL}/responses",
        json_data=payload,
        headers=_headers(api_key),
        timeout=60,
    )


def _poll_response(api_key: str, response_id: str) -> Dict[str, Any]:
    """Poll for a completed response.

    Returns:
        Completed response dict.

    Raises:
        http.HTTPError: If polling fails or times out.
    """
    start_time = time.time()
    poll_count = 0

    while True:
        elapsed = time.time() - start_time

        # Check hard timeout ceiling
        if elapsed >= MAX_POLL_SECONDS:
            raise ProviderTimeoutError("openai", MAX_POLL_SECONDS, elapsed)

        poll_count += 1
        resp = http.get(
            f"{BASE_URL}/responses/{response_id}",
            headers=_headers(api_key),
            timeout=30,
        )
        status = resp.get("status", "")
        http.log(f"OpenAI poll {poll_count}: status={status}")

        if status == "completed":
            return resp
        elif status == "failed":
            error = resp.get("error", {})
            msg = error.get("message", "Unknown error") if isinstance(error, dict) else str(error)
            raise ProviderAPIError("openai", 0, msg, elapsed)
        elif status == "incomplete":
            raise ProviderAPIError("openai", 0, "returned incomplete (may have hit output limit)", elapsed)
        elif status == "cancelled":
            raise ProviderAPIError("openai", 0, "was cancelled", elapsed)
        elif status in ("queued", "in_progress", "searching"):
            minutes = int(elapsed) // 60
            seconds = int(elapsed) % 60
            sys.stderr.write(f"  [OpenAI] Status: {status} ({minutes}m {seconds}s, poll {poll_count})\n")
            sys.stderr.flush()
            interval = _get_poll_interval(elapsed)
            time.sleep(interval)
        else:
            # Unknown status, keep polling
            minutes = int(elapsed) // 60
            seconds = int(elapsed) % 60
            sys.stderr.write(f"  [OpenAI] Unknown status: {status} ({minutes}m {seconds}s, poll {poll_count})\n")
            sys.stderr.flush()
            interval = _get_poll_interval(elapsed)
            time.sleep(interval)


def _extract_report(response: Dict[str, Any]) -> Tuple[str, List[Any]]:
    """Extract report text and citations from a completed response.

    Returns:
        Tuple of (report_text, citations_list)
    """
    report = ""
    citations = []

    output = response.get("output", [])
    for item in output:
        if item.get("type") == "message":
            content = item.get("content", [])
            for block in content:
                if block.get("type") == "output_text":
                    report = block.get("text", "")
                    annotations = block.get("annotations", [])
                    for ann in annotations:
                        if ann.get("type") == "url_citation":
                            citations.append({
                                "url": ann.get("url", ""),
                                "title": ann.get("title", ""),
                            })

    return report, citations


def research(api_key: str, topic: str) -> Tuple[str, List[Any], str]:
    """Run OpenAI deep research on a topic.

    Args:
        api_key: OpenAI API key
        topic: Research topic/question

    Returns:
        Tuple of (report_text, citations, model_used)

    Raises:
        http.HTTPError: On API failure
    """
    model = PRIMARY_MODEL

    try:
        resp = _submit_request(api_key, topic, model)
    except http.HTTPError as e:
        if e.status_code == 404:
            # Primary model not available, try fallback
            http.log(f"Primary model {model} not found, trying fallback")
            model = FALLBACK_MODEL
            resp = _submit_request(api_key, topic, model)
        else:
            raise

    response_id = resp.get("id")
    status = resp.get("status", "")

    if not response_id:
        raise ProviderAPIError("openai", 0, "No response ID returned")

    # If already completed (unlikely for deep research), extract directly
    if status == "completed":
        report, citations = _extract_report(resp)
        return report, citations, model

    # Poll for completion
    completed = _poll_response(api_key, response_id)
    report, citations = _extract_report(completed)
    return report, citations, model

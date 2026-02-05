"""OpenAI deep research provider client.

@decision Background mode with polling for OpenAI Responses API — o3-deep-research
runs as a background task that can take 2-10 minutes. We POST with background=true,
then poll GET /v1/responses/{id} every 10s until status is 'completed' or 'failed'.
Fallback model o4-mini-deep-research used if primary model returns 404.

Uses the Responses API (not Chat Completions) as required by deep research models.
"""

import sys
import time
from typing import Any, Dict, List, Optional, Tuple

from . import http

BASE_URL = "https://api.openai.com/v1"
PRIMARY_MODEL = "o3-deep-research-2025-06-26"
FALLBACK_MODEL = "o4-mini-deep-research-2025-06-26"
POLL_INTERVAL = 10  # seconds
MAX_POLL_ATTEMPTS = 60  # 10 minutes max


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
    for attempt in range(MAX_POLL_ATTEMPTS):
        resp = http.get(
            f"{BASE_URL}/responses/{response_id}",
            headers=_headers(api_key),
            timeout=30,
        )
        status = resp.get("status", "")
        http.log(f"OpenAI poll {attempt + 1}: status={status}")

        if status == "completed":
            return resp
        elif status == "failed":
            error = resp.get("error", {})
            msg = error.get("message", "Unknown error") if isinstance(error, dict) else str(error)
            raise http.HTTPError(f"OpenAI deep research failed: {msg}")
        elif status in ("queued", "in_progress", "searching"):
            sys.stderr.write(f"  [OpenAI] Status: {status} (poll {attempt + 1})\n")
            sys.stderr.flush()
            time.sleep(POLL_INTERVAL)
        else:
            # Unknown status, keep polling
            sys.stderr.write(f"  [OpenAI] Unknown status: {status} (poll {attempt + 1})\n")
            sys.stderr.flush()
            time.sleep(POLL_INTERVAL)

    raise http.HTTPError(f"OpenAI deep research timed out after {MAX_POLL_ATTEMPTS * POLL_INTERVAL}s")


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
        raise http.HTTPError("No response ID returned from OpenAI")

    # If already completed (unlikely for deep research), extract directly
    if status == "completed":
        report, citations = _extract_report(resp)
        return report, citations, model

    # Poll for completion
    completed = _poll_response(api_key, response_id)
    report, citations = _extract_report(completed)
    return report, citations, model

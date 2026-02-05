"""Gemini deep research provider client.

@decision Background mode with polling for Gemini Interactions API — deep research
runs as a background interaction that can take 2-10 minutes. We POST with
background=true, then poll GET /v1beta/interactions/{id} every 15s. The Interactions
API is a separate endpoint from the standard Gemini generateContent API.

Uses the v1beta Interactions API with API key auth (not OAuth).
"""

import sys
import time
from typing import Any, Dict, List, Tuple

from . import http

BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
AGENT = "deep-research-pro-preview-12-2025"
POLL_INTERVAL = 15  # seconds
MAX_POLL_ATTEMPTS = 40  # 10 minutes max


def _submit_request(api_key: str, topic: str) -> Dict[str, Any]:
    """Submit a deep research interaction in background mode.

    Returns:
        Response dict with interaction ID.
    """
    payload = {
        "input": topic,
        "agent": AGENT,
        "background": True,
    }
    headers = {
        "Content-Type": "application/json",
        "x-goog-api-key": api_key,
    }
    return http.post(
        f"{BASE_URL}/interactions",
        json_data=payload,
        headers=headers,
        timeout=60,
    )


def _poll_response(api_key: str, interaction_id: str) -> Dict[str, Any]:
    """Poll for a completed interaction.

    Returns:
        Completed interaction response dict.

    Raises:
        http.HTTPError: If polling fails or times out.
    """
    headers = {"x-goog-api-key": api_key}

    for attempt in range(MAX_POLL_ATTEMPTS):
        resp = http.get(
            f"{BASE_URL}/interactions/{interaction_id}",
            headers=headers,
            timeout=30,
        )
        status = resp.get("status", resp.get("metadata", {}).get("status", ""))
        http.log(f"Gemini poll {attempt + 1}: status={status}")

        if status in ("completed", "COMPLETED"):
            return resp
        elif status in ("failed", "FAILED"):
            error = resp.get("error", {})
            msg = error.get("message", "Unknown error") if isinstance(error, dict) else str(error)
            raise http.HTTPError(f"Gemini deep research failed: {msg}")
        else:
            sys.stderr.write(f"  [Gemini] Status: {status} (poll {attempt + 1})\n")
            sys.stderr.flush()
            time.sleep(POLL_INTERVAL)

    raise http.HTTPError(f"Gemini deep research timed out after {MAX_POLL_ATTEMPTS * POLL_INTERVAL}s")


def _extract_report(response: Dict[str, Any]) -> Tuple[str, List[Any]]:
    """Extract report text and citations from a completed interaction.

    Returns:
        Tuple of (report_text, citations_list)
    """
    report = ""
    citations = []

    # Try multiple response shapes the API may return
    outputs = response.get("outputs", [])
    if outputs:
        # Take the last output (final report)
        last_output = outputs[-1]
        if isinstance(last_output, dict):
            report = last_output.get("text", last_output.get("content", ""))
        elif isinstance(last_output, str):
            report = last_output

    # Fallback: check result field
    if not report:
        result = response.get("result", {})
        if isinstance(result, dict):
            report = result.get("text", result.get("content", ""))

    # Extract citations/sources if present
    sources = response.get("sources", response.get("groundingMetadata", {}).get("webSearchQueries", []))
    if isinstance(sources, list):
        for src in sources:
            if isinstance(src, str):
                citations.append({"url": src})
            elif isinstance(src, dict):
                citations.append({
                    "url": src.get("url", src.get("uri", "")),
                    "title": src.get("title", ""),
                })

    return report, citations


def research(api_key: str, topic: str) -> Tuple[str, List[Any], str]:
    """Run Gemini deep research on a topic.

    Args:
        api_key: Gemini API key
        topic: Research topic/question

    Returns:
        Tuple of (report_text, citations, model_used)

    Raises:
        http.HTTPError: On API failure
    """
    resp = _submit_request(api_key, topic)

    # Extract interaction ID — may be in 'name', 'id', or 'interactionId'
    interaction_id = resp.get("name", resp.get("id", resp.get("interactionId", "")))

    if not interaction_id:
        raise http.HTTPError("No interaction ID returned from Gemini")

    # Check if already completed
    status = resp.get("status", resp.get("metadata", {}).get("status", ""))
    if status in ("completed", "COMPLETED"):
        report, citations = _extract_report(resp)
        return report, citations, AGENT

    # Poll for completion
    completed = _poll_response(api_key, interaction_id)
    report, citations = _extract_report(completed)
    return report, citations, AGENT

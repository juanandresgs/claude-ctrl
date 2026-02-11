"""Gemini deep research provider client.

@decision DEC-TIMEOUT-002, DEC-TIMEOUT-006
@title Gemini Interactions API with SSE streaming and thinking summaries
@status accepted
@rationale Deep research runs as a background interaction that can take up to 30
minutes. We POST with background=true only to create the interaction (DEC-TIMEOUT-002).
Primary mode: SSE streaming via GET /v1beta/interactions/{id}?alt=sse to receive
real-time thinking summaries and content deltas (DEC-TIMEOUT-006). The SSE stream
provides agent_config behavior automatically. Fallback mode: polling GET
/v1beta/interactions/{id} every 5-30s (adaptive) up to 1800s total. Zombie detection:
if no SSE events arrive for 300s, raise "appears stuck" error. The Interactions API
is a separate endpoint from the standard Gemini generateContent API. Uses v1beta API
with API key auth (not OAuth).
"""

import json
import sys
import time
from typing import Any, Dict, List, Tuple

from . import http

BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
AGENT = "deep-research-pro-preview-12-2025"
MAX_TIMEOUT_SECONDS = 1800  # 30 minutes total timeout
ZOMBIE_THRESHOLD = 300  # 5 minutes without events = stuck


def _submit_request(api_key: str, topic: str) -> Dict[str, Any]:
    """Submit a deep research interaction in background mode.

    Creates an interaction that runs in the background. The POST returns JSON
    with an interaction ID. Streaming is retrieved separately via GET with ?alt=sse.

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


def _get_poll_interval(elapsed: float) -> float:
    """Calculate adaptive poll interval based on elapsed time.

    Args:
        elapsed: Seconds elapsed since start

    Returns:
        Poll interval in seconds (5s, 15s, or 30s)
    """
    if elapsed < 120:  # First 2 minutes
        return 5.0
    elif elapsed < 600:  # Next 8 minutes (2-10 min)
        return 15.0
    else:  # After 10 minutes
        return 30.0


def _poll_response_fallback(api_key: str, interaction_id: str) -> Dict[str, Any]:
    """Poll for a completed interaction (fallback when streaming unavailable).

    Uses adaptive polling: 5s for first 2 min, 15s for next 8 min, 30s after that.
    Total timeout: 1800s (30 minutes).

    Returns:
        Completed interaction response dict.

    Raises:
        http.HTTPError: If polling fails or times out.
    """
    headers = {"x-goog-api-key": api_key}
    start_time = time.time()
    poll_count = 0

    while True:
        elapsed = time.time() - start_time

        if elapsed >= MAX_TIMEOUT_SECONDS:
            raise http.HTTPError(
                f"Gemini deep research timed out after {int(elapsed)}s"
            )

        resp = http.get(
            f"{BASE_URL}/interactions/{interaction_id}",
            headers=headers,
            timeout=30,
        )
        status = resp.get("status", resp.get("metadata", {}).get("status", ""))
        poll_count += 1
        http.log(f"Gemini poll {poll_count}: status={status} (elapsed={int(elapsed)}s)")

        if status in ("completed", "COMPLETED"):
            return resp
        elif status in ("failed", "FAILED"):
            error = resp.get("error", {})
            msg = error.get("message", "Unknown error") if isinstance(error, dict) else str(error)
            raise http.HTTPError(f"Gemini deep research failed: {msg}")
        elif status in ("cancelled", "CANCELLED"):
            raise http.HTTPError("Gemini deep research was cancelled")
        else:
            minutes = int(elapsed) // 60
            seconds = int(elapsed) % 60
            sys.stderr.write(f"  [Gemini] Status: {status} ({minutes}m {seconds:02d}s, poll {poll_count})\n")
            sys.stderr.flush()

            interval = _get_poll_interval(elapsed)
            time.sleep(interval)


def _format_thinking_line(elapsed: float, summary_text: str) -> str:
    """Format a thinking summary line for stderr output.

    Args:
        elapsed: Seconds elapsed since start
        summary_text: The thinking summary text (will be truncated to ~80 chars)

    Returns:
        Formatted line like "  [Gemini] 2m 30s - Searching: \"topic\""
    """
    minutes = int(elapsed) // 60
    seconds = int(elapsed) % 60

    # Truncate summary to ~80 chars
    max_len = 80
    if len(summary_text) > max_len:
        summary_text = summary_text[:max_len - 3] + "..."

    return f"  [Gemini] {minutes}m {seconds:02d}s - {summary_text}"


def _stream_response(api_key: str, interaction_id: str) -> str:
    """Stream a Gemini interaction via SSE and return the final report.

    Processes SSE events:
    - interaction.start: log start
    - content.delta with thought_summary: display on stderr
    - content.delta with text: accumulate into report
    - interaction.complete: return accumulated report
    - error: raise HTTPError

    Zombie detection: if no events arrive for 300s, raise "appears stuck" error.
    Overall timeout: 1800s total.

    Args:
        api_key: Gemini API key
        interaction_id: Interaction ID from _submit_request

    Returns:
        Complete report text

    Raises:
        http.HTTPError: On API error, timeout, or zombie detection
    """
    url = f"{BASE_URL}/interactions/{interaction_id}?alt=sse"
    headers = {
        "x-goog-api-key": api_key,
        "Accept": "text/event-stream",
    }

    start_time = time.time()
    last_event_time = start_time
    report_parts: List[str] = []

    try:
        for event in http.stream_sse(url, headers=headers, timeout=MAX_TIMEOUT_SECONDS):
            last_event_time = time.time()
            elapsed = last_event_time - start_time

            # Overall timeout check
            if elapsed >= MAX_TIMEOUT_SECONDS:
                raise http.HTTPError(
                    f"Gemini deep research timed out after {int(elapsed)}s"
                )

            event_type = event.get("event", "")
            data_str = event.get("data", "")

            # Parse JSON data if present
            data: Dict[str, Any] = {}
            if data_str:
                try:
                    data = json.loads(data_str)
                except json.JSONDecodeError:
                    http.log(f"Failed to parse event data as JSON: {data_str[:100]}")
                    continue

            http.log(f"SSE event: {event_type} (elapsed={int(elapsed)}s)")

            # Handle different event types
            if event_type == "interaction.start":
                sys.stderr.write(f"  [Gemini] 0m 00s - Starting research...\n")
                sys.stderr.flush()

            elif event_type == "content.delta":
                content_type = data.get("type", "")

                if content_type == "thought_summary":
                    # Display thinking summary on stderr
                    summary_text = data.get("text", "")
                    if summary_text:
                        line = _format_thinking_line(elapsed, summary_text)
                        sys.stderr.write(line + "\n")
                        sys.stderr.flush()

                elif content_type == "text":
                    # Accumulate report text
                    text = data.get("text", "")
                    if text:
                        report_parts.append(text)

            elif event_type in ("interaction.complete", "interaction.completed"):
                minutes = int(elapsed) // 60
                seconds = int(elapsed) % 60
                sys.stderr.write(f"  [Gemini] {minutes}m {seconds:02d}s - Complete\n")
                sys.stderr.flush()
                return ''.join(report_parts)

            elif event_type == "error":
                error_msg = data.get("message", "Unknown error")
                raise http.HTTPError(f"Gemini deep research failed: {error_msg}")

            # Zombie detection: check if we've been silent too long
            silence_duration = time.time() - last_event_time
            if silence_duration > ZOMBIE_THRESHOLD:
                raise http.HTTPError(
                    f"Gemini task appears stuck (no events for {int(silence_duration)}s)"
                )

    except http.HTTPError:
        # Re-raise HTTP errors as-is
        raise
    except Exception as e:
        # Wrap other exceptions
        raise http.HTTPError(f"SSE stream error: {type(e).__name__}: {e}")

    # If we exit the loop without interaction.complete, something went wrong
    raise http.HTTPError("SSE stream ended without interaction.complete event")


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

    # Extract citations from structured sources if present
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

    # Fallback: extract inline URLs from report text (Gemini embeds grounding
    # redirect URLs directly in the markdown)
    if not citations and report:
        import re
        urls = re.findall(r'https?://[^\s\)>\]]+', report)
        seen = set()
        for url in urls:
            if url not in seen:
                seen.add(url)
                citations.append({"url": url})

    return report, citations


def research(api_key: str, topic: str) -> Tuple[str, List[Any], str]:
    """Run Gemini deep research on a topic.

    Primary mode: SSE streaming with thinking summaries.
    Fallback mode: polling (if SSE connection fails).

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

    # Check if already completed (unlikely with background=true, but handle it)
    status = resp.get("status", resp.get("metadata", {}).get("status", ""))
    if status in ("completed", "COMPLETED"):
        report, citations = _extract_report(resp)
        return report, citations, AGENT

    # Try SSE streaming first
    report = None
    try:
        report = _stream_response(api_key, interaction_id)
    except http.HTTPError as e:
        # If it's a connection error (not an API error), fall back to polling
        if e.status_code is None or e.status_code >= 500:
            sys.stderr.write(f"  [Gemini] SSE streaming unavailable, falling back to polling\n")
            sys.stderr.flush()
            http.log(f"SSE error: {e}, falling back to polling")
            # Fall through to polling
        else:
            # API error (4xx) - re-raise
            raise

    # If streaming succeeded, extract citations
    if report:
        # SSE stream returns report text directly; citations come from final GET
        # We need to fetch the final state to get citations
        try:
            completed = http.get(
                f"{BASE_URL}/interactions/{interaction_id}",
                headers={"x-goog-api-key": api_key},
                timeout=30,
            )
            _, citations = _extract_report(completed)
            return report, citations, AGENT
        except Exception:
            # If citation fetch fails, return report with empty citations
            http.log("Failed to fetch citations from completed interaction")
            return report, [], AGENT

    # Fallback: poll for completion
    completed = _poll_response_fallback(api_key, interaction_id)
    report, citations = _extract_report(completed)
    return report, citations, AGENT

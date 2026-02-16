"""Perplexity deep research provider client.

@decision Synchronous long-timeout request for Perplexity — sonar-deep-research
is a synchronous API (no background/polling). It can take 60-300s to respond.
We use a 300s timeout and extract inline citations from the response content.
Rate limit is 5-10 req/min so no special handling needed for single requests.

Uses the standard Chat Completions API format.
"""

from typing import Any, Dict, List, Tuple

from . import http
from .errors import ProviderError, ProviderTimeoutError, ProviderRateLimitError, ProviderAPIError

BASE_URL = "https://api.perplexity.ai"
MODEL = "sonar-deep-research"
REQUEST_TIMEOUT = 300  # seconds — deep research can take several minutes


def _headers(api_key: str) -> Dict[str, str]:
    return {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }


def research(api_key: str, topic: str) -> Tuple[str, List[Any], str]:
    """Run Perplexity deep research on a topic.

    Args:
        api_key: Perplexity API key
        topic: Research topic/question

    Returns:
        Tuple of (report_text, citations, model_used)

    Raises:
        http.HTTPError: On API failure
    """
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": topic}],
    }

    resp = http.post(
        f"{BASE_URL}/chat/completions",
        json_data=payload,
        headers=_headers(api_key),
        timeout=REQUEST_TIMEOUT,
    )

    report = ""
    citations = []

    # Extract report from chat completion response
    choices = resp.get("choices", [])
    if choices:
        message = choices[0].get("message", {})
        report = message.get("content", "")

    # Extract citations if present (Perplexity includes them in response)
    raw_citations = resp.get("citations", [])
    for url in raw_citations:
        if isinstance(url, str):
            citations.append({"url": url})
        elif isinstance(url, dict):
            citations.append(url)

    model_used = resp.get("model", MODEL)
    return report, citations, model_used

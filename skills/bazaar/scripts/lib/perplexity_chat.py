"""Perplexity Chat Completions API wrapper for bazaar skill (stdlib only).

@decision DEC-BAZAAR-004
@title bazaar_dispatch.py for non-tool phases; thin provider wrappers per model
@status accepted
@rationale Perplexity uses the OpenAI Chat Completions format but adds a "citations"
array in the response. The wrapper extracts both text and citations, returning
citations as part of the text output (appended as a JSON block) so obsessive
archetypes can reference sources. No json_object mode — Perplexity's sonar
models return natural language with embedded citations.

Thin wrapper around the Perplexity Chat Completions API. Used by bazaar_dispatch.py
for search-obsessive archetype phases (live web research with citations).

API reference: https://docs.perplexity.ai/api-reference/chat-completions
Response shape: {"choices": [{"message": {"content": "..."}}], "citations": [...], "model": "..."}
"""

import json
import time
from typing import Dict, List, Tuple

from . import http
from .errors import ProviderError, ProviderTimeoutError, ProviderRateLimitError, ProviderAPIError

BASE_URL = "https://api.perplexity.ai/chat/completions"
DEFAULT_TIMEOUT = 120  # seconds


def _headers(api_key: str) -> Dict[str, str]:
    return {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }


def chat(
    api_key: str,
    system_prompt: str,
    user_prompt: str,
    model: str = "sonar-deep-research",
    max_tokens: int = 4096,
    timeout: float = DEFAULT_TIMEOUT,
) -> Tuple[str, str]:
    """Send a chat request to the Perplexity API with live web search.

    Returns the response text with citations appended as a JSON block so
    downstream obsessive archetype processing can extract source references.

    Args:
        api_key: Perplexity API key
        system_prompt: System-level instructions for the model
        user_prompt: User message content (search query / research task)
        model: Model identifier (e.g., sonar-deep-research, sonar-pro)
        max_tokens: Maximum tokens in the response
        timeout: Request timeout in seconds

    Returns:
        Tuple of (response_text_with_citations, model_used)
        response_text contains the answer followed by a CITATIONS_JSON block

    Raises:
        ProviderAPIError: On non-retryable API failures
        ProviderTimeoutError: When request exceeds timeout
        ProviderRateLimitError: On 429 responses
    """
    t0 = time.time()
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "max_tokens": max_tokens,
    }

    try:
        resp = http.post(
            BASE_URL,
            json_data=payload,
            headers=_headers(api_key),
            timeout=timeout,
        )
    except http.HTTPError as e:
        elapsed = time.time() - t0
        if e.status_code == 429:
            raise ProviderRateLimitError("perplexity", e.retry_after, elapsed) from e
        if e.status_code and e.status_code >= 500:
            raise ProviderAPIError("perplexity", e.status_code, str(e.body or ""), elapsed) from e
        raise ProviderAPIError("perplexity", e.status_code or 0, str(e), elapsed) from e
    except TimeoutError as e:
        elapsed = time.time() - t0
        raise ProviderTimeoutError("perplexity", timeout, elapsed) from e

    choices = resp.get("choices", [])
    if not choices:
        raise ProviderError("perplexity", "empty choices array in response")

    text = choices[0].get("message", {}).get("content", "")

    # Append citations as a structured block for downstream extraction
    citations: List[str] = resp.get("citations", [])
    if citations:
        citations_block = json.dumps({"citations": citations}, indent=2)
        text = f"{text}\n\nCITATIONS_JSON:\n{citations_block}"

    model_used = resp.get("model", model)
    return text, model_used

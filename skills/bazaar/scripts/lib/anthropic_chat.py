"""Anthropic Messages API wrapper for bazaar skill (stdlib only).

@decision DEC-BAZAAR-004
@title bazaar_dispatch.py for non-tool phases; thin provider wrappers per model
@status accepted
@rationale Each provider wrapper is a stateless function with identical signature:
(api_key, system_prompt, user_prompt, model, max_tokens, timeout) -> (text, model_used).
This uniformity lets bazaar_dispatch.py route to any provider without branching.
Error translation to ProviderError hierarchy isolates callers from HTTP details.

Thin wrapper around the Anthropic Messages API. Used by bazaar_dispatch.py
for ideator, judge, and analyst archetype phases.

API reference: https://docs.anthropic.com/en/api/messages
Response shape: {"content": [{"type": "text", "text": "..."}], "model": "...", "usage": {...}}
"""

import time
from typing import Dict, Tuple

from . import http
from .errors import ProviderError, ProviderTimeoutError, ProviderRateLimitError, ProviderAPIError

BASE_URL = "https://api.anthropic.com/v1/messages"
API_VERSION = "2023-06-01"
DEFAULT_TIMEOUT = 120  # seconds


def _headers(api_key: str) -> Dict[str, str]:
    return {
        "x-api-key": api_key,
        "anthropic-version": API_VERSION,
        "content-type": "application/json",
    }


def chat(
    api_key: str,
    system_prompt: str,
    user_prompt: str,
    model: str = "claude-opus-4-6",
    max_tokens: int = 4096,
    timeout: float = DEFAULT_TIMEOUT,
) -> Tuple[str, str]:
    """Send a chat request to the Anthropic Messages API.

    Args:
        api_key: Anthropic API key
        system_prompt: System-level instructions for the model
        user_prompt: User message content
        model: Model identifier (e.g., claude-opus-4-6)
        max_tokens: Maximum tokens in the response
        timeout: Request timeout in seconds

    Returns:
        Tuple of (response_text, model_used)

    Raises:
        ProviderAPIError: On non-retryable API failures
        ProviderTimeoutError: When request exceeds timeout
        ProviderRateLimitError: On 429 responses
    """
    t0 = time.time()
    payload = {
        "model": model,
        "max_tokens": max_tokens,
        "system": system_prompt,
        "messages": [{"role": "user", "content": user_prompt}],
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
            raise ProviderRateLimitError("anthropic", e.retry_after, elapsed) from e
        if e.status_code and e.status_code >= 500:
            raise ProviderAPIError("anthropic", e.status_code, str(e.body or ""), elapsed) from e
        raise ProviderAPIError("anthropic", e.status_code or 0, str(e), elapsed) from e
    except TimeoutError as e:
        elapsed = time.time() - t0
        raise ProviderTimeoutError("anthropic", timeout, elapsed) from e

    content = resp.get("content", [])
    if not content:
        raise ProviderError("anthropic", "empty content array in response")

    text = ""
    for block in content:
        if block.get("type") == "text":
            text = block.get("text", "")
            break

    model_used = resp.get("model", model)
    return text, model_used

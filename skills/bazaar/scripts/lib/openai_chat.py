"""OpenAI Chat Completions API wrapper for bazaar skill (stdlib only).

@decision DEC-BAZAAR-004
@title bazaar_dispatch.py for non-tool phases; thin provider wrappers per model
@status accepted
@rationale Uniform (api_key, system_prompt, user_prompt, model, max_tokens, timeout)
-> (text, model_used) signature matches all other bazaar provider wrappers.
json_object response_format enforces valid JSON output from ideator/judge archetypes,
avoiding parse errors downstream in aggregate.py.

Thin wrapper around the OpenAI Chat Completions API. Used by bazaar_dispatch.py
for ideator, judge, and analyst archetype phases.

API reference: https://platform.openai.com/docs/api-reference/chat
Response shape: {"choices": [{"message": {"content": "..."}}], "model": "...", "usage": {...}}
"""

import time
from typing import Dict, Tuple

from . import http
from .errors import ProviderError, ProviderTimeoutError, ProviderRateLimitError, ProviderAPIError

BASE_URL = "https://api.openai.com/v1/chat/completions"
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
    model: str = "gpt-5.2",
    max_tokens: int = 4096,
    timeout: float = DEFAULT_TIMEOUT,
) -> Tuple[str, str]:
    """Send a chat request to the OpenAI Chat Completions API.

    Uses json_object response_format when the user prompt mentions JSON,
    ensuring structured outputs for ideator and judge archetypes.

    Args:
        api_key: OpenAI API key
        system_prompt: System-level instructions for the model
        user_prompt: User message content
        model: Model identifier (e.g., gpt-5.2, gpt-4o)
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
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "response_format": {"type": "json_object"},
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
            raise ProviderRateLimitError("openai", e.retry_after, elapsed) from e
        if e.status_code and e.status_code >= 500:
            raise ProviderAPIError("openai", e.status_code, str(e.body or ""), elapsed) from e
        raise ProviderAPIError("openai", e.status_code or 0, str(e), elapsed) from e
    except TimeoutError as e:
        elapsed = time.time() - t0
        raise ProviderTimeoutError("openai", timeout, elapsed) from e

    choices = resp.get("choices", [])
    if not choices:
        raise ProviderError("openai", "empty choices array in response")

    text = choices[0].get("message", {}).get("content", "")
    model_used = resp.get("model", model)
    return text, model_used

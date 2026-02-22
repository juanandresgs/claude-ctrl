"""Google Gemini generateContent API wrapper for bazaar skill (stdlib only).

@decision DEC-BAZAAR-004
@title bazaar_dispatch.py for non-tool phases; thin provider wrappers per model
@status accepted
@rationale Gemini uses a different payload shape (system_instruction vs system message,
contents.parts vs messages). responseMimeType: application/json enforces structured
output. The wrapper normalizes this to the same (text, model_used) return shape
as all other bazaar providers, so bazaar_dispatch.py needs no provider-specific logic.

Thin wrapper around the Google Gemini generateContent API. Used by bazaar_dispatch.py
for ideator, judge, and analyst archetype phases.

API reference: https://ai.google.dev/api/generate-content
Response shape: {"candidates": [{"content": {"parts": [{"text": "..."}]}}], "modelVersion": "...", "usageMetadata": {...}}
"""

import time
from typing import Dict, Tuple

from . import http
from .errors import ProviderError, ProviderTimeoutError, ProviderRateLimitError, ProviderAPIError

BASE_URL_TEMPLATE = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
DEFAULT_TIMEOUT = 120  # seconds


def _headers(api_key: str) -> Dict[str, str]:
    return {
        "x-goog-api-key": api_key,
        "Content-Type": "application/json",
    }


def chat(
    api_key: str,
    system_prompt: str,
    user_prompt: str,
    model: str = "gemini-3.1-pro-preview",
    max_tokens: int = 4096,
    timeout: float = DEFAULT_TIMEOUT,
) -> Tuple[str, str]:
    """Send a generateContent request to the Google Gemini API.

    Uses responseMimeType: application/json to enforce structured JSON output
    for ideator and judge archetypes.

    Args:
        api_key: Google Gemini API key
        system_prompt: System-level instructions for the model
        user_prompt: User message content
        model: Model identifier (e.g., gemini-3.1-pro-preview, gemini-2.0-flash)
        max_tokens: Maximum tokens in the response (maps to maxOutputTokens)
        timeout: Request timeout in seconds

    Returns:
        Tuple of (response_text, model_used)

    Raises:
        ProviderAPIError: On non-retryable API failures
        ProviderTimeoutError: When request exceeds timeout
        ProviderRateLimitError: On 429 responses
    """
    t0 = time.time()
    url = BASE_URL_TEMPLATE.format(model=model)

    payload = {
        "system_instruction": {
            "parts": [{"text": system_prompt}]
        },
        "contents": [
            {"parts": [{"text": user_prompt}]}
        ],
        "generationConfig": {
            "responseMimeType": "application/json",
            "maxOutputTokens": max_tokens,
        },
    }

    try:
        resp = http.post(
            url,
            json_data=payload,
            headers=_headers(api_key),
            timeout=timeout,
        )
    except http.HTTPError as e:
        elapsed = time.time() - t0
        if e.status_code == 429:
            raise ProviderRateLimitError("gemini", e.retry_after, elapsed) from e
        if e.status_code and e.status_code >= 500:
            raise ProviderAPIError("gemini", e.status_code, str(e.body or ""), elapsed) from e
        raise ProviderAPIError("gemini", e.status_code or 0, str(e), elapsed) from e
    except TimeoutError as e:
        elapsed = time.time() - t0
        raise ProviderTimeoutError("gemini", timeout, elapsed) from e

    candidates = resp.get("candidates", [])
    if not candidates:
        raise ProviderError("gemini", "empty candidates array in response")

    parts = candidates[0].get("content", {}).get("parts", [])
    if not parts:
        raise ProviderError("gemini", "empty parts in first candidate")

    text = parts[0].get("text", "")
    model_used = resp.get("modelVersion", model)
    return text, model_used

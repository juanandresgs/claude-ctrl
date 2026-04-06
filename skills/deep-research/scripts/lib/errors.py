"""Structured error hierarchy for deep-research providers.

@decision Provider-specific exception types with context (elapsed time, retry hints)
rather than generic exceptions. Modeled after giga-research's error taxonomy but
kept stdlib-only. ProviderError is the base; all provider modules raise these
instead of bare HTTPError where appropriate.
"""


class ProviderError(Exception):
    """Base error for provider failures."""

    def __init__(self, provider: str, message: str, elapsed: float = 0.0):
        self.provider = provider
        self.elapsed = elapsed
        super().__init__(f"[{provider}] {message}")


class ProviderTimeoutError(ProviderError):
    """Provider exceeded its time budget."""

    def __init__(self, provider: str, timeout: float, elapsed: float = 0.0):
        self.timeout = timeout
        super().__init__(provider, f"timed out after {timeout}s", elapsed)


class ProviderRateLimitError(ProviderError):
    """Provider returned 429 or equivalent."""

    def __init__(self, provider: str, retry_after: float | None = None, elapsed: float = 0.0):
        self.retry_after = retry_after
        msg = "rate limited"
        if retry_after:
            msg += f" (retry after {retry_after}s)"
        super().__init__(provider, msg, elapsed)


class ProviderAPIError(ProviderError):
    """Provider returned a non-retryable API error."""

    def __init__(self, provider: str, status_code: int, body: str = "", elapsed: float = 0.0):
        self.status_code = status_code
        self.body = body
        super().__init__(provider, f"HTTP {status_code}: {body[:200]}", elapsed)

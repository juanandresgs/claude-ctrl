#!/usr/bin/env python3
"""Test suite for structured error hierarchy.

@decision Real unit tests without mocks — tests construct actual error objects
and verify their properties, message format, and inheritance chain. No subprocess
calls needed — pure Python object testing.
"""

import sys
import unittest
from pathlib import Path

# Add lib to path
SCRIPT_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

from lib.errors import (
    ProviderError,
    ProviderTimeoutError,
    ProviderRateLimitError,
    ProviderAPIError,
)


class TestProviderError(unittest.TestCase):
    """Test base ProviderError class."""

    def test_provider_error_stores_provider_name(self):
        """ProviderError stores provider name."""
        err = ProviderError("openai", "test error")
        self.assertEqual(err.provider, "openai")

    def test_provider_error_stores_message(self):
        """ProviderError formats message with provider prefix."""
        err = ProviderError("openai", "test error")
        self.assertEqual(str(err), "[openai] test error")

    def test_provider_error_stores_elapsed(self):
        """ProviderError stores elapsed time."""
        err = ProviderError("openai", "test error", elapsed=45.3)
        self.assertEqual(err.elapsed, 45.3)

    def test_provider_error_default_elapsed(self):
        """ProviderError defaults elapsed to 0.0."""
        err = ProviderError("openai", "test error")
        self.assertEqual(err.elapsed, 0.0)

    def test_provider_error_is_exception(self):
        """ProviderError inherits from Exception."""
        err = ProviderError("openai", "test error")
        self.assertIsInstance(err, Exception)


class TestProviderTimeoutError(unittest.TestCase):
    """Test ProviderTimeoutError class."""

    def test_timeout_error_formats_message(self):
        """ProviderTimeoutError formats message correctly."""
        err = ProviderTimeoutError("openai", 1800, elapsed=1850.5)
        self.assertIn("timed out after 1800s", str(err))
        self.assertIn("[openai]", str(err))

    def test_timeout_error_stores_timeout(self):
        """ProviderTimeoutError stores timeout value."""
        err = ProviderTimeoutError("openai", 1800)
        self.assertEqual(err.timeout, 1800)

    def test_timeout_error_is_provider_error(self):
        """ProviderTimeoutError inherits from ProviderError."""
        err = ProviderTimeoutError("openai", 1800)
        self.assertIsInstance(err, ProviderError)

    def test_timeout_error_is_exception(self):
        """ProviderTimeoutError inherits from Exception."""
        err = ProviderTimeoutError("openai", 1800)
        self.assertIsInstance(err, Exception)


class TestProviderRateLimitError(unittest.TestCase):
    """Test ProviderRateLimitError class."""

    def test_rate_limit_error_without_retry_after(self):
        """ProviderRateLimitError formats message without retry_after."""
        err = ProviderRateLimitError("perplexity")
        self.assertIn("rate limited", str(err))
        self.assertIn("[perplexity]", str(err))
        self.assertIsNone(err.retry_after)

    def test_rate_limit_error_with_retry_after(self):
        """ProviderRateLimitError formats message with retry_after."""
        err = ProviderRateLimitError("perplexity", retry_after=60.0)
        self.assertIn("rate limited", str(err))
        self.assertIn("retry after 60.0s", str(err))
        self.assertEqual(err.retry_after, 60.0)

    def test_rate_limit_error_is_provider_error(self):
        """ProviderRateLimitError inherits from ProviderError."""
        err = ProviderRateLimitError("perplexity")
        self.assertIsInstance(err, ProviderError)

    def test_rate_limit_error_is_exception(self):
        """ProviderRateLimitError inherits from Exception."""
        err = ProviderRateLimitError("perplexity")
        self.assertIsInstance(err, Exception)


class TestProviderAPIError(unittest.TestCase):
    """Test ProviderAPIError class."""

    def test_api_error_with_status_code(self):
        """ProviderAPIError formats message with status code."""
        err = ProviderAPIError("gemini", 404, "Not Found")
        self.assertIn("HTTP 404", str(err))
        self.assertIn("Not Found", str(err))
        self.assertIn("[gemini]", str(err))
        self.assertEqual(err.status_code, 404)

    def test_api_error_truncates_long_body(self):
        """ProviderAPIError truncates body to 200 chars."""
        long_body = "a" * 300
        err = ProviderAPIError("gemini", 500, long_body)
        # Should truncate to 200 chars
        self.assertLessEqual(len(str(err)), 250)  # Room for prefix

    def test_api_error_stores_body(self):
        """ProviderAPIError stores full body."""
        body = "Error details here"
        err = ProviderAPIError("gemini", 400, body)
        self.assertEqual(err.body, body)

    def test_api_error_with_empty_body(self):
        """ProviderAPIError handles empty body."""
        err = ProviderAPIError("gemini", 500, "")
        self.assertIn("HTTP 500", str(err))

    def test_api_error_is_provider_error(self):
        """ProviderAPIError inherits from ProviderError."""
        err = ProviderAPIError("gemini", 404, "Not Found")
        self.assertIsInstance(err, ProviderError)

    def test_api_error_is_exception(self):
        """ProviderAPIError inherits from Exception."""
        err = ProviderAPIError("gemini", 404, "Not Found")
        self.assertIsInstance(err, Exception)


class TestInheritanceChain(unittest.TestCase):
    """Test error inheritance chain."""

    def test_all_errors_inherit_from_provider_error(self):
        """All error types inherit from ProviderError."""
        timeout = ProviderTimeoutError("openai", 1800)
        rate_limit = ProviderRateLimitError("perplexity")
        api_error = ProviderAPIError("gemini", 404, "Not Found")

        self.assertIsInstance(timeout, ProviderError)
        self.assertIsInstance(rate_limit, ProviderError)
        self.assertIsInstance(api_error, ProviderError)

    def test_all_errors_inherit_from_exception(self):
        """All error types inherit from Exception."""
        timeout = ProviderTimeoutError("openai", 1800)
        rate_limit = ProviderRateLimitError("perplexity")
        api_error = ProviderAPIError("gemini", 404, "Not Found")

        self.assertIsInstance(timeout, Exception)
        self.assertIsInstance(rate_limit, Exception)
        self.assertIsInstance(api_error, Exception)


if __name__ == "__main__":
    unittest.main()

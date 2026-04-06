#!/usr/bin/env python3
"""test_timeout.py — Tests for --timeout flag threading into provider calls (Bug 1 fix).

Bug: --timeout is documented as a per-provider ceiling but run_provider() never
passes args.timeout into module.research(). Each provider uses its own hard-coded
constant (openai: 1800s, perplexity: 300s, gemini: 1800s) regardless of --timeout.

Fix contract: run_provider(provider, api_key, topic, timeout) passes timeout into
each provider's research(api_key, topic, timeout) call. Providers use the passed
value as their per-call ceiling.

Test strategy:
1. Unit: run_provider() passes timeout to module.research() (mock the module).
2. Unit: each provider research() accepts and applies a timeout argument.
3. Integration: a short timeout triggers ProviderTimeoutError before the hard ceiling.

@decision DEC-TIMEOUT-TEST-001
@title Test timeout threading via mock patching, not real HTTP
@status accepted
@rationale Provider functions are I/O-bound against external APIs. Tests use
unittest.mock.patch to inject controlled fakes that record call arguments,
letting us assert timeout was forwarded without any network traffic.
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Add scripts dir to path so lib is importable
SCRIPTS_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import deep_research  # noqa: E402
from lib.errors import ProviderTimeoutError  # noqa: E402

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_research_mock(report="Report text.", citations=None, model="mock-model"):
    """Return a mock that mimics a provider research() function signature."""
    mock = MagicMock(return_value=(report, citations or [], model))
    return mock


# ---------------------------------------------------------------------------
# Bug 1: run_provider must pass timeout to module.research()
# ---------------------------------------------------------------------------


class TestRunProviderPassesTimeout(unittest.TestCase):
    """run_provider() must forward the timeout argument to module.research().

    Production sequence:
      main() parses --timeout → passes to run_provider(…, timeout=N)
      run_provider calls module.research(api_key, topic, timeout=N)
      Provider uses N as its per-call ceiling instead of a hard-coded constant.
    """

    def test_run_provider_forwards_timeout_to_openai(self):
        """run_provider passes timeout to openai_dr.research()."""
        mock_research = _make_research_mock()
        with patch.object(deep_research.PROVIDER_MODULES["openai"], "research", mock_research):
            deep_research.run_provider("openai", "key", "topic", timeout=42)
        mock_research.assert_called_once()
        _, kwargs = mock_research.call_args
        self.assertEqual(
            kwargs.get("timeout"),
            42,
            "run_provider must forward timeout= to openai research()",
        )

    def test_run_provider_forwards_timeout_to_perplexity(self):
        """run_provider passes timeout to perplexity_dr.research()."""
        mock_research = _make_research_mock()
        with patch.object(deep_research.PROVIDER_MODULES["perplexity"], "research", mock_research):
            deep_research.run_provider("perplexity", "key", "topic", timeout=120)
        mock_research.assert_called_once()
        _, kwargs = mock_research.call_args
        self.assertEqual(kwargs.get("timeout"), 120)

    def test_run_provider_forwards_timeout_to_gemini(self):
        """run_provider passes timeout to gemini_dr.research()."""
        mock_research = _make_research_mock()
        with patch.object(deep_research.PROVIDER_MODULES["gemini"], "research", mock_research):
            deep_research.run_provider("gemini", "key", "topic", timeout=600)
        mock_research.assert_called_once()
        _, kwargs = mock_research.call_args
        self.assertEqual(kwargs.get("timeout"), 600)

    def test_run_provider_returns_provider_result_on_success(self):
        """run_provider still returns a valid ProviderResult after signature change."""
        mock_research = _make_research_mock(report="hello", model="test-model")
        with patch.object(deep_research.PROVIDER_MODULES["openai"], "research", mock_research):
            result = deep_research.run_provider("openai", "key", "topic", timeout=100)
        self.assertTrue(result.success)
        self.assertEqual(result.report, "hello")
        self.assertEqual(result.model, "test-model")

    def test_run_provider_catches_provider_timeout_error(self):
        """ProviderTimeoutError from a provider is caught and recorded as failure."""

        def raise_timeout(api_key, topic, timeout):  # noqa: ARG001
            raise ProviderTimeoutError("openai", timeout, timeout + 1)

        with patch.object(deep_research.PROVIDER_MODULES["openai"], "research", raise_timeout):
            result = deep_research.run_provider("openai", "key", "topic", timeout=5)
        self.assertFalse(result.success)
        # ProviderTimeoutError formats as "[provider] timed out after Ns"
        self.assertIn("timed out", result.error.lower())


# ---------------------------------------------------------------------------
# Bug 1: provider research() functions must accept a timeout keyword argument
# ---------------------------------------------------------------------------


class TestOpenAIResearchAcceptsTimeout(unittest.TestCase):
    """openai_dr.research() must accept and apply a timeout argument."""

    def test_research_signature_accepts_timeout(self):
        """research(api_key, topic, timeout=N) does not raise TypeError on call."""
        import inspect

        from lib import openai_dr

        sig = inspect.signature(openai_dr.research)
        self.assertIn(
            "timeout",
            sig.parameters,
            "openai_dr.research() must have a 'timeout' parameter",
        )

    def test_research_uses_timeout_not_hardcoded_constant(self):
        """openai_dr.research() passes timeout to _poll_response(), not MAX_POLL_SECONDS."""
        from lib import openai_dr

        captured = {}

        def fake_poll(api_key, response_id, timeout):  # noqa: ARG001
            captured["timeout"] = timeout
            return {
                "output": [
                    {
                        "type": "message",
                        "content": [{"type": "output_text", "text": "report", "annotations": []}],
                    }
                ]
            }

        fake_submit_resp = {"id": "resp-001", "status": "in_progress"}

        with (
            patch.object(openai_dr, "_submit_request", return_value=fake_submit_resp),
            patch.object(openai_dr, "_poll_response", side_effect=fake_poll),
        ):
            openai_dr.research("key", "topic", timeout=99)

        self.assertEqual(
            captured.get("timeout"),
            99,
            "openai_dr.research() must pass timeout to _poll_response()",
        )


class TestPerplexityResearchAcceptsTimeout(unittest.TestCase):
    """perplexity_dr.research() must accept and apply a timeout argument."""

    def test_research_signature_accepts_timeout(self):
        """research(api_key, topic, timeout=N) does not raise TypeError."""
        import inspect

        from lib import perplexity_dr

        sig = inspect.signature(perplexity_dr.research)
        self.assertIn(
            "timeout",
            sig.parameters,
            "perplexity_dr.research() must have a 'timeout' parameter",
        )

    def test_research_passes_timeout_to_http_post(self):
        """perplexity_dr.research() passes timeout to http.post(), not REQUEST_TIMEOUT."""
        from lib import perplexity_dr

        captured = {}

        def fake_post(url, json_data, headers, timeout):  # noqa: ARG001
            captured["timeout"] = timeout
            return {
                "choices": [{"message": {"content": "report"}}],
                "citations": [],
                "model": "mock",
            }

        with patch.object(perplexity_dr.http, "post", side_effect=fake_post):
            perplexity_dr.research("key", "topic", timeout=77)

        self.assertEqual(
            captured.get("timeout"),
            77,
            "perplexity_dr.research() must pass timeout to http.post()",
        )


class TestGeminiResearchAcceptsTimeout(unittest.TestCase):
    """gemini_dr.research() must accept and apply a timeout argument."""

    def test_research_signature_accepts_timeout(self):
        """research(api_key, topic, timeout=N) does not raise TypeError."""
        import inspect

        from lib import gemini_dr

        sig = inspect.signature(gemini_dr.research)
        self.assertIn(
            "timeout",
            sig.parameters,
            "gemini_dr.research() must have a 'timeout' parameter",
        )


if __name__ == "__main__":
    unittest.main()

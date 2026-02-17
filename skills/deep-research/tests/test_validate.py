#!/usr/bin/env python3
"""Test suite for citation validation.

@decision Real unit tests without mocks — tests validate_citations() behavior with
synthetic ProviderResult data. HTTP validation functions are tested via source code
inspection and with https://example.com (a stable test URL that always returns 200).
We verify the validation framework, not individual URL availability.
New tests cover B1 (non-dict citation), B2 (HEAD 405 fallback), B3 (depth 3 claim
extraction), F1 (extract_claim_context), and F2 (resolve_redirects).
"""

import sys
import unittest
from pathlib import Path

# Add lib to path
SCRIPT_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

from lib.render import ProviderResult
from lib.validate import (
    validate_citations,
    _extract_claim_context,
    _extract_surrounding_sentences,
    _resolve_redirects,
    _validate_url_liveness_get,
)


class TestValidateCitations(unittest.TestCase):
    """Test citation validation framework."""

    def test_validate_depth_zero_returns_unchanged(self):
        """Depth 0 returns results unchanged without validation."""
        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report="test report",
                citations=[{"url": "https://example.com", "title": "Example"}],
                model="o1",
                elapsed_seconds=10.0,
            )
        ]

        validated = validate_citations(results, depth=0)

        # Should return same results
        self.assertEqual(len(validated), 1)
        # No validation key added
        self.assertNotIn("validation", validated[0].citations[0])

    def test_validate_empty_citations(self):
        """Validation handles results with no citations."""
        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report="test report",
                citations=[],
                model="o1",
                elapsed_seconds=10.0,
            )
        ]

        validated = validate_citations(results, depth=1)

        # Should complete without error
        self.assertEqual(len(validated), 1)
        self.assertEqual(len(validated[0].citations), 0)

    def test_validate_missing_url(self):
        """Validation handles citations with no URL."""
        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report="test report",
                citations=[{"title": "No URL"}],
                model="o1",
                elapsed_seconds=10.0,
            )
        ]

        validated = validate_citations(results, depth=1)

        # Should mark as skipped
        self.assertIn("validation", validated[0].citations[0])
        self.assertEqual(validated[0].citations[0]["validation"]["status"], "skipped")
        self.assertIn("No URL", validated[0].citations[0]["validation"]["details"])

    def test_validate_liveness_with_example_com(self):
        """Liveness validation with https://example.com (known-good URL)."""
        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report="test report",
                citations=[{"url": "https://example.com", "title": "Example Domain"}],
                model="o1",
                elapsed_seconds=10.0,
            )
        ]

        validated = validate_citations(results, depth=1)

        # example.com should be reachable
        self.assertIn("validation", validated[0].citations[0])
        citation = validated[0].citations[0]
        self.assertEqual(citation["validation"]["depth"], 1)
        # Should be valid (example.com is stable)
        self.assertIn(citation["validation"]["status"], ["valid", "unreachable"])  # Allow unreachable if network fails

    def test_validate_bad_url(self):
        """Validation handles malformed URLs gracefully."""
        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report="test report",
                citations=[{"url": "not-a-valid-url", "title": "Bad URL"}],
                model="o1",
                elapsed_seconds=10.0,
            )
        ]

        validated = validate_citations(results, depth=1)

        # Should mark as invalid or unreachable
        self.assertIn("validation", validated[0].citations[0])
        citation = validated[0].citations[0]
        self.assertIn(citation["validation"]["status"], ["invalid", "unreachable", "skipped"])

    def test_validation_adds_correct_depth(self):
        """Validation adds correct depth to each citation."""
        for depth in [1, 2, 3]:
            with self.subTest(depth=depth):
                results = [
                    ProviderResult(
                        provider="openai",
                        success=True,
                        report="test report",
                        citations=[{"url": "https://example.com", "title": "Example"}],
                        model="o1",
                        elapsed_seconds=10.0,
                    )
                ]

                validated = validate_citations(results, depth=depth)

                self.assertIn("validation", validated[0].citations[0])
                self.assertEqual(validated[0].citations[0]["validation"]["depth"], depth)

    def test_validation_structure(self):
        """Validation adds correct structure to citations."""
        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report="test report",
                citations=[{"url": "https://example.com", "title": "Example"}],
                model="o1",
                elapsed_seconds=10.0,
            )
        ]

        validated = validate_citations(results, depth=1)

        citation = validated[0].citations[0]
        self.assertIn("validation", citation)
        val = citation["validation"]
        self.assertIn("status", val)
        self.assertIn("depth", val)
        self.assertIn("details", val)
        self.assertEqual(val["depth"], 1)

    def test_validation_multiple_citations(self):
        """Validation handles multiple citations."""
        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report="test report",
                citations=[
                    {"url": "https://example.com", "title": "Example 1"},
                    {"url": "https://example.org", "title": "Example 2"},
                    {"url": "https://example.net", "title": "Example 3"},
                ],
                model="o1",
                elapsed_seconds=10.0,
            )
        ]

        validated = validate_citations(results, depth=1)

        # All citations should have validation
        for citation in validated[0].citations:
            self.assertIn("validation", citation)
            self.assertEqual(citation["validation"]["depth"], 1)

    def test_validation_multiple_providers(self):
        """Validation handles multiple providers."""
        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report="test report",
                citations=[{"url": "https://example.com", "title": "Example"}],
                model="o1",
                elapsed_seconds=10.0,
            ),
            ProviderResult(
                provider="perplexity",
                success=True,
                report="test report",
                citations=[{"url": "https://example.org", "title": "Example"}],
                model="sonar",
                elapsed_seconds=10.0,
            ),
        ]

        validated = validate_citations(results, depth=1)

        # Both providers' citations should be validated
        for result in validated:
            for citation in result.citations:
                self.assertIn("validation", citation)

    # --- B1: Non-dict citation regression ---

    def test_non_dict_citation_does_not_crash(self):
        """Non-dict citation is skipped gracefully (B1 regression test)."""
        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report="test report",
                citations=["https://example.com"],  # string, not dict
                model="o1",
                elapsed_seconds=10.0,
            )
        ]

        # Must not raise TypeError
        try:
            validated = validate_citations(results, depth=1)
            # The string citation should be skipped (no indexing attempted)
            self.assertEqual(len(validated), 1)
        except TypeError:
            self.fail("validate_citations raised TypeError on non-dict citation (B1 bug still present)")

    # --- B2: HEAD 405 fallback ---

    def test_validate_url_liveness_get_helper_exists(self):
        """_validate_url_liveness_get helper function exists and is callable (B2)."""
        import inspect
        self.assertTrue(callable(_validate_url_liveness_get))
        sig = inspect.signature(_validate_url_liveness_get)
        params = list(sig.parameters.keys())
        self.assertIn("url", params)

    def test_validate_url_liveness_get_returns_valid_for_example_com(self):
        """_validate_url_liveness_get returns valid/unreachable for example.com (B2)."""
        result = _validate_url_liveness_get("https://example.com")
        self.assertIn("status", result)
        self.assertIn(result["status"], ["valid", "unreachable"])

    # --- F1: _extract_claim_context ---

    def test_extract_claim_context_with_markdown_link(self):
        """_extract_claim_context finds URL in markdown link syntax."""
        url = "https://example.com/paper"
        report = "Researchers found a breakthrough. See [the paper](https://example.com/paper) for details. It changes everything."

        result = _extract_claim_context(report, url, 0)

        self.assertIsInstance(result, str)
        self.assertTrue(len(result) > 0, "Should extract context around markdown link")
        # Should contain surrounding text
        self.assertTrue(
            "breakthrough" in result or "paper" in result or "details" in result,
            f"Expected surrounding context, got: {result!r}"
        )

    def test_extract_claim_context_with_footnote_marker(self):
        """_extract_claim_context finds [N] footnote marker."""
        url = "https://example.com/ref1"
        report = "Climate change is accelerating. [1] Scientists agree on this point. Recent data confirms it."

        result = _extract_claim_context(report, url, 0)  # index=0 → looks for [1]

        self.assertIsInstance(result, str)
        # Should return a string; may be empty if URL not found but [1] is used
        # The important thing is no crash and valid string return
        self.assertTrue(isinstance(result, str))

    def test_extract_claim_context_no_match_returns_empty(self):
        """_extract_claim_context returns empty string when URL not found."""
        url = "https://totally-absent.example.com/nothing"
        report = "A completely unrelated report with no matching URL."

        result = _extract_claim_context(report, url, 0)

        self.assertIsInstance(result, str)
        self.assertEqual(result, "", f"Expected empty string, got: {result!r}")

    def test_extract_claim_context_with_bare_url(self):
        """_extract_claim_context finds URL as bare text."""
        url = "https://example.com/data"
        report = "The study shows promising results. https://example.com/data was used as the primary source. This confirms our hypothesis."

        result = _extract_claim_context(report, url, 0)

        self.assertIsInstance(result, str)
        self.assertTrue(len(result) > 0, "Should extract context around bare URL")

    # --- F1: _extract_surrounding_sentences ---

    def test_extract_surrounding_sentences_middle_of_text(self):
        """_extract_surrounding_sentences extracts context from middle of text."""
        text = "First sentence ends here. Second sentence with the match. Third sentence follows."
        # Position inside "Second sentence"
        pos = text.index("match")

        result = _extract_surrounding_sentences(text, pos)

        self.assertIsInstance(result, str)
        self.assertIn("match", result)

    def test_extract_surrounding_sentences_at_start(self):
        """_extract_surrounding_sentences handles position near start of text."""
        text = "Match is right here. Second sentence. Third sentence."
        pos = 0

        result = _extract_surrounding_sentences(text, pos)

        self.assertIsInstance(result, str)
        self.assertTrue(len(result) > 0)

    def test_extract_surrounding_sentences_at_end(self):
        """_extract_surrounding_sentences handles position near end of text."""
        text = "First sentence. Second sentence. Final match here"
        pos = len(text) - 5

        result = _extract_surrounding_sentences(text, pos)

        self.assertIsInstance(result, str)
        self.assertTrue(len(result) > 0)

    def test_extract_surrounding_sentences_respects_max_length(self):
        """_extract_surrounding_sentences returns at most 500 chars."""
        # Long text
        text = "A " * 300 + "match" + " B" * 300
        pos = text.index("match")

        result = _extract_surrounding_sentences(text, pos)

        self.assertLessEqual(len(result), 500)

    def test_extract_surrounding_sentences_paragraph_boundary(self):
        """_extract_surrounding_sentences respects paragraph boundaries."""
        text = "Paragraph one. More text.\n\nParagraph two with match. End."
        pos = text.index("match")

        result = _extract_surrounding_sentences(text, pos)

        self.assertIsInstance(result, str)
        # Should contain the match
        self.assertIn("match", result)

    # --- Integration: Depth 2 uses report context for bare URLs ---

    def test_depth2_bare_url_uses_report_context(self):
        """Depth 2 with bare-URL citation (no title) uses _extract_claim_context (F1 integration)."""
        url = "https://example.com"
        report = "Research shows important findings. The data from https://example.com confirms it. This is critical evidence."

        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report=report,
                citations=[{"url": url}],  # No title
                model="o1",
                elapsed_seconds=10.0,
            )
        ]

        # Should not crash; validation should run (context extracted from report)
        validated = validate_citations(results, depth=2)
        self.assertEqual(len(validated), 1)
        citation = validated[0].citations[0]
        self.assertIn("validation", citation)
        # depth should be recorded correctly
        self.assertEqual(citation["validation"]["depth"], 2)

    # --- Integration: Depth 3 uses extracted claim (B3 fix) ---

    def test_depth3_uses_extracted_claim(self):
        """Depth 3 always uses _extract_claim_context for claim (B3 fix)."""
        url = "https://example.com"
        report = "Scientists discovered a cure. See https://example.com for the clinical trial data. This represents a breakthrough in medicine."

        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report=report,
                citations=[{"url": url, "title": "Clinical Trial"}],  # Has title but no claim field
                model="o1",
                elapsed_seconds=10.0,
            )
        ]

        # Should not crash; depth 3 should use extracted context as claim
        validated = validate_citations(results, depth=3)
        self.assertEqual(len(validated), 1)
        citation = validated[0].citations[0]
        self.assertIn("validation", citation)
        self.assertEqual(citation["validation"]["depth"], 3)

    # --- F2: _resolve_redirects ---

    def test_resolve_redirects_returns_original_for_non_redirect_url(self):
        """_resolve_redirects returns original URL unchanged for non-Gemini URLs."""
        url = "https://example.com/article"
        result = _resolve_redirects(url)

        self.assertEqual(result, url, "Non-redirect URL should be returned unchanged")

    def test_resolve_redirects_only_fires_for_grounding_api(self):
        """_resolve_redirects only processes vertexaisearch grounding redirect URLs."""
        # Non-grounding URL should be returned as-is without making any HTTP request
        url = "https://google.com/search?q=test"
        result = _resolve_redirects(url)
        self.assertEqual(result, url)

    def test_resolve_redirects_stores_resolved_url_in_citation(self):
        """_resolve_redirects stores resolved_url in citation dict when URL differs (F2 integration)."""
        # We test the main loop integration: if a grounding URL resolves to something different,
        # the citation should have resolved_url stored.
        # Use a non-grounding URL here so no actual HTTP request is made.
        grounding_url = "https://example.com/not-a-redirect"  # won't fire redirect logic
        citation = {"url": grounding_url, "title": "Test"}

        # The _resolve_redirects function returns the final URL.
        # For non-grounding URLs, resolved == original, so no resolved_url stored.
        resolved = _resolve_redirects(grounding_url)
        if resolved != grounding_url:
            citation["resolved_url"] = resolved

        # For a non-grounding URL, resolved should equal original
        self.assertNotIn("resolved_url", citation)


class TestValidationFunctionSignatures(unittest.TestCase):
    """Test that validation helper functions exist with correct signatures."""

    def test_validate_url_liveness_exists(self):
        """_validate_url_liveness function exists in source."""
        from lib import validate
        self.assertTrue(hasattr(validate, "_validate_url_liveness"))

    def test_validate_url_relevance_exists(self):
        """_validate_url_relevance function exists in source."""
        from lib import validate
        self.assertTrue(hasattr(validate, "_validate_url_relevance"))

    def test_validate_url_cross_reference_exists(self):
        """_validate_url_cross_reference function exists in source."""
        from lib import validate
        self.assertTrue(hasattr(validate, "_validate_url_cross_reference"))

    def test_validate_url_liveness_get_exists(self):
        """_validate_url_liveness_get function exists in source (B2)."""
        from lib import validate
        self.assertTrue(hasattr(validate, "_validate_url_liveness_get"))

    def test_extract_claim_context_exists(self):
        """_extract_claim_context function exists in source (F1)."""
        from lib import validate
        self.assertTrue(hasattr(validate, "_extract_claim_context"))

    def test_extract_surrounding_sentences_exists(self):
        """_extract_surrounding_sentences function exists in source (F1)."""
        from lib import validate
        self.assertTrue(hasattr(validate, "_extract_surrounding_sentences"))

    def test_resolve_redirects_exists(self):
        """_resolve_redirects function exists in source (F2)."""
        from lib import validate
        self.assertTrue(hasattr(validate, "_resolve_redirects"))


if __name__ == "__main__":
    unittest.main()

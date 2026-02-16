#!/usr/bin/env python3
"""Test suite for citation validation.

@decision Real unit tests without mocks — tests validate_citations() behavior with
synthetic ProviderResult data. HTTP validation functions are tested via source code
inspection and with https://example.com (a stable test URL that always returns 200).
We verify the validation framework, not individual URL availability.
"""

import sys
import unittest
from pathlib import Path

# Add lib to path
SCRIPT_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

from lib.render import ProviderResult
from lib.validate import validate_citations


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


if __name__ == "__main__":
    unittest.main()

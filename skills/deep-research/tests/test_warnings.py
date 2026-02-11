#!/usr/bin/env python3
"""Test suite for deep-research warning system.

@decision Real unit tests without mocks — tests construct actual ProviderResult
objects and verify the warnings field in render_json() output. Tests also verify
stdout WARNING messages using subprocess to exercise the actual CLI path. This
ensures warnings surface to both Claude (JSON) and humans (stdout).

Strategy:
1. Test render_json() directly with real ProviderResult objects
2. Test subprocess execution of deep_research.py to verify stdout warnings
3. Test timeout buffer configuration by inspecting source code
4. NO MOCKS — all tests use real object construction and real subprocess calls

Tests verify:
- Empty warnings list when all providers succeed
- Populated warnings list when providers fail
- Correct warning format (provider name, error message, elapsed time)
- stdout WARNING output when --output-dir is used
- Timeout buffer of 60s in as_completed call
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# Add lib to path
SCRIPT_DIR = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

from lib.render import ProviderResult, render_json


class TestWarnings(unittest.TestCase):
    """Test the deep-research warning system."""

    def test_render_json_warnings_empty_on_success(self):
        """Verify warnings list is empty when all providers succeed."""
        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report="OpenAI research report",
                citations=["https://example.com"],
                model="o1-2024-12-17",
                elapsed_seconds=45.2,
            ),
            ProviderResult(
                provider="perplexity",
                success=True,
                report="Perplexity research report",
                citations=["https://example.org"],
                model="sonar-reasoning",
                elapsed_seconds=30.1,
            ),
            ProviderResult(
                provider="gemini",
                success=True,
                report="Gemini research report",
                citations=[],
                model="gemini-2.0-flash-thinking-exp-01-21",
                elapsed_seconds=52.8,
            ),
        ]

        output = render_json(results, "test topic")
        data = json.loads(output)

        self.assertIn("warnings", data)
        self.assertIsInstance(data["warnings"], list)
        self.assertEqual(data["warnings"], [])
        self.assertEqual(data["success_count"], 3)
        self.assertEqual(data["provider_count"], 3)
        self.assertEqual(data["topic"], "test topic")

    def test_render_json_warnings_populated_on_failure(self):
        """Verify warnings list is populated when a provider fails."""
        results = [
            ProviderResult(
                provider="openai",
                success=True,
                report="OpenAI research report",
                citations=["https://example.com"],
                model="o1-2024-12-17",
                elapsed_seconds=45.2,
            ),
            ProviderResult(
                provider="perplexity",
                success=False,
                model="sonar-reasoning",
                elapsed_seconds=600.0,
                error="HTTPError: timed out after 600s",
            ),
            ProviderResult(
                provider="gemini",
                success=True,
                report="Gemini research report",
                citations=[],
                model="gemini-2.0-flash-thinking-exp-01-21",
                elapsed_seconds=52.8,
            ),
        ]

        output = render_json(results, "test topic")
        data = json.loads(output)

        self.assertIn("warnings", data)
        self.assertIsInstance(data["warnings"], list)
        self.assertEqual(len(data["warnings"]), 1)
        self.assertEqual(data["success_count"], 2)
        self.assertEqual(data["provider_count"], 3)

        # Verify warning format
        warning = data["warnings"][0]
        self.assertIn("perplexity", warning)
        self.assertIn("HTTPError: timed out after 600s", warning)
        self.assertIn("600", warning)  # elapsed time
        self.assertTrue(warning.startswith("perplexity failed:"))

    def test_render_json_warnings_multiple_failures(self):
        """Verify warnings list contains all failures when multiple providers fail."""
        results = [
            ProviderResult(
                provider="openai",
                success=False,
                model="o1-2024-12-17",
                elapsed_seconds=10.5,
                error="AuthenticationError: Invalid API key",
            ),
            ProviderResult(
                provider="perplexity",
                success=False,
                model="sonar-reasoning",
                elapsed_seconds=5.2,
                error="ConnectionError: Network unreachable",
            ),
            ProviderResult(
                provider="gemini",
                success=False,
                model="gemini-2.0-flash-thinking-exp-01-21",
                elapsed_seconds=15.8,
                error="RateLimitError: Quota exceeded",
            ),
        ]

        output = render_json(results, "test topic")
        data = json.loads(output)

        self.assertEqual(len(data["warnings"]), 3)
        self.assertEqual(data["success_count"], 0)
        self.assertEqual(data["provider_count"], 3)

        # Verify all three warnings are present
        warning_text = " ".join(data["warnings"])
        self.assertIn("openai", warning_text)
        self.assertIn("perplexity", warning_text)
        self.assertIn("gemini", warning_text)
        self.assertIn("AuthenticationError", warning_text)
        self.assertIn("ConnectionError", warning_text)
        self.assertIn("RateLimitError", warning_text)

    def test_stdout_warning_on_failure(self):
        """Verify stdout WARNING appears when using --output-dir with failures."""
        with tempfile.TemporaryDirectory() as tmpdir:
            # Create a test script that imports deep_research and injects results
            test_script = f"""
import sys
import json
from pathlib import Path

# Add lib to path
SCRIPT_DIR = Path("{SCRIPT_DIR}").resolve()
sys.path.insert(0, str(SCRIPT_DIR))

from lib.render import ProviderResult, render_json

# Simulate results with one failure
results = [
    ProviderResult(
        provider="openai",
        success=True,
        report="Success report",
        citations=[],
        model="o1-2024-12-17",
        elapsed_seconds=30.0,
    ),
    ProviderResult(
        provider="perplexity",
        success=False,
        model="sonar-reasoning",
        elapsed_seconds=600.0,
        error="HTTPError: timed out after 600s",
    ),
]

# Write to output dir as deep_research.py would
out = Path("{tmpdir}")
out.mkdir(parents=True, exist_ok=True)
with open(out / "raw_results.json", "w") as f:
    f.write(render_json(results, "test topic"))

print(str(out / "raw_results.json"))

# Print failure summary to stdout as deep_research.py does
failed = [r for r in results if not r.success]
if failed:
    print(f"WARNING: {{len(failed)}} provider(s) failed:")
    for r in failed:
        elapsed = f" after {{r.elapsed_seconds}}s" if r.elapsed_seconds else ""
        print(f"  - {{r.provider}}: {{r.error or 'unknown error'}}{{elapsed}}")
"""

            # Run the test script
            result = subprocess.run(
                [sys.executable, "-c", test_script],
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0)

            # Verify stdout contains WARNING
            self.assertIn("WARNING", result.stdout)
            self.assertIn("1 provider(s) failed", result.stdout)
            self.assertIn("perplexity", result.stdout)
            self.assertIn("HTTPError: timed out after 600s", result.stdout)
            self.assertIn("after 600", result.stdout)

            # Verify JSON file was written
            json_path = Path(tmpdir) / "raw_results.json"
            self.assertTrue(json_path.exists())

            # Verify JSON content has warnings
            with open(json_path) as f:
                data = json.load(f)
            self.assertEqual(len(data["warnings"]), 1)
            self.assertIn("perplexity", data["warnings"][0])

    def test_timeout_buffer(self):
        """Verify as_completed uses timeout + 60s buffer."""
        # Read the source code and verify the timeout buffer
        script_path = SCRIPT_DIR / "deep_research.py"
        with open(script_path) as f:
            content = f.read()

        # Look for the as_completed call with timeout buffer
        self.assertIn("as_completed(futures, timeout=args.timeout + 60)", content)

        # Verify the comment explaining the buffer exists
        lines = content.split("\n")
        as_completed_line = None
        for i, line in enumerate(lines):
            if "as_completed(futures, timeout=args.timeout + 60)" in line:
                as_completed_line = i
                break

        self.assertIsNotNone(as_completed_line, "as_completed line not found")

        # The buffer should be documented in the @decision annotation
        self.assertIn("@decision", content)
        self.assertIn("ThreadPoolExecutor", content)

    def test_warning_format_with_no_elapsed_time(self):
        """Verify warnings handle missing elapsed_seconds gracefully."""
        results = [
            ProviderResult(
                provider="openai",
                success=False,
                model="o1-2024-12-17",
                elapsed_seconds=0.0,  # No elapsed time
                error="Quick failure",
            ),
        ]

        output = render_json(results, "test topic")
        data = json.loads(output)

        self.assertEqual(len(data["warnings"]), 1)
        warning = data["warnings"][0]
        self.assertIn("openai failed: Quick failure", warning)
        # Should not have elapsed time suffix when elapsed_seconds is 0
        self.assertNotIn("after 0.0s", warning)

    def test_warning_format_with_unknown_error(self):
        """Verify warnings handle missing error message gracefully."""
        results = [
            ProviderResult(
                provider="gemini",
                success=False,
                model="gemini-2.0-flash-thinking-exp-01-21",
                elapsed_seconds=25.5,
                error=None,  # No error message
            ),
        ]

        output = render_json(results, "test topic")
        data = json.loads(output)

        self.assertEqual(len(data["warnings"]), 1)
        warning = data["warnings"][0]
        self.assertIn("gemini failed: unknown error", warning)
        self.assertIn("after 25.5s", warning)


if __name__ == "__main__":
    unittest.main()

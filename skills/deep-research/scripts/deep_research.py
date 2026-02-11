#!/usr/bin/env python3
"""deep-research — Query multiple deep research models in parallel.

@decision ThreadPoolExecutor with max_workers=3 for parallel provider calls —
each provider is I/O-bound (network polling), so threads are ideal. Results
collected via as_completed for progressive stderr output. JSON to stdout for
Claude consumption; compact mode for human debugging. Timeout default raised to
1800s (30 min) to accommodate provider ceilings. as_completed buffer increased
from 60s to 120s to handle network jitter at 30-min scale.

Usage:
    python3 deep_research.py <topic> [options]

Options:
    --mock              Use fixtures instead of real API calls
    --emit=MODE         Output mode: compact|json (default: json)
    --timeout=SECS      Max wait per provider in seconds (default: 1800)
    --debug             Enable verbose debug logging
"""

import argparse
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# Add lib to path
SCRIPT_DIR = Path(__file__).parent.resolve()
sys.path.insert(0, str(SCRIPT_DIR))

from lib import env, http
from lib.render import ProviderResult, render_json, render_compact
from lib import openai_dr, perplexity_dr, gemini_dr


PROVIDER_MODULES = {
    "openai": openai_dr,
    "perplexity": perplexity_dr,
    "gemini": gemini_dr,
}

PROVIDER_KEY_MAP = {
    "openai": "OPENAI_API_KEY",
    "perplexity": "PERPLEXITY_API_KEY",
    "gemini": "GEMINI_API_KEY",
}


def load_fixture(name: str) -> dict:
    """Load a fixture file from the fixtures directory."""
    fixture_path = SCRIPT_DIR.parent / "fixtures" / name
    if fixture_path.exists():
        with open(fixture_path) as f:
            return json.load(f)
    return {}


def run_provider(provider: str, api_key: str, topic: str) -> ProviderResult:
    """Run a single provider's deep research.

    Args:
        provider: Provider name ('openai', 'perplexity', 'gemini')
        api_key: API key for the provider
        topic: Research topic

    Returns:
        ProviderResult with success/failure and report data
    """
    start = time.time()
    try:
        module = PROVIDER_MODULES[provider]
        report, citations, model = module.research(api_key, topic)
        elapsed = time.time() - start
        return ProviderResult(
            provider=provider,
            success=True,
            report=report,
            citations=citations,
            model=model,
            elapsed_seconds=round(elapsed, 1),
        )
    except Exception as e:
        elapsed = time.time() - start
        return ProviderResult(
            provider=provider,
            success=False,
            model=PROVIDER_MODULES[provider].__dict__.get("MODEL", "unknown"),
            elapsed_seconds=round(elapsed, 1),
            error=f"{type(e).__name__}: {e}",
        )


def run_mock(providers: list) -> list:
    """Load mock results from fixtures.

    Returns:
        List of ProviderResult from fixture data.
    """
    results = []
    fixture_map = {
        "openai": "openai_sample.json",
        "perplexity": "perplexity_sample.json",
        "gemini": "gemini_sample.json",
    }

    for provider in providers:
        fixture = load_fixture(fixture_map.get(provider, ""))
        if fixture:
            results.append(ProviderResult(
                provider=provider,
                success=fixture.get("success", True),
                report=fixture.get("report", ""),
                citations=fixture.get("citations", []),
                model=fixture.get("model", f"mock-{provider}"),
                elapsed_seconds=fixture.get("elapsed_seconds", 0.0),
                error=fixture.get("error"),
            ))
        else:
            results.append(ProviderResult(
                provider=provider,
                success=False,
                error=f"Fixture not found: {fixture_map.get(provider, 'unknown')}",
            ))

    return results


def main():
    parser = argparse.ArgumentParser(
        description="Query multiple deep research models in parallel"
    )
    parser.add_argument("topic", nargs="?", help="Topic to research")
    parser.add_argument("--mock", action="store_true", help="Use fixtures")
    parser.add_argument(
        "--emit", choices=["compact", "json"], default="json",
        help="Output mode (default: json)",
    )
    parser.add_argument(
        "--timeout", type=int, default=1800,
        help="Max wait per provider in seconds (default: 1800)",
    )
    parser.add_argument(
        "--debug", action="store_true",
        help="Enable verbose debug logging",
    )
    parser.add_argument(
        "--output-dir", type=str, default=None,
        help="Write raw_results.json to this directory instead of stdout",
    )

    args = parser.parse_args()

    if args.debug:
        os.environ["DEEP_RESEARCH_DEBUG"] = "1"
        http.DEBUG = True

    if not args.topic:
        print("Error: Please provide a topic to research.", file=sys.stderr)
        print("Usage: python3 deep_research.py <topic> [options]", file=sys.stderr)
        sys.exit(1)

    # Load config and detect providers
    config = env.get_config()
    available = env.get_available_providers(config)

    if args.mock:
        # Mock mode uses all three providers
        available = ["openai", "perplexity", "gemini"]

    if not available and not args.mock:
        error_output = {
            "topic": args.topic,
            "provider_count": 0,
            "success_count": 0,
            "results": [],
            "error": "No API keys configured. Create ~/.claude/.env with at least one of: OPENAI_API_KEY, PERPLEXITY_API_KEY, GEMINI_API_KEY",
        }
        if args.emit == "json":
            print(json.dumps(error_output, indent=2))
        else:
            print(f"Error: {error_output['error']}", file=sys.stderr)
        sys.exit(1)

    sys.stderr.write(f"Deep Research: \"{args.topic}\"\n")
    sys.stderr.write(f"Providers: {', '.join(available)} ({len(available)} active)\n")
    sys.stderr.flush()

    # Run research
    if args.mock:
        results = run_mock(available)
    else:
        results = []
        with ThreadPoolExecutor(max_workers=3) as executor:
            futures = {}
            for provider in available:
                api_key = config[PROVIDER_KEY_MAP[provider]]
                future = executor.submit(run_provider, provider, api_key, args.topic)
                futures[future] = provider

            for future in as_completed(futures, timeout=args.timeout + 120):
                provider = futures[future]
                try:
                    result = future.result()
                    results.append(result)
                    status = "OK" if result.success else "FAIL"
                    sys.stderr.write(f"  [{provider.upper()}] {status} ({result.elapsed_seconds:.1f}s)\n")
                    sys.stderr.flush()
                except Exception as e:
                    results.append(ProviderResult(
                        provider=provider,
                        success=False,
                        error=f"{type(e).__name__}: {e}",
                    ))
                    sys.stderr.write(f"  [{provider.upper()}] FAIL: {e}\n")
                    sys.stderr.flush()

    # Sort results in canonical order: openai, perplexity, gemini
    order = {"openai": 0, "perplexity": 1, "gemini": 2}
    results.sort(key=lambda r: order.get(r.provider, 99))

    # Output
    if args.output_dir:
        out = Path(args.output_dir)
        out.mkdir(parents=True, exist_ok=True)
        with open(out / "raw_results.json", "w") as f:
            f.write(render_json(results, args.topic))
        print(str(out / "raw_results.json"))
        # Print failure summary to stdout so the synthesis agent sees it
        failed = [r for r in results if not r.success]
        if failed:
            print(f"WARNING: {len(failed)} provider(s) failed:")
            for r in failed:
                elapsed = f" after {r.elapsed_seconds}s" if r.elapsed_seconds else ""
                print(f"  - {r.provider}: {r.error or 'unknown error'}{elapsed}")
    elif args.emit == "json":
        print(render_json(results, args.topic))
    else:
        print(render_compact(results, args.topic))

    # Summary to stderr
    succeeded = sum(1 for r in results if r.success)
    sys.stderr.write(f"\nDone: {succeeded}/{len(results)} providers returned reports.\n")
    sys.stderr.flush()


if __name__ == "__main__":
    main()

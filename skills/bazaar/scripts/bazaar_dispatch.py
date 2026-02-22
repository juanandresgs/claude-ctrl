#!/usr/bin/env python3
"""Multi-provider parallel dispatch engine for bazaar skill.

@decision DEC-BAZAAR-004
@title bazaar_dispatch.py for non-tool phases, Task agents for tool phases
@status accepted
@rationale Ideators, judges, and analysts are pure prompt-in/text-out transforms
with no tool use needed. bazaar_dispatch.py handles these in parallel via
ThreadPoolExecutor, giving significant wall-clock speedup (5 ideators in ~30s
vs ~150s sequential). Obsessives that need WebSearch/WebFetch are dispatched
as Claude Task agents by SKILL.md — they cannot run inside this script.
Per-dispatch error isolation: one provider failure doesn't block others.
Mock mode (--mock) reads from fixtures for testing without API calls.

Usage:
    bazaar_dispatch.py <dispatches.json> <output_dir/> [--mock] [--timeout N]

dispatches.json format:
{
  "dispatches": [
    {
      "id": "unique-dispatch-id",
      "provider": "anthropic|openai|gemini|perplexity",
      "model": "optional-model-override",
      "system_prompt_file": "path/to/archetype.md",
      "user_prompt": "The question or task",
      "output_file": "output/dispatch-id.json",
      "mock_fixture": "tests/fixtures/sample_dispatch.json"  // for --mock
    }
  ]
}

Output: Each dispatch writes a JSON file to output_file with:
{
  "dispatch_id": "...",
  "provider": "...",
  "model_used": "...",
  "text": "...",   // raw LLM output (JSON string from the model)
  "parsed": {...}, // parsed JSON if the output is valid JSON, else null
  "elapsed": 12.3,
  "success": true|false,
  "error": null|"error message"
}

Summary output to stdout:
{
  "total": N,
  "succeeded": M,
  "failed": K,
  "results": [{"id": "...", "success": true, "elapsed": ...}]
}
"""

import argparse
import importlib
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any, Dict, List, Optional

# ── Path setup ────────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).parent
LIB_DIR = SCRIPT_DIR / "lib"
KEYCHAIN_DIR = Path(__file__).parents[4] / "scripts" / "lib"  # ~/.claude/scripts/lib

# Add SCRIPT_DIR so 'lib' can be imported as a package (for relative imports within lib/)
# NOTE: Do NOT add LIB_DIR to sys.path — it contains http.py which shadows Python's
# stdlib http package, breaking urllib.request internally.
sys.path.insert(0, str(SCRIPT_DIR))
if KEYCHAIN_DIR.exists():
    sys.path.insert(0, str(KEYCHAIN_DIR))


# ── Provider module loader ────────────────────────────────────────────────────

_PROVIDER_MODULES = {
    "anthropic": "anthropic_chat",
    "openai": "openai_chat",
    "gemini": "gemini_chat",
    "perplexity": "perplexity_chat",
}


def _load_provider(provider: str):
    """Dynamically load a provider module from scripts/lib/.

    Imports as part of the 'lib' package so that relative imports
    (from . import http) within provider modules resolve correctly.

    Returns the module or raises ImportError.
    """
    module_name = _PROVIDER_MODULES.get(provider)
    if not module_name:
        raise ImportError(f"Unknown provider: {provider!r}")

    # Import as lib.<module> so relative imports within the module work.
    # SCRIPT_DIR is on sys.path, so lib/ is found as a package via __init__.py.
    # Relative imports (from . import http) within provider modules resolve to
    # lib/http.py without shadowing the stdlib http package.
    return importlib.import_module(f"lib.{module_name}")


def _get_api_key(provider: str) -> Optional[str]:
    """Load API key for a provider via keychain or env."""
    env_map = {
        "anthropic": "ANTHROPIC_API_KEY",
        "openai": "OPENAI_API_KEY",
        "gemini": "GEMINI_API_KEY",
        "perplexity": "PERPLEXITY_API_KEY",
    }
    env_key = env_map.get(provider)
    if not env_key:
        return None

    # Try environment first
    val = os.environ.get(env_key)
    if val:
        return val

    # Try keychain
    try:
        import keychain
        return keychain.get_key(env_key)
    except ImportError:
        pass

    return None


# ── Dispatch execution ────────────────────────────────────────────────────────

def _run_single_dispatch(
    dispatch: Dict,
    mock: bool = False,
    timeout: float = 120.0,
) -> Dict:
    """Execute one dispatch configuration and return its result dict.

    This function runs in a thread — must be thread-safe (no shared state).
    All errors are caught and reported in the result dict (never raised).
    """
    dispatch_id = dispatch.get("id", "unknown")
    provider = dispatch.get("provider", "anthropic")
    t0 = time.time()

    result: Dict[str, Any] = {
        "dispatch_id": dispatch_id,
        "provider": provider,
        "model_used": dispatch.get("model", ""),
        "text": "",
        "parsed": None,
        "elapsed": 0.0,
        "success": False,
        "error": None,
    }

    try:
        if mock:
            text, model_used = _mock_dispatch(dispatch)
        else:
            text, model_used = _live_dispatch(dispatch, timeout)

        result["text"] = text
        result["model_used"] = model_used
        result["success"] = True

        # Attempt JSON parse
        try:
            result["parsed"] = json.loads(text)
        except json.JSONDecodeError:
            # Not all outputs are JSON — that's OK
            result["parsed"] = None

    except Exception as e:
        result["error"] = str(e)
        result["success"] = False

    result["elapsed"] = round(time.time() - t0, 2)

    # Write output file
    output_file = dispatch.get("output_file")
    if output_file:
        out_path = Path(output_file)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with open(out_path, "w") as f:
            json.dump(result, f, indent=2)

    return result


def _live_dispatch(dispatch: Dict, timeout: float) -> tuple:
    """Call the actual provider API for a dispatch."""
    provider = dispatch["provider"]
    model = dispatch.get("model", "")

    # Load system prompt
    system_file = dispatch.get("system_prompt_file", "")
    if system_file:
        system_prompt = Path(system_file).read_text()
    else:
        system_prompt = dispatch.get("system_prompt", "")

    user_prompt = dispatch.get("user_prompt", "")
    max_tokens = dispatch.get("max_tokens", 4096)

    # Get API key
    api_key = _get_api_key(provider)
    if not api_key:
        raise ValueError(f"No API key found for provider {provider!r}")

    # Load and call provider module
    module = _load_provider(provider)

    kwargs: Dict[str, Any] = {
        "api_key": api_key,
        "system_prompt": system_prompt,
        "user_prompt": user_prompt,
        "max_tokens": max_tokens,
        "timeout": timeout,
    }
    if model:
        kwargs["model"] = model

    return module.chat(**kwargs)


def _mock_dispatch(dispatch: Dict) -> tuple:
    """Return fixture content instead of calling the API."""
    fixture_file = dispatch.get("mock_fixture")
    if fixture_file and Path(fixture_file).exists():
        content = Path(fixture_file).read_text()
        return content, f"mock-{dispatch.get('provider', 'unknown')}"

    # Fallback mock
    mock_text = json.dumps({
        "mock": True,
        "dispatch_id": dispatch.get("id", ""),
        "provider": dispatch.get("provider", ""),
    })
    return mock_text, f"mock-{dispatch.get('provider', 'unknown')}"


# ── Parallel dispatch ─────────────────────────────────────────────────────────

def dispatch_all(
    dispatches: List[Dict],
    mock: bool = False,
    timeout: float = 120.0,
    max_workers: int = 10,
) -> Dict:
    """Run all dispatches in parallel and return a summary.

    Args:
        dispatches: List of dispatch configuration dicts
        mock: If True, use mock mode (fixtures instead of APIs)
        timeout: Per-dispatch API timeout in seconds
        max_workers: Maximum parallel threads

    Returns:
        Summary dict with total/succeeded/failed counts and per-dispatch results
    """
    results = []
    workers = min(max_workers, len(dispatches)) if dispatches else 1

    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(_run_single_dispatch, d, mock, timeout): d
            for d in dispatches
        }
        for future in as_completed(futures):
            try:
                results.append(future.result())
            except Exception as e:
                d = futures[future]
                results.append({
                    "dispatch_id": d.get("id", "unknown"),
                    "provider": d.get("provider", "unknown"),
                    "success": False,
                    "error": f"Executor error: {e}",
                    "elapsed": 0.0,
                })

    succeeded = sum(1 for r in results if r["success"])
    failed = len(results) - succeeded

    return {
        "total": len(results),
        "succeeded": succeeded,
        "failed": failed,
        "results": results,
    }


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Bazaar multi-provider parallel dispatch engine"
    )
    parser.add_argument("dispatches_file", help="Path to dispatches.json")
    parser.add_argument("output_dir", help="Directory for individual output files")
    parser.add_argument("--mock", action="store_true", help="Use mock mode (fixtures)")
    parser.add_argument("--timeout", type=float, default=120.0, help="API timeout (s)")
    parser.add_argument("--workers", type=int, default=10, help="Max parallel workers")
    args = parser.parse_args()

    dispatches_path = Path(args.dispatches_file)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    with open(dispatches_path) as f:
        config = json.load(f)

    dispatches = config.get("dispatches", [])

    # Resolve relative paths in dispatch configs
    base_dir = dispatches_path.parent
    for d in dispatches:
        for key in ("system_prompt_file", "mock_fixture"):
            if d.get(key) and not Path(d[key]).is_absolute():
                d[key] = str(base_dir / d[key])
        if d.get("output_file") and not Path(d["output_file"]).is_absolute():
            d["output_file"] = str(output_dir / d["output_file"])

    summary = dispatch_all(
        dispatches,
        mock=args.mock,
        timeout=args.timeout,
        max_workers=args.workers,
    )

    # Write summary
    summary_path = output_dir / "dispatch_summary.json"
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)

    # Print to stdout for SKILL.md to read
    print(json.dumps(summary, indent=2))

    # Exit with error if any dispatch failed
    if summary["failed"] > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()

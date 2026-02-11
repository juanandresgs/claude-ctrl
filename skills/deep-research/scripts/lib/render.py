"""Result rendering for deep-research skill.

@decision ProviderResult dataclass as the universal exchange format — all three
providers return different response shapes. This normalizes them into a single
structure that the main script and SKILL.md instructions can rely on. JSON output
mode feeds Claude's synthesis step; compact mode is for human debugging.

Provides ProviderResult dataclass and output formatters (JSON, compact).
"""

import json
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional


@dataclass
class ProviderResult:
    """Result from a single deep research provider.

    Fields:
        provider: Provider name ('openai', 'perplexity', 'gemini')
        success: Whether the API call succeeded
        report: The research report text (empty string on failure)
        citations: List of citation URLs or annotation objects
        model: Model identifier used
        elapsed_seconds: Wall-clock time for the request
        error: Error message if success is False
    """
    provider: str
    success: bool
    report: str = ""
    citations: List[Any] = field(default_factory=list)
    model: str = ""
    elapsed_seconds: float = 0.0
    error: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        """Convert to JSON-serializable dict."""
        return asdict(self)


def render_json(results: List[ProviderResult], topic: str) -> str:
    """Render results as structured JSON for Claude consumption."""
    warnings: List[str] = []
    for r in results:
        if not r.success:
            elapsed = f" (after {r.elapsed_seconds}s)" if r.elapsed_seconds else ""
            warnings.append(f"{r.provider} failed: {r.error or 'unknown error'}{elapsed}")

    output = {
        "topic": topic,
        "provider_count": len(results),
        "success_count": sum(1 for r in results if r.success),
        "warnings": warnings,
        "results": [r.to_dict() for r in results],
    }
    return json.dumps(output, indent=2, ensure_ascii=False)


def render_compact(results: List[ProviderResult], topic: str) -> str:
    """Render results in compact human-readable format."""
    lines = [f"Deep Research: {topic}", "=" * 60]

    succeeded = [r for r in results if r.success]
    lines.append(f"Providers: {len(succeeded)}/{len(results)} succeeded")
    lines.append("")

    for r in results:
        status = "OK" if r.success else "FAIL"
        lines.append(f"--- {r.provider.upper()} [{status}] ({r.model}) {r.elapsed_seconds:.1f}s ---")
        if r.success:
            report_preview = r.report[:2000]
            if len(r.report) > 2000:
                report_preview += f"\n... [{len(r.report)} chars total]"
            lines.append(report_preview)
            if r.citations:
                lines.append(f"\nCitations: {len(r.citations)}")
        else:
            lines.append(f"Error: {r.error}")
        lines.append("")

    return "\n".join(lines)

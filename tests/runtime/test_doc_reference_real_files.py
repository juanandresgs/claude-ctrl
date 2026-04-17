"""Real-file pins for Invariant #8 hook-surface reference validation.

Asserts that the high-traffic docs ``MASTER_PLAN.md`` and ``AGENTS.md``
contain no drifted hook-surface references (ghost adapter paths, ghost
events, or retired event-matcher pairs) relative to HOOK_MANIFEST.

If this file fails, either:
  - the doc genuinely drifted (e.g. a retired hook was added back, or a
    matcher vocabulary was renamed), OR
  - the manifest was updated without bringing the doc along.

Fix: update whichever side is stale. Both are maintainers' responsibility;
this pin exists so the drift is caught at test time, not during a human
review pass months later.

@decision DEC-DOC-REF-VALIDATION-001 (see runtime.core.doc_reference_validation)
"""

from __future__ import annotations

from pathlib import Path

import pytest

from runtime.core.doc_reference_validation import validate_doc_references_file

REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize(
    "doc_path",
    [
        REPO_ROOT / "MASTER_PLAN.md",
        REPO_ROOT / "AGENTS.md",
    ],
)
def test_doc_has_no_hook_surface_drift(doc_path: Path):
    assert doc_path.is_file(), (
        f"Expected doc to exist: {doc_path}. Invariant #8 real-file pin "
        "covers MASTER_PLAN.md and AGENTS.md only; if one of those is "
        "renamed or removed, update this parametrization."
    )
    report = validate_doc_references_file(doc_path)
    # Produce a clear failure message naming the drift when present.
    assert report.healthy, (
        f"{doc_path.name} has hook-surface drift:\n"
        f"  unknown_adapters:  {report.unknown_adapters}\n"
        f"  unknown_events:    {report.unknown_events}\n"
        f"  unknown_matchers:  {report.unknown_matchers}\n"
        f"  references_checked: {report.references_checked}"
    )

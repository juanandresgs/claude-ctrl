"""Real-file pins for Invariant #8 hook-surface reference validation.

Asserts that core cutover + docs surfaces contain no drifted hook-surface
references (ghost adapter paths, ghost events, or retired event-matcher
pairs) relative to HOOK_MANIFEST + on-disk hook files + the retirement
registry in ``runtime.core.doc_reference_validation``.

First-wave coverage (DEC-DOC-REF-VALIDATION-001):
  - ``MASTER_PLAN.md``
  - ``AGENTS.md``

Second-wave coverage (DEC-DOC-REF-VALIDATION-002):
  - ``docs/ARCHITECTURE.md``
  - ``docs/DISPATCH.md``
  - ``docs/PLAN_DISCIPLINE.md``

If this file fails, either:
  - the doc genuinely drifted (e.g. a retired hook was added back, or a
    matcher vocabulary was renamed), OR
  - the manifest was updated without bringing the doc along, OR
  - a retirement happened without being recorded in the retirement
    registry (``RETIRED_ADAPTER_PATHS`` /  ``RETIRED_EVENT_MATCHERS``).

Fix: update whichever side is stale. The retirement registry IS the
single authority for documented retirements — never add a second
acceptance path; instead, extend the registry with a new retirement
record.

@decision DEC-DOC-REF-VALIDATION-001 (validator + MASTER_PLAN/AGENTS coverage)
@decision DEC-DOC-REF-VALIDATION-002 (expanded real-file coverage)
"""

from __future__ import annotations

from pathlib import Path

import pytest

from runtime.core.doc_reference_validation import validate_doc_references_file

REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize(
    "doc_path",
    [
        # First-wave coverage (DEC-DOC-REF-VALIDATION-001).
        REPO_ROOT / "MASTER_PLAN.md",
        REPO_ROOT / "AGENTS.md",
        REPO_ROOT / "docs" / "ARCHITECTURE.md",
        REPO_ROOT / "docs" / "DISPATCH.md",
        REPO_ROOT / "docs" / "PLAN_DISCIPLINE.md",
    ],
)
def test_doc_has_no_hook_surface_drift(doc_path: Path):
    assert doc_path.is_file(), (
        f"Expected doc to exist: {doc_path}. Invariant #8 real-file pin "
        "covers a fixed list of core cutover + docs surfaces; if one is "
        "renamed or removed, update the parametrization in this file."
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

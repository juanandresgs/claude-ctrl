"""enforcement_gap policy — deny writes when linter gap has been seen > 1 time.

Mirrors: hooks/lib/write-policy.sh lines 104-168 (check_enforcement_gap)

@decision DEC-ENFORCEMENT-GAPS-DB-001
Title: enforcement_gap reads structured state.db rows, not flatfiles
Status: accepted
Rationale: The shell version used grep on .claude/.enforcement-gaps. That made
  write authorization depend on a project-local text file outside the runtime
  authority. build_context now loads open enforcement_gaps rows from SQLite and
  this pure policy consumes that context.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import PATH_KIND_SOURCE, classify_policy_path


def enforcement_gap(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny source-file writes for extensions with a persistent enforcement gap.

    Enforcement gaps are loaded into request.context.enforcement_gaps from
    the SQLite enforcement_gaps table.

    Skip conditions (return None):
      - No file_path in tool_input
      - File is not a source file or is a skippable path
      - No extension on the file
      - No open DB gap exists for the extension
      - Gap count is <= 1 (first encounter may be transient)
    """
    file_path: str = request.tool_input.get("file_path", "")
    if not file_path:
        return None

    info = classify_policy_path(
        file_path,
        project_root=request.context.project_root or "",
        worktree_path=request.context.worktree_path or "",
        scratch_roots=request.context.scratchlane_roots,
    )
    if info.kind != PATH_KIND_SOURCE:
        return None

    ext = Path(file_path).suffix.lstrip(".")
    if not ext:
        return None

    for gap in request.context.enforcement_gaps:
        if str(gap.get("ext") or "") != ext:
            continue
        gap_type = str(gap.get("gap_type") or "")
        try:
            count = int(gap.get("encounter_count") or 0)
        except (TypeError, ValueError):
            continue
        if count <= 1:
            continue
        tool = str(gap.get("tool") or "")
        if gap_type == "unsupported":
            reason = (
                f"Write denied: unresolved enforcement gap for .{ext} files "
                f"(no linter profile). This gap has been encountered {count} times. "
                f"Add a linter config for .{ext} files to unblock writes."
            )
        else:
            reason = (
                f"Write denied: unresolved enforcement gap for .{ext} files "
                f"(linter '{tool}' not installed). "
                f"This gap has been encountered {count} times. "
                f"Install '{tool}' to unblock writes."
            )
        return PolicyDecision(
            action="deny",
            reason=reason,
            policy_name="enforcement_gap",
        )

    return None

"""enforcement_gap policy — deny writes when linter gap has been seen > 1 time.

Mirrors: hooks/lib/write-policy.sh lines 104-168 (check_enforcement_gap)

@decision DEC-PE-W2-003
Title: enforcement_gap reads .claude/.enforcement-gaps directly (no subprocess)
Status: accepted
Rationale: The shell version used grep on .claude/.enforcement-gaps. The Python
  port reads and parses the file directly (pipe-delimited format). No subprocess
  needed: the file is small and the parse is trivial. Priority 250 places this
  after branch_guard (100) and write_who (200) so WHO checks run first, but
  before plan checks (300+) so enforcement health takes precedence over plan
  staleness. This matches DEC-LINT-002 from the original shell annotation.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import PATH_KIND_SOURCE, classify_policy_path


def enforcement_gap(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny source-file writes for extensions with a persistent enforcement gap.

    An enforcement gap is recorded in {project_root}/.claude/.enforcement-gaps
    as pipe-delimited lines:
      {gap_type}|{ext}|{tool}|{timestamp}|{count}|...

    Skip conditions (return None):
      - No file_path in tool_input
      - File is not a source file or is a skippable path
      - No extension on the file
      - No gaps file exists
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

    project_root = request.context.project_root
    if not project_root:
        return None

    gaps_file = os.path.join(project_root, ".claude", ".enforcement-gaps")
    if not os.path.isfile(gaps_file):
        return None

    try:
        content = Path(gaps_file).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None

    for gap_type in ("unsupported", "missing_dep"):
        prefix = f"{gap_type}|{ext}|"
        for line in content.splitlines():
            if not line.startswith(prefix):
                continue
            parts = line.split("|")
            # Field 5 (0-indexed: index 4) is count
            if len(parts) < 5:
                continue
            try:
                count = int(parts[4])
            except ValueError:
                continue
            if count <= 1:
                continue
            tool = parts[2] if len(parts) > 2 else ""
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

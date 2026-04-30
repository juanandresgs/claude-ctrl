"""decision_log policy — decision log entries in MASTER_PLAN.md are append-only.

Mirrors: hooks/lib/plan-policy.sh lines 67-92 (check_decision_log_append_only)

@decision DEC-PE-W2-007
Title: decision_log delegates to planctl.py check-decision-log via subprocess
Status: accepted
Rationale: All decision-log enforcement logic lives in planctl.py (Python,
  fully tested). This policy is a thin bridge that mirrors plan_immutability's
  architecture: same precondition checks, call planctl check-decision-log,
  parse JSON, deny if append_only=false. Priority 600 places this after
  plan_immutability (500) so immutability fires first; both checks apply
  independently to MASTER_PLAN.md writes.
"""

from __future__ import annotations

import json
import os
import subprocess
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import PATH_KIND_GOVERNANCE, classify_policy_path


def decision_log(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny MASTER_PLAN.md writes that delete or reorder decision log entries.

    Skip conditions (return None):
      - file_path is not MASTER_PLAN.md
      - CLAUDE_PLAN_MIGRATION env var is "1"
      - planctl.py not found at {project_root}/scripts/planctl.py
      - .plan-baseline.json not found at project_root
      - The file does not yet exist on disk (first write)
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
    if info.kind != PATH_KIND_GOVERNANCE or info.repo_relative_path != "MASTER_PLAN.md":
        return None

    if os.environ.get("CLAUDE_PLAN_MIGRATION", "") == "1":
        return None

    project_root = request.context.project_root
    if not project_root:
        return None

    planctl = os.path.join(project_root, "scripts", "planctl.py")
    if not os.path.isfile(planctl):
        return None

    baseline = os.path.join(project_root, ".plan-baseline.json")
    if not os.path.isfile(baseline):
        return None

    if not os.path.isfile(file_path):
        return None

    try:
        r = subprocess.run(
            ["python3", planctl, "check-decision-log", file_path],
            capture_output=True,
            text=True,
            timeout=15,
        )
        result_text = r.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None

    if not result_text:
        return None

    try:
        data = json.loads(result_text)
    except json.JSONDecodeError:
        return None

    if data.get("append_only", True):
        return None

    violations = data.get("violations", [])
    reason = (
        violations[0].get("reason", "entries modified or reordered")
        if violations
        else "entries modified or reordered"
    )

    return PolicyDecision(
        action="deny",
        reason=f"Decision log violation: {reason}",
        policy_name="decision_log",
    )

"""plan_immutability policy — permanent sections of MASTER_PLAN.md may not be rewritten.

Mirrors: hooks/lib/plan-policy.sh lines 27-65 (check_plan_immutability)

@decision DEC-PE-W2-006
Title: plan_immutability delegates to planctl.py via subprocess
Status: accepted
Rationale: All immutability enforcement logic lives in planctl.py (Python,
  fully tested). This policy is a thin bridge: same precondition checks as the
  shell version, then call planctl check-immutability, parse its JSON, and
  return deny if immutable=false. This mirrors DEC-PLAN-002 (plan-policy.sh as
  thin shell bridge to planctl.py) — we preserve the same architecture in
  Python rather than reimplementing planctl logic here. Priority 500 places
  this after plan_exists (400) so the plan-existence gate fires first.
"""

from __future__ import annotations

import json
import os
import subprocess
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import PATH_KIND_GOVERNANCE, classify_policy_path


def plan_immutability(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny MASTER_PLAN.md writes that modify permanent (immutable) sections.

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

    # planctl.py needs the file to exist on disk; skip for first-write
    if not os.path.isfile(file_path):
        return None

    try:
        r = subprocess.run(
            ["python3", planctl, "check-immutability", file_path],
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

    # Use explicit conditional — .get("immutable", True) treats missing as safe
    if data.get("immutable", True):
        return None

    violations = data.get("violations", [])
    reason = (
        violations[0].get("reason", "permanent section modified")
        if violations
        else "permanent section modified"
    )

    return PolicyDecision(
        action="deny",
        reason=f"Plan immutability violation: {reason}",
        policy_name="plan_immutability",
    )

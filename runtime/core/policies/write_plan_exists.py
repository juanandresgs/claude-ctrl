"""plan_exists policy — MASTER_PLAN.md must exist for large source writes.

Mirrors: hooks/plan-check.sh (170 lines)

@decision DEC-PE-W2-005
Title: plan_exists ports get_plan_status() inline rather than shelling out
Status: accepted
Rationale: plan-check.sh calls get_plan_status() from context-lib.sh via
  shell sourcing. Porting the staleness heuristic inline avoids a subprocess
  round-trip on every Write hook. The logic is: count commits since the plan
  file was last modified, count source-file churn %, and apply tiered
  thresholds. Default thresholds match the shell: warn=15%, deny=35%,
  commit_warn=40, commit_deny=100. Environment overrides (PLAN_CHURN_WARN,
  PLAN_CHURN_DENY) are honoured so operators can tune without patching.
  Priority 400 places this after WHO checks and enforcement_gap so structural
  gates (branch, role, gap) fire before the plan-existence gate.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    SOURCE_EXTENSIONS,
    is_skippable_path,
    is_source_file,
)

# ---------------------------------------------------------------------------
# Plan staleness helpers (ported from context-lib.sh get_plan_status)
# ---------------------------------------------------------------------------

_SOURCE_EXT_PATTERN = "|".join(SOURCE_EXTENSIONS)


def _get_plan_staleness(project_root: str) -> dict:
    """Compute plan staleness metrics from git history.

    Returns a dict with keys:
      plan_exists        bool
      commits_since      int   — commits after plan file's mtime
      source_churn_pct   int   — % of tracked source files changed since plan
      diag_parts         list[str]

    Mirrors: hooks/context-lib.sh:70 get_plan_status()
    """
    result = {
        "plan_exists": False,
        "commits_since": 0,
        "source_churn_pct": 0,
        "diag_parts": [],
    }

    plan_path = os.path.join(project_root, "MASTER_PLAN.md")
    if not os.path.isfile(plan_path):
        return result
    result["plan_exists"] = True

    # Plan file modification time
    try:
        plan_mtime = int(os.stat(plan_path).st_mtime)
    except OSError:
        return result

    if plan_mtime <= 0:
        return result

    # Check if project_root is a git repo
    try:
        r = subprocess.run(
            ["git", "-C", project_root, "rev-parse", "--is-inside-work-tree"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if r.returncode != 0:
            return result
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return result

    # Format plan mtime as git-compatible date string
    import datetime

    try:
        plan_dt = datetime.datetime.fromtimestamp(plan_mtime)
        plan_date = plan_dt.strftime("%Y-%m-%d %H:%M:%S")
    except (OSError, ValueError, OverflowError):
        return result

    # Commits since plan update
    try:
        r = subprocess.run(
            ["git", "-C", project_root, "rev-list", "--count", f"--after={plan_date}", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            result["commits_since"] = int(r.stdout.strip() or "0")
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError, ValueError):
        pass

    # Source-file churn since plan update
    changed_source = 0
    try:
        r = subprocess.run(
            [
                "git",
                "-C",
                project_root,
                "log",
                f"--after={plan_date}",
                "--name-only",
                "--format=",
                "HEAD",
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if r.returncode == 0:
            seen: set[str] = set()
            for line in r.stdout.splitlines():
                line = line.strip()
                if not line or line in seen:
                    continue
                seen.add(line)
                ext = Path(line).suffix.lstrip(".")
                if ext in SOURCE_EXTENSIONS:
                    changed_source += 1
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass

    total_source = 0
    try:
        r = subprocess.run(
            ["git", "-C", project_root, "ls-files"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            for line in r.stdout.splitlines():
                ext = Path(line.strip()).suffix.lstrip(".")
                if ext in SOURCE_EXTENSIONS:
                    total_source += 1
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass

    if total_source > 0:
        result["source_churn_pct"] = (changed_source * 100) // total_source

    return result


# ---------------------------------------------------------------------------
# Policy function
# ---------------------------------------------------------------------------


def plan_exists(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny large source writes when MASTER_PLAN.md is absent or critically stale.

    Skip conditions (return None / feedback):
      - No file_path in tool_input
      - File is not a source file or is skippable
      - File is under {project_root}/.claude/
      - tool_name is "Edit" (inherently scoped — skip plan check)
      - tool_name is "Write" with content < 20 lines (fast-mode bypass)
      - project_root is not a git repo

    Deny conditions:
      - MASTER_PLAN.md does not exist
      - source_churn_pct >= PLAN_CHURN_DENY (default 35%)
      - commits_since >= 100

    Feedback conditions:
      - source_churn_pct >= PLAN_CHURN_WARN (default 15%) or commits_since >= 40
    """
    file_path: str = request.tool_input.get("file_path", "")
    if not file_path:
        return None

    if not is_source_file(file_path):
        return None
    if is_skippable_path(file_path):
        return None

    # Skip meta-infrastructure
    project_root = request.context.project_root
    if project_root and file_path.startswith(os.path.join(project_root, ".claude") + os.sep):
        return None

    # Edit tool is inherently scoped — skip plan check
    tool_name = request.tool_name
    if tool_name == "Edit":
        return None

    # Write tool: fast-mode bypass for small files
    if tool_name == "Write":
        content: str = request.tool_input.get("content", "")
        line_count = len(content.splitlines())
        if line_count < 20:
            return PolicyDecision(
                action="feedback",
                reason=(
                    f"Fast-mode bypass: small file write ({line_count} lines) "
                    "skipped plan check. Surface audit will track this."
                ),
                policy_name="plan_exists",
            )

    # Resolve project root from file path (fix #468 pattern)
    if not project_root:
        return None

    # Verify project is a git repo
    try:
        r = subprocess.run(
            ["git", "-C", project_root, "rev-parse", "--is-inside-work-tree"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if r.returncode != 0:
            return None
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None

    plan_path = os.path.join(project_root, "MASTER_PLAN.md")
    if not os.path.isfile(plan_path):
        return PolicyDecision(
            action="deny",
            reason=(
                f"BLOCKED: No MASTER_PLAN.md in {project_root}. "
                "Sacred Practice #6: We NEVER run straight into implementing anything.\n\n"
                "Action: Invoke the Planner agent to create MASTER_PLAN.md before implementing."
            ),
            policy_name="plan_exists",
        )

    # Plan staleness check
    churn_warn = int(os.environ.get("PLAN_CHURN_WARN", "15"))
    churn_deny = int(os.environ.get("PLAN_CHURN_DENY", "35"))

    staleness = _get_plan_staleness(project_root)
    churn_pct = staleness["source_churn_pct"]
    commits = staleness["commits_since"]

    # Compute tiers
    churn_tier = "ok"
    if churn_pct >= churn_deny:
        churn_tier = "deny"
    elif churn_pct >= churn_warn:
        churn_tier = "warn"

    drift_tier = "ok"
    if commits >= 100:
        drift_tier = "deny"
    elif commits >= 40:
        drift_tier = "warn"

    staleness_tier = "ok"
    if churn_tier == "deny" or drift_tier == "deny":
        staleness_tier = "deny"
    elif churn_tier == "warn" or drift_tier == "warn":
        staleness_tier = "warn"

    # Build diagnostic
    diag_parts = []
    if churn_tier != "ok":
        diag_parts.append(
            f"Source churn: {churn_pct}% of files changed (threshold: {churn_warn}%/{churn_deny}%)."
        )
    if drift_tier != "ok":
        diag_parts.append(f"Commit count: {commits} commits since plan update.")
    diagnostic = " ".join(diag_parts)

    if staleness_tier == "deny":
        return PolicyDecision(
            action="deny",
            reason=(
                f"MASTER_PLAN.md is critically stale. {diagnostic}"
                "Read MASTER_PLAN.md, scan the codebase for @decision annotations, "
                "and update the plan's phase statuses before continuing."
            ),
            policy_name="plan_exists",
        )

    if staleness_tier == "warn":
        return PolicyDecision(
            action="feedback",
            reason=(
                f"Plan staleness warning: {diagnostic}"
                "Consider reviewing MASTER_PLAN.md — it may not reflect the "
                "current codebase state."
            ),
            policy_name="plan_exists",
        )

    return None

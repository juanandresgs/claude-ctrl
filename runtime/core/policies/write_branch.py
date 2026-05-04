"""branch_guard policy — block source-file writes on main/master branch.

Mirrors: hooks/branch-guard.sh (79 lines)

@decision DEC-PE-W2-001
Title: branch_guard is a pure Python port of branch-guard.sh
Status: accepted
Rationale: branch-guard.sh is the highest-priority write-path control. It
  must fire before WHO checks so that branch protection takes precedence
  over role checks. Porting to Python lets the policy engine run all checks
  in one process rather than forking 7 shell scripts. The logic is identical:
  skip non-source / skippable / meta-infra files, resolve the git branch from
  the file's directory (not CWD), and deny if branch is main or master.
  Priority 100 matches the original position in the CHECKS list in pre-write.sh.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Optional

from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import PATH_KIND_SOURCE, classify_policy_path


def branch_guard(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny source-file writes when the file's git repo is on main/master.

    Skip conditions (return None):
      - No file_path in tool_input
      - File is under {project_root}/.claude/ (meta-infrastructure)
      - File is MASTER_PLAN.md
      - File is not a source file (is_source_file returns False)
      - File is a skippable path (vendor/build/generated)
      - File's directory is not inside a git repo
      - Current branch is not main or master
    """
    file_path: str = request.tool_input.get("file_path", "")
    if not file_path:
        return None

    # Skip meta-infrastructure (.claude/ subtree of project root)
    project_root = request.context.project_root
    if project_root and file_path.startswith(os.path.join(project_root, ".claude") + os.sep):
        return None

    info = classify_policy_path(
        file_path,
        project_root=project_root or "",
        worktree_path=request.context.worktree_path or "",
        scratch_roots=request.context.scratchlane_roots,
    )
    if info.kind != PATH_KIND_SOURCE:
        return None

    # Resolve the git repo from the file's directory (fix #468 pattern)
    file_dir = str(Path(file_path).parent)
    if not os.path.isdir(file_dir):
        file_dir = str(Path(file_dir).parent)

    try:
        r = subprocess.run(
            ["git", "-C", file_dir, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if r.returncode != 0:
            return None  # Not in a git repo — no opinion
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None

    # Resolve current branch via symbolic-ref (works pre-first-commit too)
    branch = ""
    try:
        r = subprocess.run(
            ["git", "-C", file_dir, "symbolic-ref", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if r.returncode == 0:
            branch = r.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass

    if not branch:
        try:
            r = subprocess.run(
                ["git", "-C", file_dir, "rev-parse", "--abbrev-ref", "HEAD"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if r.returncode == 0:
                branch = r.stdout.strip()
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass

    if branch not in ("main", "master"):
        return None

    return PolicyDecision(
        action="deny",
        reason=(
            f"BLOCKED: Cannot write source code on {branch} branch. "
            "Sacred Practice #2: Main is sacred.\n\n"
            "Action: Invoke the Guardian agent to create an isolated worktree for this work."
        ),
        policy_name="branch_guard",
    )

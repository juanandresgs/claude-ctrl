"""Policy: bash_main_sacred — deny non-landing commits directly on main/master.

Port of guard.sh lines 180-204 (Check 4).

@decision DEC-PE-W3-006
Title: bash_main_sacred enforces Sacred Practice #2 at the policy layer
Status: accepted
Rationale: Feature work must happen in worktrees, not on main. Direct commits
  to main/master break the branching model and make review impossible. Four
  exceptions are intentional:
    1. Meta-repo (/.claude): config edits by the orchestrator do not follow
       the implementer workflow path.
    2. MERGE_HEAD exists: this is a merge finalisation commit, governed by
       Check 3 (lease) and Check 10 (eval readiness). Check 4 should not
       block the finalization step.
    3. Only MASTER_PLAN.md is staged: planning document updates per Core Dogma
       may land directly on main.
    4. Guardian landing: a resolved guardian:land actor with CAN_LAND_GIT may
       make the final landing commit on main/master after the earlier lease
       gate and the later test/evaluation gates agree. Main remains sacred for
       feature work; Guardian landing is the canonical way changes reach main.
"""

from __future__ import annotations

import os
import subprocess
from typing import Optional

from runtime.core.authority_registry import CAN_LAND_GIT
from runtime.core.policy_engine import PolicyDecision, PolicyRequest


def _get_branch(target_dir: str) -> str:
    try:
        r = subprocess.run(
            ["git", "-C", target_dir, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if r.returncode == 0:
            return r.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return ""


def _merge_head_exists(target_dir: str) -> bool:
    return os.path.isfile(os.path.join(target_dir, ".git", "MERGE_HEAD"))


def _staged_files(target_dir: str) -> str:
    try:
        r = subprocess.run(
            ["git", "-C", target_dir, "diff", "--cached", "--name-only"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if r.returncode == 0:
            return r.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return ""


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny git commit when the worktree is on main/master.

    Exceptions (pass through with no opinion):
      - is_meta_repo is True
      - MERGE_HEAD exists in target_dir (merge finalisation commit)
      - Only MASTER_PLAN.md is staged
      - actor has CAN_LAND_GIT (guardian:land canonical landing)

    Source: guard.sh lines 180-204 (Check 4).
    """
    intent = request.command_intent
    if intent is None:
        return None

    commit_invocations = [
        op.invocation for op in intent.git_operations if op.invocation.subcommand == "commit"
    ]
    if not commit_invocations:
        return None

    # Meta-repo bypass.
    if request.context.is_meta_repo:
        return None

    # Fix #175: use the project_root already resolved by cli.py (_handle_evaluate)
    # from target_cwd, rather than re-parsing the raw command with
    # extract_git_target_dir(). Re-parsing fails on unexpanded shell variables
    # and is redundant now that effective_cwd flows through to PolicyRequest.cwd.
    # _merge_head_exists() needs the repo root (.git/ lives there), which is
    # exactly what context.project_root provides.
    target_dir = request.context.project_root or intent.target_cwd or request.cwd or ""
    if not target_dir:
        return None

    branch = _get_branch(target_dir)
    if branch not in ("main", "master"):
        return None

    # Exception: Guardian landing. bash_git_who already proved lease ownership
    # and CAN_LAND_GIT before this policy runs; bash_test_gate and
    # bash_eval_readiness still run after this policy. This exception keeps the
    # canonical path ergonomic while preserving gates around the final commit.
    if CAN_LAND_GIT in request.context.capabilities:
        return None

    # Exception: merge finalisation commit.
    if _merge_head_exists(target_dir):
        return None

    # Exception: only MASTER_PLAN.md staged.
    staged = _staged_files(target_dir)
    if staged == "MASTER_PLAN.md":
        return None

    return PolicyDecision(
        action="deny",
        reason=(
            f"Cannot commit directly to {branch}. Sacred Practice #2: Main is sacred. "
            "Do feature work in a Guardian-provisioned worktree, then route final "
            "landing through guardian:land after review and passing tests."
        ),
        policy_name="bash_main_sacred",
    )


def register(registry) -> None:
    """Register bash_main_sacred into the given PolicyRegistry."""
    registry.register(
        "bash_main_sacred",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=400,
    )

"""Policy: bash_eval_readiness — gate commit/merge on evaluation_state.

Port of guard.sh lines 285-366 (Check 10).

@decision DEC-PE-W3-009
Title: bash_eval_readiness uses context.eval_state as the sole readiness authority
Status: accepted
Rationale: guard.sh Check 10 reads evaluation_state from SQLite via
  read_evaluation_status/read_evaluation_state. build_context() has already
  loaded eval_state (for the resolved workflow_id) into PolicyContext. This
  policy consumes that pre-loaded state — pure function, no I/O.

  Workflow ID resolution order (mirrors guard.sh Check 10 exactly):
    1. Lease workflow_id (when a lease is active) — authoritative identity.
    2. For merge: extract_merge_ref → sanitize_token the ref name.
    3. Fallback: current_workflow_id derived from branch/project basename.

  SHA comparison: accept prefix match (short SHA stored vs full SHA from git,
  or vice versa). This matches guard.sh's grep-based prefix check.

  Admin recovery (merge --abort, reset --merge) is exempt — these are
  governed recovery operations with no "feature" to evaluate.

  The SHA comparison for merge operations uses the merge_ref tip (the branch
  being merged), not main's HEAD. The evaluator cleared the feature branch,
  not main.
"""

from __future__ import annotations

import subprocess
from typing import Optional

from runtime.core.leases import GitInvocation
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    current_workflow_id,
    extract_merge_ref,
    sanitize_token,
)


def _git_rev_parse(target_dir: str, ref: str) -> str:
    try:
        r = subprocess.run(
            ["git", "-C", target_dir, "rev-parse", ref],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if r.returncode == 0:
            return r.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return ""


def _sha_prefix_match(sha_a: str, sha_b: str) -> bool:
    """True if one SHA is a prefix of the other (short vs full SHA comparison)."""
    if not sha_a or not sha_b:
        return False
    return sha_b.startswith(sha_a) or sha_a.startswith(sha_b)


def _resolve_workflow_id(
    request: PolicyRequest, invocation: GitInvocation, target_dir: str
) -> str:
    """Resolve workflow_id using lease-first then branch-derived fallback."""
    lease = request.context.lease
    if lease:
        wf = lease.get("workflow_id", "")
        if wf:
            return wf

    # For merge: try to derive from the merge ref
    if invocation.subcommand == "merge":
        merge_ref = extract_merge_ref(" ".join(invocation.argv))
        if merge_ref:
            return sanitize_token(merge_ref)

    return current_workflow_id(target_dir)


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Gate git commit/merge on evaluation_state == ready_for_guardian with SHA match.

    Source: guard.sh lines 285-366 (Check 10).
    """
    intent = request.command_intent
    if intent is None:
        return None

    invocation = intent.git_invocation
    if invocation is None or invocation.subcommand not in ("commit", "merge"):
        return None

    # Admin recovery exemption.
    if invocation.subcommand == "merge" and "--abort" in invocation.args:
        return None

    # Meta-repo bypass.
    if request.context.is_meta_repo:
        return None

    # Determine target dir.
    # Fix #175: on the commit path, use the project_root already resolved by
    # cli.py (_handle_evaluate) from target_cwd. Re-parsing the raw command
    # with extract_git_target_dir() was the workaround for the missing
    # effective_cwd propagation; now that request.cwd IS the effective target
    # directory, context.project_root (resolved from it) is authoritative.
    # The merge path is unchanged — it uses extract_merge_ref() for merge
    # semantics and project_root/cwd for the directory.
    target_dir = request.context.project_root or intent.target_cwd or request.cwd or ""

    workflow_id = _resolve_workflow_id(request, invocation, target_dir)

    # Check evaluation state — use context (already loaded for resolved workflow_id).
    eval_state = request.context.eval_state
    eval_status = eval_state.get("status", "unknown") if eval_state else "not_found"

    if eval_status != "ready_for_guardian":
        return PolicyDecision(
            action="deny",
            reason=(
                f"Cannot proceed: evaluation_state for workflow '{workflow_id}' "
                f"is '{eval_status}'. The tester must emit "
                "EVAL_VERDICT=ready_for_guardian before local landing can proceed."
            ),
            policy_name="bash_eval_readiness",
        )

    # SHA comparison: stored head_sha vs. relevant HEAD.
    stored_sha = eval_state.get("head_sha", "") if eval_state else ""

    is_merge = invocation.subcommand == "merge"
    merge_ref = extract_merge_ref(" ".join(invocation.argv)) if is_merge else None

    if is_merge and merge_ref:
        compare_head = _git_rev_parse(target_dir, merge_ref)
        sha_label = f"merge-ref ({merge_ref})"
    else:
        compare_head = _git_rev_parse(target_dir, "HEAD")
        sha_label = "HEAD"

    if stored_sha and compare_head:
        if not _sha_prefix_match(stored_sha, compare_head):
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Cannot proceed: evaluation_state head_sha '{stored_sha}' "
                    f"does not match {sha_label} '{compare_head}'. "
                    "Source changes after evaluator clearance require a new tester pass."
                ),
                policy_name="bash_eval_readiness",
            )

    return None


def register(registry) -> None:
    """Register bash_eval_readiness into the given PolicyRegistry."""
    registry.register(
        "bash_eval_readiness",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=900,
    )

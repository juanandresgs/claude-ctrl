"""Policy: bash_eval_readiness — gate commit/merge on v6 landing readiness.

Port of guard.sh lines 285-366 (Check 10), upgraded for v6.

@decision DEC-V6-LANDING-001
Title: v6_landing_readiness is the sole Guardian landing readiness authority
Status: accepted
Rationale: evaluation_state, test_state, scope, leases, and reviewer results are
  evidence sources, not separate landing authorities. v6 collapses them into one
  v6_landing_readiness row keyed by guardian:land stage_run_id. This policy
  consumes that pre-loaded aggregate from PolicyContext and denies commit/merge
  unless it is ready and HEAD-aligned.

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

import json
import subprocess
from typing import Optional

from runtime.core.leases import GitInvocation
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policies.fast_path import guarded_non_source_commit
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
    """Strict SHA comparison: full match, or >=12-char unambiguous prefix."""
    sha_a = str(sha_a or "")
    sha_b = str(sha_b or "")
    if not sha_a or not sha_b:
        return False
    if len(sha_a) == 40 and len(sha_b) == 40:
        return sha_a.lower() == sha_b.lower()
    if min(len(sha_a), len(sha_b)) < 12:
        return False
    return sha_b.lower().startswith(sha_a.lower()) or sha_a.lower().startswith(sha_b.lower())


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

    if guarded_non_source_commit(request).eligible:
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

    readiness = getattr(request.context, "landing_readiness", None)
    readiness_status = readiness.get("status", "not_found") if readiness else "not_found"
    if readiness_status != "ready":
        missing = []
        if readiness:
            raw_missing = readiness.get("missing") or readiness.get("missing_json") or []
            if isinstance(raw_missing, str):
                try:
                    parsed = json.loads(raw_missing)
                    missing = parsed if isinstance(parsed, list) else []
                except (TypeError, json.JSONDecodeError):
                    missing = [raw_missing] if raw_missing else []
            elif isinstance(raw_missing, list):
                missing = raw_missing
        missing_text = f" missing={missing}." if missing else ""
        return PolicyDecision(
            action="deny",
            reason=(
                f"Cannot proceed: v6_landing_readiness for workflow '{workflow_id}' "
                f"is '{readiness_status}'.{missing_text} Run reviewer -> guardian:land readiness aggregation first."
            ),
            policy_name="bash_eval_readiness",
        )

    # SHA comparison: readiness head_sha vs. relevant HEAD.
    stored_sha = readiness.get("head_sha", "") if readiness else ""

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
                    f"Cannot proceed: v6_landing_readiness head_sha '{stored_sha}' "
                    f"does not match {sha_label} '{compare_head}'. "
                    "Source changes after reviewer clearance require a new reviewer pass."
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

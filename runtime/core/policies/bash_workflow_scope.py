"""Policy: bash_workflow_scope — enforce workflow binding + scope on commit/merge.

Port of guard.sh lines 368-422 (Check 12).

@decision DEC-PE-W3-010
Title: bash_workflow_scope uses context.binding and context.scope as sole authorities
Status: accepted
Rationale: guard.sh Check 12 queries the DB for binding and scope, then runs
  git diff to get changed files, then calls rt_workflow_scope_check.
  build_context() has already loaded binding and scope into PolicyContext.
  The changed-file list still requires a git subprocess (it is dynamic, not
  pre-loaded) but is the only I/O this policy performs.

  check_scope_compliance() from workflows.py requires a DB connection — we
  cannot call it in a pure policy function. Instead we replicate the matching
  logic inline using the scope data already loaded into context.scope. This
  avoids introducing a conn dependency into the policy layer. The logic is
  simple enough (fnmatch + forbidden-first) to duplicate safely.

  If either binding or scope is missing, we deny with guidance. This mirrors
  guard.sh sub-checks A and B before the compliance check.
"""

from __future__ import annotations

import fnmatch
import subprocess
from typing import Optional

from runtime.core.leases import GitInvocation
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import (
    current_workflow_id,
    extract_merge_ref,
    sanitize_token,
)


def _resolve_workflow_id(
    request: PolicyRequest, invocation: GitInvocation, target_dir: str
) -> str:
    lease = request.context.lease
    if lease:
        wf = lease.get("workflow_id", "")
        if wf:
            return wf
    # Merge: try the merge ref
    if invocation.subcommand == "merge":
        merge_ref = extract_merge_ref(" ".join(invocation.argv))
        if merge_ref:
            return sanitize_token(merge_ref)
    return current_workflow_id(target_dir)


def _get_changed_files(target_dir: str, base_branch: str) -> list[str]:
    try:
        r = subprocess.run(
            ["git", "-C", target_dir, "diff", "--name-only", f"{base_branch}...HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            return [f for f in r.stdout.strip().splitlines() if f]
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return []


def _check_compliance(scope: dict, changed_files: list[str]) -> tuple[bool, list[str]]:
    """Replicate workflows.check_scope_compliance logic using pre-loaded scope dict.

    Returns (compliant, violations_list).
    forbidden_paths take strict precedence per DEC-WF-002.
    """
    import json

    def _parse_list(val) -> list[str]:
        if isinstance(val, list):
            return val
        if isinstance(val, str):
            try:
                parsed = json.loads(val)
                return parsed if isinstance(parsed, list) else []
            except (json.JSONDecodeError, TypeError):
                return []
        return []

    allowed = _parse_list(scope.get("allowed_paths", []))
    forbidden = _parse_list(scope.get("forbidden_paths", []))

    violations: list[str] = []
    for f in changed_files:
        if any(fnmatch.fnmatch(f, pat) for pat in forbidden):
            violations.append(f"FORBIDDEN: {f}")
            continue
        if allowed and not any(fnmatch.fnmatch(f, pat) for pat in allowed):
            violations.append(f"OUT_OF_SCOPE: {f}")

    return len(violations) == 0, violations


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny git commit/merge when workflow binding or scope is missing,
    or when changed files violate the scope manifest.

    Sub-checks:
      A. Binding must exist.
      B. Scope must exist.
      C. Changed files must comply with scope.

    Source: guard.sh lines 368-422 (Check 12).
    """
    intent = request.command_intent
    if intent is None:
        return None

    invocation = intent.git_invocation
    if invocation is None or invocation.subcommand not in ("commit", "merge"):
        return None

    # Meta-repo bypass.
    if request.context.is_meta_repo:
        return None

    target_dir = request.context.project_root or intent.target_cwd or request.cwd or ""
    workflow_id = _resolve_workflow_id(request, invocation, target_dir)

    # Sub-check A: binding must exist.
    if not request.context.binding:
        return PolicyDecision(
            action="deny",
            reason=(
                f"No workflow binding for '{workflow_id}'. "
                f"Bind workflow before committing: "
                f"cc-policy workflow bind {workflow_id} <worktree_path> <branch>"
            ),
            policy_name="bash_workflow_scope",
        )

    # Sub-check B: scope must exist.
    if not request.context.scope:
        return PolicyDecision(
            action="deny",
            reason=(
                f"No scope manifest for workflow '{workflow_id}'. "
                f"Set scope before committing: "
                f"cc-policy workflow scope-set {workflow_id} "
                f"--allowed '[...]' --forbidden '[...]'"
            ),
            policy_name="bash_workflow_scope",
        )

    # Sub-check C: changed files must comply with scope.
    # Fix #175: on the commit path, use project_root already resolved by
    # cli.py from target_cwd. The if/else distinction between commit and merge
    # is no longer needed — both paths resolve to the same source of truth.
    # Merge path is preserved as-is (project_root or cwd) since it was already
    # correct; the commit path now matches it rather than re-parsing the command.
    base_branch = request.context.binding.get("base_branch", "main") or "main"
    changed_files = _get_changed_files(target_dir, base_branch)

    if changed_files:
        compliant, violations = _check_compliance(request.context.scope, changed_files)
        if not compliant:
            viols_str = ", ".join(violations)
            return PolicyDecision(
                action="deny",
                reason=(
                    f"Scope violation for workflow '{workflow_id}'. "
                    f"Unauthorized files changed: {viols_str}"
                ),
                policy_name="bash_workflow_scope",
            )

    return None


def register(registry) -> None:
    """Register bash_workflow_scope into the given PolicyRegistry."""
    registry.register(
        "bash_workflow_scope",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=1000,
    )

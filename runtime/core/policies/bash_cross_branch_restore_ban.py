"""Policy: bash_cross_branch_restore_ban — deny cross-branch git restore/checkout
for can_write_source actors when the target path is outside the active workflow scope.

Capability-gated on CAN_WRITE_SOURCE (implementer role). Non-implementer actors
are not subject to this policy — return None so other policies can proceed.

Background (DEC-DISCIPLINE-NONSTASH-RESTORE-BAN-001):
  In slice 7 of the global-soak lane, a `git checkout origin/main -- CLAUDE.md`
  materialised content from a different branch into the implementer's worktree,
  contaminating 11 files (CLAUDE.md, hooks/*, runtime/*, tests/*) from a ref
  that was not the active workflow branch. This is the non-stash contamination
  vector — distinct from the stash-pop vector closed by bash_stash_ban (slice 6).

  Banned patterns:
    git checkout <ref> -- <pathspec>  (cross-branch file extraction)
    git restore --source=<ref> ...    (explicit cross-ref restore)
    git restore --source=<worktree>   (cross-worktree restore)

  Allowed patterns:
    git checkout <branch>            (branch switch, no --)
    git checkout -- <pathspec>       (HEAD/index restore, no ref)
    git restore -- <pathspec>        (index/HEAD restore, no --source)
    git restore --source=HEAD ...    (same-HEAD restore)

Parsing note: all sub-command classification is driven exclusively by
  `request.command_intent.git_invocation` (pre-parsed, Rule B compliant).
  Raw command string access for .split() is forbidden by Rule B of the
  command-intent single-authority contract.

Exemption design:
  Supervisor-authorized Option B recovery is performed by guardian, which does
  NOT carry CAN_WRITE_SOURCE. The capability gate alone is the exemption
  mechanism — no allowlist string is needed (mirrors bash_stash_ban design).
  If context.scope is None (no active workflow scope row), this policy is a
  no-op — it must not break general git ops outside ClauDEX workflows.

@decision DEC-DISCIPLINE-NONSTASH-RESTORE-BAN-001
Title: bash_cross_branch_restore_ban is the sole enforcement authority for
  cross-branch/cross-worktree git-command contamination on CAN_WRITE_SOURCE actors.
Status: accepted
Rationale: bash_stash_ban (priority 625, slice 6) closes the stash-pop vector.
  This policy closes the non-stash vector: git checkout <ref> -- <path> and
  git restore --source=<ref> -- <path>. A separate module is required because:
  (a) bash_stash_ban is narrowly scoped to git stash sub-ops by name and audit
      contract; folding restore/checkout would violate its single-authority
      docstring;
  (b) bash_workflow_scope fires at commit/merge time on the staged index —
      by then the worktree has already been contaminated;
  (c) one-authority-per-vector is the established codebase pattern.
  Priority 630: between bash_stash_ban (625) and bash_worktree_removal (700).
  Capability-gated on CAN_WRITE_SOURCE, not actor_role string.
  Sub-command extraction uses request.command_intent.git_invocation exclusively.
  Integration note: This policy does not fire on cherry-pick/merge (distinct
  subcommands) or on bash_write_who events (shell write vectors). See risk
  register entry 3 in tmp/slice8-plan.md for double-fire analysis.
"""

from __future__ import annotations

import fnmatch
import os
from typing import Optional

from runtime.core.authority_registry import CAN_WRITE_SOURCE
from runtime.core.policy_engine import PolicyDecision, PolicyRequest
from runtime.core.policy_utils import parse_scope_list

# Module-level alias — delegates to canonical single-authority parser.
# @decision DEC-DISCIPLINE-SCOPE-PARSER-SINGLE-AUTH-001
_parse_scope_list = parse_scope_list

# ---------------------------------------------------------------------------
# Sub-command sets
# ---------------------------------------------------------------------------

# Git subcommands that can extract file content from a ref into the worktree
# when combined with a source ref argument.
_RESTORE_SUBCOMMANDS: frozenset[str] = frozenset({"checkout", "restore"})


def _is_path_forbidden(
    path: str,
    forbidden_patterns: list[str],
    allowed_patterns: list[str],
) -> bool:
    """Return True if path matches any forbidden_pattern and no allowed_pattern.

    Path is matched as-is (already repo-relative or basename from git invocation).
    fnmatch is used for glob semantics (mirrors bash_workflow_scope convention).
    allowed_patterns checked first — explicit allow beats forbidden glob.
    If forbidden_patterns is empty, always return False (conservative: no-op).
    """
    if not forbidden_patterns:
        return False
    # Explicit allow beats forbidden glob
    for pat in allowed_patterns:
        if fnmatch.fnmatch(path, pat):
            return False
    for pat in forbidden_patterns:
        if fnmatch.fnmatch(path, pat):
            return True
    return False


def _extract_scope_patterns(scope: object) -> tuple[list[str], list[str]]:
    """Extract (forbidden_paths, allowed_paths) from a scope dict.

    Returns ([], []) when scope is None, empty, or malformed — conservative.
    """
    if not isinstance(scope, dict):
        return [], []
    forbidden = _parse_scope_list(scope.get("forbidden_paths", []))
    allowed = _parse_scope_list(scope.get("allowed_paths", []))
    return forbidden, allowed


# ---------------------------------------------------------------------------
# Checkout sub-command parsing
# ---------------------------------------------------------------------------


def _parse_checkout_args(
    args: tuple[str, ...],
) -> tuple[Optional[str], list[str]]:
    """Parse `git checkout` args into (ref, pathspecs).

    Patterns:
      git checkout <ref> -- <path...>   → (ref, [path...])
      git checkout -- <path...>          → (None, [path...])  # HEAD restore
      git checkout <branch>              → (None, [])          # branch switch

    Returns (ref, pathspecs):
      - ref is None if no ref present (HEAD restore or branch switch)
      - pathspecs is [] if not a file-extraction invocation
    """
    # Look for '--' separator
    try:
        sep_idx = list(args).index("--")
    except ValueError:
        # No '--': this is a branch switch (git checkout <branch>)
        return None, []

    # Everything before '--' that is not a flag is the ref
    before_sep = [a for a in args[:sep_idx] if not a.startswith("-")]
    pathspecs = list(args[sep_idx + 1 :])

    ref = before_sep[-1] if before_sep else None
    return ref, pathspecs


# ---------------------------------------------------------------------------
# Restore sub-command parsing
# ---------------------------------------------------------------------------


def _parse_restore_args(
    args: tuple[str, ...],
) -> tuple[Optional[str], list[str]]:
    """Parse `git restore` args into (source_ref, pathspecs).

    Patterns:
      git restore --source=<ref> -- <path>   → (<ref>, [<path>])
      git restore --source <ref> -- <path>   → (<ref>, [<path>])
      git restore -- <path>                  → (None, [<path>])  # index/HEAD restore
      git restore <path>                     → (None, [<path>])  # index restore

    Returns (source_ref, pathspecs):
      - source_ref is None if no --source= flag
      - pathspecs is [] only when no paths at all (bare restore, very unusual)
    """
    source_ref: Optional[str] = None
    pathspecs: list[str] = []

    i = 0
    arg_list = list(args)
    while i < len(arg_list):
        token = arg_list[i]
        if token == "--":
            # Everything after '--' is a pathspec
            pathspecs.extend(arg_list[i + 1 :])
            break
        if token.startswith("--source="):
            source_ref = token[len("--source="):]
        elif token in ("--source", "-s") and i + 1 < len(arg_list):
            i += 1
            source_ref = arg_list[i]
        elif not token.startswith("-"):
            # Non-flag token before '--': positional pathspec
            pathspecs.append(token)
        i += 1

    return source_ref, pathspecs


# ---------------------------------------------------------------------------
# Main policy check
# ---------------------------------------------------------------------------


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny cross-branch restore/checkout when actor carries CAN_WRITE_SOURCE
    and target paths match the active workflow's forbidden_paths (or the source
    ref is outside the workflow scope).

    Logic:
      1. If CAN_WRITE_SOURCE not in capabilities: return None (not our gate).
      2. Require git_invocation via command_intent (Rule B: no raw .split()).
         If command_intent or git_invocation is absent: return None (not a git op).
      3. If subcommand not in {"checkout", "restore"}: return None.
      4. If context.scope is None: return None (conservative; no-op outside ClauDEX workflows).
      5. Extract (source_ref, pathspecs) per subcommand.
      6. For checkout: deny if ref is present AND any pathspec matches forbidden_paths.
         (ref present = cross-branch extraction, distinct from branch switch)
      7. For restore: deny if --source= is present AND source is not HEAD AND
         any pathspec matches forbidden_paths OR source resolves outside worktree.
      8. Otherwise: return None (allow).
    """
    # Gate 1: only apply to CAN_WRITE_SOURCE actors (implementers).
    if CAN_WRITE_SOURCE not in request.context.capabilities:
        return None

    # Gate 2: require pre-parsed git invocation (Rule B compliant — no raw split).
    intent = request.command_intent
    if intent is None or not intent.git_invocations:
        return None

    invocation = next(
        (
            candidate
            for candidate in intent.git_invocations
            if candidate.subcommand in _RESTORE_SUBCOMMANDS
        ),
        None,
    )
    if invocation is None:
        return None

    # Gate 4: conservative exemption — no scope seated → policy is a no-op.
    # This protects ad-hoc implementer sessions where no workflow scope row was
    # written. A follow-on governance slice can later require scope-mandatory.
    scope = request.context.scope
    if scope is None:
        return None

    forbidden_patterns, allowed_patterns = _extract_scope_patterns(scope)
    # No forbidden patterns in scope → nothing to enforce.
    if not forbidden_patterns:
        return None

    # Gate 5-8: dispatch to subcommand-specific parser.
    if invocation.subcommand == "checkout":
        return _check_checkout(request, invocation.args, forbidden_patterns, allowed_patterns)
    else:  # restore
        return _check_restore(request, invocation.args, forbidden_patterns, allowed_patterns)


def _check_checkout(
    request: PolicyRequest,
    args: tuple[str, ...],
    forbidden_patterns: list[str],
    allowed_patterns: list[str],
) -> Optional[PolicyDecision]:
    """Evaluate a git checkout invocation.

    Deny only when a source ref is present AND at least one pathspec matches
    forbidden_patterns. A branch switch (no '--') and a HEAD restore (no ref
    before '--') are both allowed.
    """
    ref, pathspecs = _parse_checkout_args(args)

    if ref is None:
        # No ref → branch switch or HEAD restore → allow.
        return None

    if not pathspecs:
        # Ref present but no pathspecs → unusual but not a contamination vector.
        return None

    # Ref is present → this is a cross-branch file extraction.
    forbidden_targets = [
        p for p in pathspecs if _is_path_forbidden(p, forbidden_patterns, allowed_patterns)
    ]
    if not forbidden_targets:
        return None

    workflow_id = request.context.workflow_id or "<unknown>"
    return PolicyDecision(
        action="deny",
        reason=(
            f"Implementer cannot run `git checkout {ref} -- {' '.join(pathspecs)}` — "
            f"this cross-branch file extraction materialises content from ref {ref!r} "
            f"into the worktree, bypassing workflow scope discipline. "
            f"Forbidden targets: {forbidden_targets!r}. "
            f"This vector caused the slice 7 contamination scenario "
            f"(11 files drawn from origin/main). "
            f"Workflow {workflow_id!r} forbids writes to these paths. "
            f"(bash_cross_branch_restore_ban, capability-gated on can_write_source)"
        ),
        policy_name="bash_cross_branch_restore_ban",
    )


def _check_restore(
    request: PolicyRequest,
    args: tuple[str, ...],
    forbidden_patterns: list[str],
    allowed_patterns: list[str],
) -> Optional[PolicyDecision]:
    """Evaluate a git restore invocation.

    Deny when --source=<ref> is present AND source is not HEAD (or HEAD-equivalent)
    AND at least one pathspec matches forbidden_patterns.

    Also deny when --source resolves to a path (worktree path) — any absolute
    path or relative path that looks like a filesystem directory is treated as
    a cross-worktree source and is categorically denied.
    """
    source_ref, pathspecs = _parse_restore_args(args)

    if source_ref is None:
        # No --source → restores from index/HEAD → allow.
        return None

    # HEAD-equivalent sources: allow (restoring from the current HEAD is safe).
    _HEAD_EQUIVALENTS: frozenset[str] = frozenset({"HEAD", "HEAD~0", "@"})
    if source_ref in _HEAD_EQUIVALENTS:
        return None

    # Absolute path → worktree/filesystem source → deny unconditionally.
    is_filesystem_source = os.path.isabs(source_ref) or source_ref.startswith("./") or source_ref.startswith("../")

    if not pathspecs and not is_filesystem_source:
        # No pathspecs and not a filesystem source → unusual, allow (no contamination vector).
        return None

    if is_filesystem_source:
        # Cross-worktree restore — deny even without forbidden_paths match.
        workflow_id = request.context.workflow_id or "<unknown>"
        return PolicyDecision(
            action="deny",
            reason=(
                f"Implementer cannot run `git restore --source={source_ref!r} ...` — "
                f"the source is a filesystem path (worktree reference), which can "
                f"materialise content from another worktree into the current one, "
                f"violating scope discipline for workflow {workflow_id!r}. "
                f"(bash_cross_branch_restore_ban, capability-gated on can_write_source)"
            ),
            policy_name="bash_cross_branch_restore_ban",
        )

    # Ref source with pathspecs → check forbidden patterns.
    forbidden_targets = [
        p for p in pathspecs if _is_path_forbidden(p, forbidden_patterns, allowed_patterns)
    ]
    if not forbidden_targets:
        return None

    workflow_id = request.context.workflow_id or "<unknown>"
    return PolicyDecision(
        action="deny",
        reason=(
            f"Implementer cannot run `git restore --source={source_ref!r} ...` — "
            f"this cross-ref restore materialises content from {source_ref!r} "
            f"into the worktree, bypassing workflow scope discipline. "
            f"Forbidden targets: {forbidden_targets!r}. "
            f"This vector caused the slice 7 contamination scenario "
            f"(11 files drawn from a foreign ref). "
            f"Workflow {workflow_id!r} forbids writes to these paths. "
            f"(bash_cross_branch_restore_ban, capability-gated on can_write_source)"
        ),
        policy_name="bash_cross_branch_restore_ban",
    )


def register(registry) -> None:
    """Register bash_cross_branch_restore_ban into the given PolicyRegistry.

    Priority 630: between bash_stash_ban (625) and bash_worktree_removal (700).
    Fires after bash_stash_ban has cleared the stash-pop vector but before
    the worktree guard sweep. This ordering ensures both contamination vectors
    are evaluated in ascending severity within the same priority band.
    """
    registry.register(
        "bash_cross_branch_restore_ban",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=630,
    )

"""Dispatch lease lifecycle authority.

@decision DEC-LEASE-001
Title: SQLite-backed dispatch leases bind agent identity to worktree + allowed ops
Status: accepted
Rationale: Subagents today rediscover identity from ambient state (markers, CWD
  inference). This produces wasted turns, partial completions treated as done,
  and no deterministic enforcement. A runtime-issued lease ties the agent role,
  worktree, workflow, allowed operations, and evaluation requirements into one
  durable record at dispatch time. validate_op() then gates git operations
  against the active lease rather than re-inferring from environment variables.

  Uniqueness invariants:
    - One active lease per worktree_path: issuing a new one revokes the old.
    - One active lease per agent_id: claiming revokes any other active lease
      held by the same agent (agents do not hold multiple leases).

  Lifecycle: active → released (normal completion) | revoked (superseded) |
             expired (TTL elapsed, detected by expire_stale).

  validate_op() never consumes approval tokens — it only peeks via list_pending
  for the remaining approval-gated operations. guard.sh Check 13 owns actual
  token consumption. This separation ensures validate_op is safe to call
  repeatedly without side effects.

  classify_git_op() is the sole Python-side git-command classifier. It is the
  migration target for the bash classifier in guard.sh Check 3. When hook
  wiring lands (Phase 2), guard.sh Check 3 will call this via cc-policy
  lease validate-op rather than inline bash regex.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
import re
import shlex
import sqlite3
import time
import uuid
from typing import Optional

from runtime.core.policy_utils import normalize_path  # DEC-CONV-001
from runtime.schemas import DEFAULT_LEASE_TTL

# ---------------------------------------------------------------------------
# Role-safe defaults
# ---------------------------------------------------------------------------

# @decision DEC-LEASE-003
# Title: ROLE_DEFAULTS is the single source of per-role allowed_ops and requires_eval defaults
# Status: accepted
# Rationale: Callers of issue() should not need to know what ops each role needs.
#   ROLE_DEFAULTS encodes the role→ops mapping in one place. Unknown roles fall
#   back to ["routine_local"] for safety. Explicit allowed_ops parameter overrides
#   the defaults when the caller has a reason.

ROLE_DEFAULTS: dict[str, dict] = {
    "implementer": {"allowed_ops": ["routine_local"], "requires_eval": True},
    "guardian": {
        "allowed_ops": ["routine_local", "high_risk", "admin_recovery"],
        "requires_eval": True,
    },
    "planner": {"allowed_ops": [], "requires_eval": False},
    "reviewer": {"allowed_ops": [], "requires_eval": False},
}
# Note: the legacy "tester" role was retired in Phase 8 Slice 11 (Tester
# Bundle 2). It is no longer a known role; unknown roles fall back to
# ["routine_local"] per issue()'s default branch.


# ---------------------------------------------------------------------------
# Classifier
# ---------------------------------------------------------------------------


_ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
_SHELL_SEPARATORS = frozenset({";", "&&", "||", "|", "&"})
_PASSTHROUGH_WRAPPERS = frozenset({"command", "builtin", "nohup", "time"})
_SHELL_WRAPPERS = frozenset({"sh", "bash", "zsh"})
_COMMAND_SUB_GIT_PREFIX_RE = re.compile(r"^(?:[A-Za-z_][A-Za-z0-9_]*=)?(?:\$\(|`)\s*git$")
_HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_.-]*)\1")
_GIT_GLOBAL_OPTS_WITH_VALUE = frozenset(
    {
        "-C",
        "-c",
        "--exec-path",
        "--git-dir",
        "--work-tree",
        "--namespace",
        "--super-prefix",
        "--config-env",
    }
)


@dataclass(frozen=True)
class GitInvocation:
    """A real git invocation extracted from a shell command string."""

    argv: tuple[str, ...]
    subcommand: str
    args: tuple[str, ...]


def _shell_tokens(command: str) -> list[str]:
    """Tokenize a shell command string while preserving unquoted separators."""
    command = _replace_unquoted_newlines(_strip_heredoc_bodies(command))
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
    lexer.whitespace_split = True
    return list(lexer)


def _strip_heredoc_bodies(command: str) -> str:
    """Remove heredoc body lines before shell-token scanning.

    The policy parser is interested in executable shell, not commit-message or
    script payload text. Stripping simple heredoc bodies prevents a body line
    that happens to start with ``git`` from being mistaken for an invocation.
    """
    if "<<" not in command:
        return command

    output: list[str] = []
    pending_delims: list[str] = []
    for line in command.splitlines():
        if pending_delims:
            if line.strip() == pending_delims[0]:
                pending_delims.pop(0)
            continue

        output.append(line)
        for match in _HEREDOC_RE.finditer(line):
            pending_delims.append(match.group(2))

    return "\n".join(output)


def _replace_unquoted_newlines(command: str) -> str:
    """Turn unquoted newlines into shell separators before shlex tokenization."""
    if "\n" not in command:
        return command

    result: list[str] = []
    quote: str | None = None
    escaped = False
    for ch in command:
        if escaped:
            result.append(ch)
            escaped = False
            continue
        if ch == "\\" and quote != "'":
            result.append(ch)
            escaped = True
            continue
        if ch in ("'", '"'):
            if quote == ch:
                quote = None
            elif quote is None:
                quote = ch
            result.append(ch)
            continue
        if ch == "\n" and quote is None:
            result.append(" ; ")
            continue
        result.append(ch)
    return "".join(result)


def _split_shell_segments(tokens: list[str]) -> list[list[str]]:
    """Split tokens on unquoted shell control operators."""
    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if token in _SHELL_SEPARATORS:
            if current:
                segments.append(current)
            current = []
            continue
        current.append(token)
    if current:
        segments.append(current)
    return segments


def _extract_shell_c_payload(tokens: list[str]) -> Optional[str]:
    """Return the command string passed to sh/bash/zsh -c/-lc, if present."""
    for index, token in enumerate(tokens):
        if token == "--":
            continue
        if token.startswith("-") and token != "-":
            if token == "-c" or "c" in token[1:]:
                return tokens[index + 1] if index + 1 < len(tokens) else None
            continue
        break
    return None


def _git_argv_from_segment(segment: list[str], *, depth: int = 0) -> Optional[list[str]]:
    """Resolve a shell segment to the git argv it actually executes, if any."""
    index = 0
    if segment and _COMMAND_SUB_GIT_PREFIX_RE.match(segment[0]):
        return ["git", *segment[1:]]
    while index < len(segment) and _ENV_ASSIGN_RE.match(segment[index]):
        if _COMMAND_SUB_GIT_PREFIX_RE.match(segment[index]):
            return ["git", *segment[index + 1 :]]
        index += 1
    if index >= len(segment):
        return None

    command = os.path.basename(segment[index])
    if command == "env":
        index += 1
        while index < len(segment) and (
            _ENV_ASSIGN_RE.match(segment[index]) or segment[index].startswith("-")
        ):
            index += 1
        if index >= len(segment):
            return None
        command = os.path.basename(segment[index])

    if command in _PASSTHROUGH_WRAPPERS:
        return _git_argv_from_segment(segment[index + 1 :], depth=depth)

    if command in _SHELL_WRAPPERS:
        if depth >= 2:
            return None
        inner = _extract_shell_c_payload(segment[index + 1 :])
        return _extract_git_argv(inner, depth=depth + 1) if inner else None

    if command != "git":
        return None

    return segment[index:]


def _dedupe_git_argvs(argvs: list[list[str]]) -> list[list[str]]:
    seen: set[tuple[str, ...]] = set()
    result: list[list[str]] = []
    for argv in argvs:
        key = tuple(argv)
        if key in seen:
            continue
        seen.add(key)
        result.append(argv)
    return result


def _inline_command_substitution_payloads(token: str) -> list[str]:
    """Extract simple one-token $(...) or `...` command substitutions."""
    payloads: list[str] = []
    start = 0
    while True:
        open_index = token.find("$(", start)
        if open_index < 0:
            break
        depth = 1
        cursor = open_index + 2
        while cursor < len(token) and depth:
            if token.startswith("$(", cursor):
                depth += 1
                cursor += 2
                continue
            if token[cursor] == ")":
                depth -= 1
                if depth == 0:
                    payloads.append(token[open_index + 2 : cursor])
                    break
            cursor += 1
        start = cursor + 1

    start = 0
    while True:
        open_index = token.find("`", start)
        if open_index < 0:
            break
        close_index = token.find("`", open_index + 1)
        if close_index < 0:
            break
        payloads.append(token[open_index + 1 : close_index])
        start = close_index + 1

    return payloads


def _git_argvs_from_segment(segment: list[str], *, depth: int = 0) -> list[list[str]]:
    """Resolve every git argv represented by a shell segment."""
    index = 0
    while index < len(segment) and _ENV_ASSIGN_RE.match(segment[index]):
        if _COMMAND_SUB_GIT_PREFIX_RE.match(segment[index]):
            break
        index += 1
    if index < len(segment):
        command = os.path.basename(segment[index])
        if command == "env":
            env_index = index + 1
            while env_index < len(segment) and (
                _ENV_ASSIGN_RE.match(segment[env_index]) or segment[env_index].startswith("-")
            ):
                env_index += 1
            return _git_argvs_from_segment(segment[env_index:], depth=depth)
        if command in _PASSTHROUGH_WRAPPERS:
            return _git_argvs_from_segment(segment[index + 1 :], depth=depth)
        if command in _SHELL_WRAPPERS:
            if depth >= 2:
                return []
            inner = _extract_shell_c_payload(segment[index + 1 :])
            return _extract_git_argvs(inner, depth=depth + 1) if inner else []

    argvs: list[list[str]] = []
    direct = _git_argv_from_segment(segment, depth=depth)
    if direct is not None:
        argvs.append(direct)

    index = 0
    while index < len(segment):
        token = segment[index]

        if _COMMAND_SUB_GIT_PREFIX_RE.match(token):
            argvs.append(["git", *segment[index + 1 :]])
            index += 1
            continue

        for payload in _inline_command_substitution_payloads(token):
            if depth < 2:
                argvs.extend(_extract_git_argvs(payload, depth=depth + 1))
        index += 1

    return _dedupe_git_argvs(argvs)


def _extract_git_argv(command: str, *, depth: int = 0) -> Optional[list[str]]:
    """Extract the argv for the first real git invocation in a shell command."""
    argvs = _extract_git_argvs(command, depth=depth)
    return argvs[0] if argvs else None


def _extract_git_argvs(command: str, *, depth: int = 0) -> list[list[str]]:
    """Extract every real git invocation embedded in a shell command."""
    try:
        tokens = _shell_tokens(command)
    except ValueError:
        return []

    argvs: list[list[str]] = []
    for segment in _split_shell_segments(tokens):
        argvs.extend(_git_argvs_from_segment(segment, depth=depth))
    return _dedupe_git_argvs(argvs)


def _git_subcommand(argv: list[str]) -> tuple[str, list[str]]:
    """Return (subcommand, remaining_args) for a git argv list."""
    index = 1
    while index < len(argv):
        token = argv[index]
        if token in _GIT_GLOBAL_OPTS_WITH_VALUE:
            index += 2
            continue
        if token.startswith("-C") and token != "-C":
            index += 1
            continue
        if token.startswith("-c") and token != "-c":
            index += 1
            continue
        if (
            token.startswith("--exec-path=")
            or token.startswith("--git-dir=")
            or token.startswith("--work-tree=")
            or token.startswith("--namespace=")
            or token.startswith("--super-prefix=")
            or token.startswith("--config-env=")
        ):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        return token, argv[index + 1 :]
    return "", []


def parse_git_invocation(command: str) -> Optional[GitInvocation]:
    """Parse the first real git invocation embedded in a shell command string."""
    invocations = parse_git_invocations(command)
    return invocations[0] if invocations else None


def parse_git_invocations(command: str) -> tuple[GitInvocation, ...]:
    """Parse every real git invocation embedded in a shell command string."""
    invocations: list[GitInvocation] = []
    for argv in _extract_git_argvs(command):
        if not argv:
            continue
        subcommand, args = _git_subcommand(argv)
        if not subcommand:
            continue
        invocations.append(GitInvocation(tuple(argv), subcommand, tuple(args)))
    return tuple(invocations)


def classify_git_invocation(invocation: GitInvocation) -> str:
    """Classify one parsed git invocation into an operation class."""
    subcommand = invocation.subcommand
    args = invocation.args

    # Admin recovery: merge --abort (governed recovery, not a landing operation)
    if subcommand == "merge" and "--abort" in args:
        return "admin_recovery"
    # Admin recovery: reset --merge (backed-out merge recovery)
    if subcommand == "reset" and "--merge" in args:
        return "admin_recovery"
    # High-risk: push
    if subcommand == "push":
        return "high_risk"
    # High-risk: rebase
    if subcommand == "rebase":
        return "high_risk"
    # High-risk: reset (any form not already caught by admin_recovery above)
    if subcommand == "reset":
        return "high_risk"
    # High-risk: worktree remove or prune (DEC-LEASE-EGAP-002)
    if subcommand == "worktree" and args[:1] and args[0] in ("remove", "prune"):
        return "high_risk"
    # High-risk: branch delete/rename (DEC-LEASE-EGAP-002 + parity with WHO gate)
    if subcommand == "branch" and any(re.fullmatch(r"-[A-Za-z]*[dDmM][A-Za-z]*", arg) for arg in args):
        return "high_risk"
    # High-risk: tag (create/delete/annotate) — DEC-LEASE-EGAP-002
    if subcommand == "tag":
        return "high_risk"
    # High-risk: merge --no-ff (must check before plain merge)
    if subcommand == "merge" and "--no-ff" in args:
        return "high_risk"
    # High-risk: cherry-pick — replays commits onto HEAD, mutates history
    if subcommand == "cherry-pick":
        return "high_risk"
    # High-risk: revert — creates a new commit undoing prior work
    if subcommand == "revert":
        return "high_risk"
    # High-risk: worktree move — relocates a worktree on disk
    if subcommand == "worktree" and args[:1] and args[0] == "move":
        return "high_risk"
    # High-risk: stash drop / stash clear — permanently discard stashed work
    if subcommand == "stash" and args[:1] and args[0] in ("drop", "clear"):
        return "high_risk"
    # High-risk: remote add / remove / rm / set-url — modifies remote config
    if subcommand == "remote" and args[:1] and args[0] in ("add", "remove", "rm", "set-url"):
        return "high_risk"
    # High-risk: commit-tree — writes commit objects outside porcelain commit
    # flow; normal Guardian landing should use git commit/merge/push.
    if subcommand == "commit-tree":
        return "high_risk"
    # High-risk: update-ref — directly writes ref objects, bypassing normal
    #   commit flow; used for surgery on the ref namespace
    if subcommand == "update-ref":
        return "high_risk"
    # High-risk: symbolic-ref — rewrites HEAD or other symbolic refs
    if subcommand == "symbolic-ref":
        return "high_risk"
    # High-risk: filter-branch / filter-repo — rewrites entire commit history
    if subcommand in ("filter-branch", "filter-repo"):
        return "high_risk"
    # Routine local: commit
    if subcommand == "commit":
        return "routine_local"
    # Routine local: merge (without --no-ff already handled above)
    if subcommand == "merge":
        return "routine_local"
    return "unclassified"


def _dominant_op_class(op_classes: list[str]) -> str:
    """Return the strictest summary class for a command containing many git ops."""
    if "high_risk" in op_classes:
        return "high_risk"
    if "admin_recovery" in op_classes:
        return "admin_recovery"
    if "routine_local" in op_classes:
        return "routine_local"
    return "unclassified"


def op_class_label(op_class: str) -> str:
    """User-facing label for the internal lease operation class."""
    return {
        "routine_local": "routine git",
        "high_risk": "governed git",
        "admin_recovery": "admin recovery",
        "unclassified": "unclassified",
    }.get(op_class, op_class)


def classify_git_op(command: str) -> str:
    """Classify a git command string into an operation class.

    Returns one of: "routine_local", "high_risk", "admin_recovery",
    "unclassified".

    This is the sole classifier for the migrated Check 3 path. Tokenization is
    shell-aware: quoted prompt text such as ``node tool "how to git push"``
    must NOT classify as a git operation, while nested shell invocations such
    as ``bash -lc "git push"`` still must classify correctly.

    Classification precedence (first match wins):
      admin_recovery: merge --abort, reset --merge (governed recovery, not landing)
      high_risk:      push, rebase, reset, merge --no-ff, worktree remove/prune,
                      branch -d/-D, tag (state-mutating operations governed by Guardian)
      routine_local:  commit, merge (without --no-ff)
      unclassified:   everything else

    @decision DEC-LEASE-002
    Title: admin_recovery op class exempts merge --abort / reset --merge from
           evaluation-readiness gate
    Status: accepted
    Rationale: merge --abort and reset --merge are governed administrative recovery
      operations — they undo an in-progress merge, not land new code. Requiring
      evaluation_state=ready_for_guardian for these operations is wrong because
      there is no "feature" to evaluate; the purpose is to return the repo to a
      clean state. They still require a lease and an approval token (same model as
      high_risk), but bypass Check 10's eval-readiness gate. The admin_recovery
      class is checked BEFORE the generic reset/merge patterns so the specific
      variants win over the broader classification.

    @decision DEC-LEASE-EGAP-002
    Title: worktree remove/prune, branch -d/-D, and tag are classified as high_risk
    Status: accepted
    Rationale: These operations were previously unclassified, meaning they fell
      through to "unclassified" which is not in any lease's allowed_ops — so they
      were implicitly denied. However, "unclassified" produces a confusing error
      message and does not integrate with Guardian's governed-operation flow. Classifying
      them as high_risk means: (a) they are explicitly denied for implementers and
      (b) Guardian leases that include high_risk can permit them when the relevant
      state gates agree. Approval-token requirements are decided by the approval
      policy, not by the classifier label itself.

    @decision DEC-LEASE-EGAP-003
    Title: RCA-1 ops classified as high_risk — cherry-pick, revert, worktree move,
           stash drop/clear, remote add/remove/set-url, update-ref, filter-branch
    Status: accepted
    Rationale: E2E testing (RCA-1, issue #21) proved these 9 operations were matched
      by the expanded _GIT_OP_RE in bash_git_who.py but then fell through to
      "unclassified" in classify_git_op(). "unclassified" is not in any lease's
      allowed_ops, producing a confusing denial message unrelated to the real
      enforcement intent. Classifying each as high_risk means Guardian leases
      that include high_risk can permit them while implementer leases cannot.
      Approval-token requirements remain a separate policy decision. This keeps
      the authority model consistent across state-mutating git operations without
      making every Guardian git command a user-decision boundary. Classification precedence: these
      checks appear AFTER admin_recovery but BEFORE the catch-all unclassified
      return so they do not interfere with recovery operations.
    """
    invocations = parse_git_invocations(command)
    if not invocations:
        return "unclassified"

    return _dominant_op_class([classify_git_invocation(inv) for inv in invocations])


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def _revoke_active_for_worktree(conn: sqlite3.Connection, worktree_path: str, now: int) -> None:
    """Revoke any active leases for worktree_path (called inside an open transaction)."""
    conn.execute(
        """UPDATE dispatch_leases
           SET status = 'revoked', released_at = ?
           WHERE worktree_path = ? AND status = 'active'""",
        (now, worktree_path),
    )


def _revoke_active_for_agent(conn: sqlite3.Connection, agent_id: str, now: int) -> None:
    """Revoke any active leases for agent_id (called inside an open transaction)."""
    conn.execute(
        """UPDATE dispatch_leases
           SET status = 'revoked', released_at = ?
           WHERE agent_id = ? AND status = 'active'""",
        (now, agent_id),
    )


def _fetch_active(conn: sqlite3.Connection, **filters) -> Optional[sqlite3.Row]:
    """Fetch first active lease matching the given column=value filters.

    worktree_path is normalized via normalize_path() (DEC-CONV-001) before
    the SQL WHERE comparison, so raw symlink paths match normalized stored values.
    """
    clauses = ["status = 'active'"]
    params = []
    for col, val in filters.items():
        # DEC-CONV-001: normalize worktree_path at every query boundary so that
        # raw paths (e.g. /var/... on macOS) match stored canonical realpaths.
        if col == "worktree_path" and val is not None:
            val = normalize_path(val)
        clauses.append(f"{col} = ?")
        params.append(val)
    sql = f"SELECT * FROM dispatch_leases WHERE {' AND '.join(clauses)} LIMIT 1"
    return conn.execute(sql, params).fetchone()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def issue(
    conn: sqlite3.Connection,
    role: str,
    worktree_path: Optional[str] = None,
    workflow_id: Optional[str] = None,
    branch: Optional[str] = None,
    allowed_ops: Optional[list] = None,
    blocked_ops: Optional[list] = None,
    requires_eval: bool = True,
    head_sha: Optional[str] = None,
    approval_scope: Optional[list] = None,
    next_step: Optional[str] = None,
    ttl: int = DEFAULT_LEASE_TTL,
    metadata: Optional[dict] = None,
) -> dict:
    """Issue a new dispatch lease for a role.

    If worktree_path is provided, any existing active lease for that path is
    revoked within the same transaction (one-active-per-worktree invariant).
    Returns the full lease row as a dict.

    worktree_path is normalized via normalize_path() (DEC-CONV-001) before
    being stored. build_context() looks up active leases by worktree_path;
    if the stored path uses a different form (symlink vs realpath) than the
    lookup key the lease becomes invisible.
    """
    # DEC-CONV-001: normalize worktree_path to canonical realpath form.
    canonical_worktree = normalize_path(worktree_path) if worktree_path else worktree_path

    lease_id = uuid.uuid4().hex
    now = int(time.time())
    expires_at = now + ttl

    if allowed_ops is None:
        _defaults = ROLE_DEFAULTS.get(role, {})
        allowed_ops = _defaults.get("allowed_ops", ["routine_local"])
    if blocked_ops is None:
        blocked_ops = []

    allowed_ops_json = json.dumps(allowed_ops)
    blocked_ops_json = json.dumps(blocked_ops)
    approval_scope_json = json.dumps(approval_scope) if approval_scope is not None else None
    metadata_json = json.dumps(metadata) if metadata is not None else None

    with conn:
        # Enforce uniqueness: one active lease per worktree.
        if canonical_worktree:
            _revoke_active_for_worktree(conn, canonical_worktree, now)

        conn.execute(
            """INSERT INTO dispatch_leases (
                   lease_id, role, workflow_id, worktree_path, branch,
                   allowed_ops_json, blocked_ops_json, requires_eval,
                   head_sha, approval_scope_json, next_step,
                   status, issued_at, expires_at, metadata_json
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?)""",
            (
                lease_id,
                role,
                workflow_id,
                canonical_worktree,
                branch,
                allowed_ops_json,
                blocked_ops_json,
                int(requires_eval),
                head_sha,
                approval_scope_json,
                next_step,
                now,
                expires_at,
                metadata_json,
            ),
        )

    return get(conn, lease_id)


def claim(
    conn: sqlite3.Connection,
    agent_id: str,
    lease_id: Optional[str] = None,
    worktree_path: Optional[str] = None,
    expected_role: Optional[str] = None,
) -> Optional[dict]:
    """Claim an active lease by associating agent_id with it.

    Lookup priority: lease_id > worktree_path.
    Any other active lease held by agent_id is revoked (one-lease-per-agent).
    Returns the claimed lease dict, or None if no active lease found.

    If expected_role is provided, the lease's role must match exactly. A
    mismatch returns None — this prevents one role from claiming another's
    lease (e.g. a reviewer claiming a guardian lease; DEC-LEASE-003).
    """
    now = int(time.time())

    # Find target lease
    # DEC-CONV-001: normalize worktree_path at query boundary so symlink paths
    # match stored canonical realpaths.
    canonical_worktree = normalize_path(worktree_path) if worktree_path else worktree_path

    target_row = None
    if lease_id:
        row = conn.execute(
            "SELECT * FROM dispatch_leases WHERE lease_id = ? AND status = 'active'",
            (lease_id,),
        ).fetchone()
        target_row = row
    elif canonical_worktree:
        target_row = _fetch_active(conn, worktree_path=canonical_worktree)

    if target_row is None:
        return None

    # Verify role matches expectation when specified (DEC-LEASE-003).
    if expected_role is not None and target_row["role"] != expected_role:
        return None

    target_lease_id = target_row["lease_id"]

    with conn:
        # Revoke any other active lease for this agent (excluding the target).
        conn.execute(
            """UPDATE dispatch_leases
               SET status = 'revoked', released_at = ?
               WHERE agent_id = ? AND status = 'active' AND lease_id != ?""",
            (now, agent_id, target_lease_id),
        )
        # Associate agent_id with the target lease.
        conn.execute(
            "UPDATE dispatch_leases SET agent_id = ? WHERE lease_id = ?",
            (agent_id, target_lease_id),
        )

    return get(conn, target_lease_id)


def get(conn: sqlite3.Connection, lease_id: str) -> Optional[dict]:
    """Direct lookup by lease_id. Returns dict or None."""
    row = conn.execute(
        "SELECT * FROM dispatch_leases WHERE lease_id = ?",
        (lease_id,),
    ).fetchone()
    return _row_to_dict(row) if row else None


def get_current(
    conn: sqlite3.Connection,
    lease_id: Optional[str] = None,
    worktree_path: Optional[str] = None,
    agent_id: Optional[str] = None,
    workflow_id: Optional[str] = None,
) -> Optional[dict]:
    """Resolve the active lease with priority: lease_id > agent_id > worktree_path > workflow_id.

    Only returns status='active' leases. Returns None if no active lease found
    for any of the supplied identifiers.

    worktree_path is normalized via normalize_path() (DEC-CONV-001) before the
    SQL WHERE comparison so that raw symlink paths (e.g. /var/... on macOS) match
    the canonical realpaths stored by issue().
    """
    # DEC-CONV-001: normalize worktree_path at every query boundary.
    canonical_worktree = normalize_path(worktree_path) if worktree_path else worktree_path

    row = None
    if lease_id:
        row = conn.execute(
            "SELECT * FROM dispatch_leases WHERE lease_id = ? AND status = 'active'",
            (lease_id,),
        ).fetchone()
    if row is None and agent_id:
        row = _fetch_active(conn, agent_id=agent_id)
    if row is None and canonical_worktree:
        row = _fetch_active(conn, worktree_path=canonical_worktree)
    if row is None and workflow_id:
        row = _fetch_active(conn, workflow_id=workflow_id)
    return _row_to_dict(row) if row else None


def validate_op(
    conn: sqlite3.Connection,
    command: str,
    lease_id: Optional[str] = None,
    worktree_path: Optional[str] = None,
    agent_id: Optional[str] = None,
    workflow_id: Optional[str] = None,
) -> dict:
    """Composite validation of a git command against the active lease.

    Always returns a dict with the full validation surface. Does NOT consume
    approval tokens — only peeks via list_pending. guard.sh Check 13 owns
    token consumption.

    Return keys:
      allowed          bool  — True only when all applicable checks pass
      reason           str   — human-readable explanation
      lease_id         str|None
      role             str|None
      workflow_id      str|None
      op_class         str   — always present: routine_local|high_risk|unclassified
      requires_eval    bool
      eval_ok          bool|None  — None when eval check not applicable
      requires_approval bool
      approval_ok      bool|None  — None when approval check not applicable
    """
    import runtime.core.approvals as approvals_mod
    import runtime.core.evaluation as evaluation_mod

    invocations = parse_git_invocations(command)
    op_classes = [classify_git_invocation(invocation) for invocation in invocations]
    effective_op_classes = [op_class for op_class in op_classes if op_class != "unclassified"]
    op_class = _dominant_op_class(op_classes)

    result = {
        "allowed": False,
        "reason": "",
        "lease_id": None,
        "role": None,
        "workflow_id": None,
        "op_class": op_class,
        "op_label": op_class_label(op_class),
        "requires_eval": False,
        "eval_ok": None,
        "requires_approval": False,
        "approval_ok": None,
    }

    # Resolve active lease.
    lease = get_current(
        conn,
        lease_id=lease_id,
        worktree_path=worktree_path,
        agent_id=agent_id,
        workflow_id=workflow_id,
    )

    if lease is None:
        result["reason"] = "no active lease found"
        return result

    # Check lease is not expired (get_current only returns status=active, but
    # expire_stale may not have run yet — check expires_at defensively).
    now = int(time.time())
    if lease["expires_at"] < now:
        result["reason"] = "lease has expired"
        return result

    result["lease_id"] = lease["lease_id"]
    result["role"] = lease["role"]
    result["workflow_id"] = lease["workflow_id"]
    result["requires_eval"] = bool(lease["requires_eval"])

    # Deserialise allowed/blocked op lists.
    try:
        allowed_ops = json.loads(lease["allowed_ops_json"] or "[]")
        blocked_ops = json.loads(lease["blocked_ops_json"] or "[]")
    except (json.JSONDecodeError, TypeError):
        allowed_ops = ["routine_local"]
        blocked_ops = []

    # Check every governed op is permitted by the lease.
    classes_to_check = effective_op_classes or [op_class]
    for candidate_class in classes_to_check:
        if candidate_class in blocked_ops:
            result["reason"] = (
                f"{op_class_label(candidate_class)} operation is blocked "
                f"(internal op_class '{candidate_class}')"
            )
            return result
        if candidate_class not in allowed_ops:
            result["reason"] = (
                f"{op_class_label(candidate_class)} operation is not allowed "
                f"by this lease: not in allowed_ops "
                f"(internal op_class '{candidate_class}', "
                f"allowed_ops {allowed_ops})"
            )
            return result

    # Eval check (when requires_eval and op is not unclassified or admin_recovery).
    # admin_recovery (merge --abort, reset --merge) skips the eval gate because
    # these are governed recovery operations, not landing operations — there is no
    # feature to evaluate. They still require a lease and approval token (below).
    eval_ok = None
    eval_required = any(
        candidate_class not in ("unclassified", "admin_recovery")
        for candidate_class in classes_to_check
    )
    if lease["requires_eval"] and eval_required:
        wf_id = lease["workflow_id"]
        if wf_id:
            eval_state = evaluation_mod.get(conn, wf_id)
            if (
                eval_state is not None
                and eval_state.get("status") == "ready_for_guardian"
                and (lease["head_sha"] is None or eval_state.get("head_sha") == lease["head_sha"])
            ):
                eval_ok = True
            else:
                eval_ok = False
        else:
            # No workflow_id on lease — cannot check eval, treat as ok.
            eval_ok = True

    result["eval_ok"] = eval_ok

    if eval_ok is False:
        result["reason"] = "evaluation_state is not ready_for_guardian (or SHA mismatch)"
        return result

    # Approval check: admin_recovery and approval-gated governed ops require
    # an unconsumed token. Straightforward push stays classified as high_risk
    # for lease/capability purposes but is no longer user-gated once Guardian
    # has reviewer/test/lease clearance.
    requires_approval = any(
        candidate_class == "admin_recovery"
        or (
            candidate_class == "high_risk"
            and invocation.subcommand != "push"
        )
        for invocation, candidate_class in zip(invocations, op_classes)
    )
    result["requires_approval"] = requires_approval
    approval_ok = None

    if requires_approval:
        wf_id = lease["workflow_id"]
        pending = approvals_mod.list_pending(conn, workflow_id=wf_id)
        # Map op_class to the approval op_type we'd look for.
        # Approval-gated governed and admin_recovery ops may have different
        # sub-types; for now we accept any pending token for the workflow.
        approval_ok = len(pending) > 0

    result["approval_ok"] = approval_ok

    if requires_approval and not approval_ok:
        result["reason"] = (
            "op requires an unconsumed approval token "
            "(approval-gated governed operation or admin_recovery)"
        )
        return result

    result["allowed"] = True
    result["reason"] = "ok"
    return result


def list_leases(
    conn: sqlite3.Connection,
    status: Optional[str] = None,
    workflow_id: Optional[str] = None,
    role: Optional[str] = None,
    worktree_path: Optional[str] = None,
) -> list[dict]:
    """List leases with optional filters, ordered by issued_at DESC.

    worktree_path is normalized via normalize_path() (DEC-CONV-001) before
    the SQL WHERE comparison so raw symlink paths match stored canonical realpaths.
    """
    # DEC-CONV-001: normalize worktree_path at query boundary.
    canonical_worktree = normalize_path(worktree_path) if worktree_path else worktree_path

    clauses = []
    params = []
    if status:
        clauses.append("status = ?")
        params.append(status)
    if workflow_id:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    if role:
        clauses.append("role = ?")
        params.append(role)
    if canonical_worktree:
        clauses.append("worktree_path = ?")
        params.append(canonical_worktree)

    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    rows = conn.execute(
        f"SELECT * FROM dispatch_leases {where} ORDER BY issued_at DESC",
        params,
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


def release(conn: sqlite3.Connection, lease_id: str) -> bool:
    """Transition active → released. Returns True if updated, False otherwise."""
    now = int(time.time())
    with conn:
        cursor = conn.execute(
            """UPDATE dispatch_leases
               SET status = 'released', released_at = ?
               WHERE lease_id = ? AND status = 'active'""",
            (now, lease_id),
        )
    return cursor.rowcount > 0


def revoke(conn: sqlite3.Connection, lease_id: str) -> bool:
    """Transition active → revoked. Returns True if updated, False otherwise."""
    now = int(time.time())
    with conn:
        cursor = conn.execute(
            """UPDATE dispatch_leases
               SET status = 'revoked', released_at = ?
               WHERE lease_id = ? AND status = 'active'""",
            (now, lease_id),
        )
    return cursor.rowcount > 0


def expire_stale(conn: sqlite3.Connection, now: Optional[int] = None) -> int:
    """Transition all active leases past their expires_at to status='expired'.

    Returns the count of leases that were expired.
    """
    if now is None:
        now = int(time.time())
    with conn:
        cursor = conn.execute(
            """UPDATE dispatch_leases
               SET status = 'expired', released_at = ?
               WHERE status = 'active' AND expires_at < ?""",
            (now, now),
        )
    return cursor.rowcount


def summary(
    conn: sqlite3.Connection,
    worktree_path: Optional[str] = None,
    workflow_id: Optional[str] = None,
) -> dict:
    """Compact read model: active_lease, recent_leases (last 5), has_active.

    worktree_path is normalized via normalize_path() (DEC-CONV-001) before
    any SQL filtering so raw symlink paths match stored canonical realpaths.
    """
    # DEC-CONV-001: normalize worktree_path at query boundary.
    canonical_worktree = normalize_path(worktree_path) if worktree_path else worktree_path

    active = get_current(conn, worktree_path=canonical_worktree, workflow_id=workflow_id)

    # Recent leases (last 5) filtered by supplied context.
    clauses = []
    params = []
    if canonical_worktree:
        clauses.append("worktree_path = ?")
        params.append(canonical_worktree)
    if workflow_id:
        clauses.append("workflow_id = ?")
        params.append(workflow_id)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    recent_rows = conn.execute(
        f"SELECT * FROM dispatch_leases {where} ORDER BY issued_at DESC LIMIT 5",
        params,
    ).fetchall()

    return {
        "active_lease": active,
        "recent_leases": [_row_to_dict(r) for r in recent_rows],
        "has_active": active is not None,
    }


def render_startup_contract(lease: dict) -> str:
    """Render a human-readable text block from a lease dict.

    Used by the CLI to print context for the agent at dispatch time.
    """
    import datetime

    expires_dt = datetime.datetime.fromtimestamp(
        lease.get("expires_at", 0), tz=datetime.timezone.utc
    ).isoformat()

    try:
        allowed_ops = json.loads(lease.get("allowed_ops_json") or "[]")
        allowed_str = ", ".join(allowed_ops) if allowed_ops else "(none)"
    except (json.JSONDecodeError, TypeError):
        allowed_str = "(parse error)"

    return (
        f"LEASE_ID={lease.get('lease_id', '')}\n"
        f"Role: {lease.get('role', '')}\n"
        f"Workflow: {lease.get('workflow_id', '')}\n"
        f"Worktree: {lease.get('worktree_path', '')}\n"
        f"Branch: {lease.get('branch', '')}\n"
        f"Allowed ops: {allowed_str}\n"
        f"Next step: {lease.get('next_step', '')}\n"
        f"Expires: {expires_dt}"
    )

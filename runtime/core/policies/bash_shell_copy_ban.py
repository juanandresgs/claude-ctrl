"""Policy: bash_shell_copy_ban — deny shell file-op commands that write into
scope.forbidden_paths for CAN_WRITE_SOURCE actors.

Capability-gated on CAN_WRITE_SOURCE (implementer role). Non-implementer actors
are not subject to this policy — return None so other policies can proceed.

Background (DEC-DISCIPLINE-SHELL-COPY-BAN-001):
  Slices 6 and 8 closed the stash-pop and git checkout/restore contamination
  vectors respectively. Shell file-ops remain the last open mechanical route by
  which a CAN_WRITE_SOURCE actor can materialise foreign content into the
  worktree before commit. Examples that were ungated:

    cp /other/worktree/runtime/core/policies/foo.py runtime/core/policies/foo.py
    mv ../other-lane/CLAUDE.md CLAUDE.md
    rsync -a /ref/path/ runtime/
    ln -sf /some/source runtime/core/policies/bar.py
    install -m 644 /foreign/src tests/runtime/t.py
    tar -xf foreign.tar.gz -C runtime/
    cat /foreign/src > runtime/core/x.py

  This policy closes all of these by checking whether the write destination
  matches scope.forbidden_paths for the active workflow.

  Banned destination classes (resolved from the raw command):
    cp [flags] <src> <dst>         — last positional arg
    mv [flags] <src> <dst>         — last positional arg
    rsync [flags] <src> <dst>      — last positional arg
    ln [-s] <src> <dst>            — last positional arg
    install [flags] <src> <dst>    — last positional arg
    tar --extract/-x ... -C <dst>  — value of -C/--directory flag
    cmd > <path>, cmd >> <path>    — redirect target
    tee <path>                     — first non-flag positional

  Non-git guard:
    If command_intent.git_invocation is not None, this is a git command and
    MUST be passed through — bash_cross_branch_restore_ban owns that vector.

  Source authority:
    Write target extraction for cp/mv/install/>/>> /tee delegates to
    runtime.core.command_intent.extract_bash_write_targets, which is the
    single authority for those command classes. rsync/ln/tar are parsed here
    via runtime.core.leases._shell_tokens (Rule-A-compliant: no direct shlex
    import in this policy; Rule-B-compliant: no .split() on raw command string).

Exemption design:
  Supervisor-authorized Option B recovery is performed by guardian, which does
  NOT carry CAN_WRITE_SOURCE. The capability gate alone is the exemption
  mechanism — no allowlist string is needed (mirrors bash_stash_ban design).
  If context.scope is None (no active workflow scope row), this policy is a
  no-op. If forbidden_paths is empty, this policy is a no-op.

@decision DEC-DISCIPLINE-SHELL-COPY-BAN-001
Title: bash_shell_copy_ban is the sole enforcement authority for shell-mediated
  contamination (non-git file-op vector) into scope-forbidden paths by
  CAN_WRITE_SOURCE actors.
Status: accepted
Rationale: bash_stash_ban (priority 625, slice 6) closes the stash-pop vector.
  bash_cross_branch_restore_ban (priority 630, slice 8) closes the git
  checkout/restore vector. This policy closes the shell file-op vector: cp, mv,
  rsync, ln, install, tar --extract, and shell redirection writes whose
  destination matches scope.forbidden_paths. A separate module is required
  because:
  (a) bash_cross_branch_restore_ban is narrowly scoped to git commands by
      name and audit contract; folding shell ops would violate its single-
      authority docstring;
  (b) bash_workflow_scope fires at commit/merge time on the staged index —
      by then the worktree has already been contaminated;
  (c) bash_write_who gates shell writes by role authority (CAN_WRITE_SOURCE
      present/absent), not by scope.forbidden_paths — the axes are orthogonal;
  (d) one-authority-per-vector is the established codebase pattern.
  Priority 635: between bash_cross_branch_restore_ban (630) and
  bash_worktree_removal (700). Capability-gated on CAN_WRITE_SOURCE, not
  actor_role string. rsync/ln/tar parsed via _shell_tokens from leases.py
  (Rule-A-compliant: no shlex import in this policy; this reuses the same
  tokenizer leases.py and command_intent.py already use internally).
  Integration note: This policy does not fire on git invocations (guarded by
  git_invocation is not None → return None). See risk register §9 in
  tmp/slice10-plan.md for false-positive and double-fire analysis.

@decision DEC-DISCIPLINE-SHELL-COPY-BAN-002
Title: Absolute destination paths are normalized to repo-relative before
  forbidden-glob matching (slice 10R hotfix).
Status: accepted
Rationale: The original slice 10 implementation matched destination tokens
  against scope.forbidden_paths using fnmatch as raw shell tokens. A relative
  destination like "hooks/pre-bash.sh" matched "hooks/**" correctly, but an
  absolute path like "/project/.worktrees/lane/hooks/pre-bash.sh" did NOT match
  because fnmatch("/.../hooks/pre-bash.sh", "hooks/**") is False — the absolute
  prefix prevents the glob match. The fix normalizes each destination via
  _normalize_dest(): if it is an absolute path that is a subpath of the
  worktree root (context.worktree_path), strip the prefix to get the
  repo-relative form, then apply the existing _is_path_forbidden() unchanged.
  If the absolute path is outside the worktree root entirely, it cannot pollute
  the worktree — pass the raw token to _is_path_forbidden(), which will return
  False (no forbidden glob matches a fully-external absolute path). The fix is
  intentionally minimal and local to this module: no shared normalizer is added
  to policy_utils.py (F8-02 follow-on out of scope for this hotfix). The
  worktree_path authority is request.context.worktree_path, which is populated
  by build_context() and is the same authority surface used by sibling policies.
  Conservative design: if worktree_path is empty/unavailable, the raw token is
  passed through unchanged (pre-fix behavior — no regression for unrooted
  contexts). Trailing slashes on rsync-style directory destinations are stripped
  before prefix comparison and restored to the normalized form consistently.
"""

from __future__ import annotations

import fnmatch
import json
import os
from typing import Optional

from runtime.core.authority_registry import CAN_WRITE_SOURCE
from runtime.core.command_intent import extract_bash_write_targets
from runtime.core.leases import _shell_tokens
from runtime.core.policy_engine import PolicyDecision, PolicyRequest

# ---------------------------------------------------------------------------
# Command sets
# ---------------------------------------------------------------------------

# Shell commands whose last non-flag positional argument is the write destination.
# cp/mv/install are already handled by extract_bash_write_targets; they appear
# here for completeness but the shlex fallback below is not needed for them.
_LAST_POSITIONAL_DEST_CMDS: frozenset[str] = frozenset({"cp", "mv", "rsync", "ln", "install"})

# Subset not covered by extract_bash_write_targets (slice-safe, no new tokenizer).
_EXTRA_COPY_CMDS: frozenset[str] = frozenset({"rsync", "ln"})


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _parse_scope_list(raw: object) -> list[str]:
    """Decode a workflow_scope JSON-TEXT column to list[str].

    Mirrors bash_cross_branch_restore_ban._parse_scope_list semantics:
    list passthrough, JSON-string decode, malformed/unknown → [].
    Fail-open on malformed (conservative: no-op rather than crash).

    NOTE (deferred): _parse_scope_list consolidation into policy_utils.py is
    out of scope for slice 10 (F8-02 follow-on). Do NOT consolidate here — that
    would require touching policy_utils.py which is outside the slice 10 scope.
    """
    if isinstance(raw, list):
        return [str(x) for x in raw if isinstance(x, str)]
    if isinstance(raw, str):
        try:
            decoded = json.loads(raw)
            if isinstance(decoded, list):
                return [str(x) for x in decoded if isinstance(x, str)]
        except (ValueError, TypeError):
            pass
    return []


def _is_path_forbidden(
    path: str,
    forbidden_patterns: list[str],
    allowed_patterns: list[str],
) -> bool:
    """Return True if path matches any forbidden_pattern and no allowed_pattern.

    Path is matched as-is via fnmatch glob semantics (mirrors
    bash_cross_branch_restore_ban._is_path_forbidden convention).
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


def _normalize_dest(dest: str, worktree_path: str, project_root: str = "") -> str:
    """Normalize a shell destination token to a repo-relative path for fnmatch.

    Relative destinations (e.g., "hooks/pre-bash.sh") are returned as-is —
    they are already repo-relative from the implicit CWD assumption.

    Absolute destinations are resolved against two candidate roots in order:
      1. worktree_path — the lane-specific worktree root
         (e.g., "/project/.worktrees/lane").
      2. project_root — the bare project root
         (e.g., "/project"), used when the absolute dest points directly into
         the project root rather than a worktree subdirectory.

    For each candidate root:
      - If the absolute dest is under that root, strip the prefix to yield
        a repo-relative path ("hooks/pre-bash.sh") and match normally.
      - If the absolute dest matches exactly that root, treat as "." (repo root).

    If the dest is NOT under either root (fully external path such as
    "/usr/local/bin/x"), return the raw token unchanged. The raw absolute
    path cannot match any of the repo-relative forbidden globs
    (e.g., "hooks/**"), so _is_path_forbidden() will return False — correct
    behavior: an external destination cannot contaminate the worktree.

    Trailing slashes (rsync-style directory destinations, e.g., "hooks/") are
    preserved so that fnmatch("hooks/", "hooks/**") works correctly; they are
    NOT stripped before matching.

    Conservative fallback: if both worktree_path and project_root are empty,
    or dest is empty, return dest unchanged (pre-hotfix behavior, no regression
    for unrooted contexts).

    @decision DEC-DISCIPLINE-SHELL-COPY-BAN-002
    """
    if not dest:
        return dest
    if not os.path.isabs(dest):
        # Relative path — already repo-relative.
        return dest

    def _try_strip(root: str, d: str) -> str | None:
        """Return repo-relative form if d is under root, else None."""
        r = root.rstrip("/")
        if not r:
            return None
        if d == r:
            return "."
        if d.startswith(r + "/"):
            return d[len(r) + 1:]
        return None

    # Try worktree_path first (more specific), then project_root.
    for root in (worktree_path, project_root):
        if root:
            result = _try_strip(root, dest)
            if result is not None:
                return result

    # dest is not under either root — external path, cannot pollute worktree.
    return dest


def _extract_rsync_ln_tar_targets(command: str) -> set[str]:
    """Return write-destination paths from rsync, ln, and tar --extract invocations.

    Uses _shell_tokens() from runtime.core.leases as the single tokenizer
    (Rule-A-compliant: no direct shlex import in this policy module;
    Rule-B-compliant: no .split() on raw command string).
    Conservative: parse errors or unparseable forms return empty set.

    Handles:
      rsync [flags] <src> <dst>          → last non-flag positional
      ln [-s|-n] <src> <dst>             → last non-flag positional
      tar --extract/-x ... -C <dst>      → value of -C or --directory=<dst>
      tar --extract/-x ... -f <file>     → <file> is not a destination (ignore)

    Deliberately does NOT handle tar extraction to the current directory
    (tar -xf foo.tar without -C) — no confident destination can be determined,
    so we err on the side of under-blocking (policy design principle: false
    positives are worse than false negatives for scope bans).
    """
    targets: set[str] = set()
    if not command:
        return targets

    try:
        tokens = _shell_tokens(command)
    except ValueError:
        # Shell parse error — cannot confidently determine destination, allow.
        return targets

    if not tokens:
        return targets

    # Strip env-style prefix tokens (VAR=val before the command)
    i = 0
    while i < len(tokens) and "=" in tokens[i] and not tokens[i].startswith("-"):
        i += 1
    if i >= len(tokens):
        return targets

    cmd = os.path.basename(tokens[i])

    if cmd in ("rsync", "ln"):
        # Last non-flag positional argument is the destination.
        positionals = [t for t in tokens[i + 1:] if t and not t.startswith("-")]
        if len(positionals) >= 2:
            # src dst: last positional is destination
            targets.add(positionals[-1])
        # len < 2: can't determine dst confidently → allow (under-blocking)
        return targets

    if cmd == "tar":
        # Only relevant when --extract / -x is present.
        # Scan for extraction flag and -C / --directory flag.
        rest = tokens[i + 1:]
        is_extract = False
        dst: Optional[str] = None
        j = 0
        while j < len(rest):
            tok = rest[j]
            # Long-form extraction flag
            if tok == "--extract":
                is_extract = True
                j += 1
                continue
            # Long-form destination (check before generic short-flag handler)
            if tok.startswith("--directory="):
                dst = tok[len("--directory="):]
                j += 1
                continue
            # -C <dir> or --directory <dir> (check before generic short-flag handler
            # so that -C is not swallowed by the short-flag cluster branch below)
            if tok in ("-C", "--directory") and j + 1 < len(rest):
                dst = rest[j + 1]
                j += 2
                continue
            if tok.startswith("-") and not tok.startswith("--"):
                # Short-flag cluster: extract x flag presence.
                # Note: -C is already handled above so it won't reach here.
                if "x" in tok[1:]:
                    is_extract = True
                j += 1
                continue
            j += 1

        if is_extract and dst:
            targets.add(dst)
        return targets

    return targets


# ---------------------------------------------------------------------------
# Main policy check
# ---------------------------------------------------------------------------


def check(request: PolicyRequest) -> Optional[PolicyDecision]:
    """Deny shell file-op writes to forbidden scope paths for CAN_WRITE_SOURCE actors.

    Logic:
      1. If CAN_WRITE_SOURCE not in capabilities: return None (not our gate).
      2. If command_intent is None (non-bash or empty command): return None.
      3. If git_invocation is not None: return None (bash_cross_branch_restore_ban owns git).
      4. If context.scope is None: return None (conservative; no-op outside ClauDEX workflows).
      5. Extract forbidden/allowed patterns from scope.
      6. If forbidden_patterns is empty: return None (nothing to enforce).
      7. Collect write targets from two sources:
         a. extract_bash_write_targets() covers cp/mv/install/>/>> /tee.
         b. _extract_rsync_ln_tar_targets() covers rsync/ln/tar --extract.
      8. For each target, check _is_path_forbidden() — allow beats forbidden.
      9. If any target is forbidden: return deny.
      10. Otherwise: return None (allow).

    @decision DEC-DISCIPLINE-SHELL-COPY-BAN-001
    Title: bash_shell_copy_ban.check() is the single enforcement gate for
      shell file-op contamination into scope-forbidden paths.
    Status: accepted
    Rationale: See module docstring. Two-source extraction (extract_bash_write_targets
      for well-established commands + _extract_rsync_ln_tar_targets for the
      additional classes) avoids introducing a new tokenizer while reusing the
      canonical authority surface. Conservative design: parse errors and
      ambiguous forms pass through (under-block, not over-block).
    """
    # Gate 1: only apply to CAN_WRITE_SOURCE actors (implementers).
    if CAN_WRITE_SOURCE not in request.context.capabilities:
        return None

    # Gate 2: require parsed command intent.
    intent = request.command_intent
    if intent is None:
        return None

    # Gate 3: git commands are owned by bash_cross_branch_restore_ban.
    if intent.git_invocation is not None:
        return None

    # Gate 4: conservative exemption — no scope seated → policy is a no-op.
    scope = request.context.scope
    if scope is None:
        return None

    forbidden_patterns, allowed_patterns = _extract_scope_patterns(scope)

    # Gate 5: no forbidden patterns → nothing to enforce.
    if not forbidden_patterns:
        return None

    # Collect write targets from both authority surfaces.
    command = intent.command
    targets: set[str] = set()
    targets |= extract_bash_write_targets(command)
    targets |= _extract_rsync_ln_tar_targets(command)

    if not targets:
        return None

    # Normalize each target to repo-relative before forbidden-glob matching.
    # Absolute paths that point inside the worktree (or project root) are stripped
    # to repo-relative form so that fnmatch("hooks/pre-bash.sh", "hooks/**") fires
    # correctly even when the implementer spelled out the full worktree path.
    # (DEC-DISCIPLINE-SHELL-COPY-BAN-002)
    worktree_path: str = request.context.worktree_path or ""
    project_root: str = request.context.project_root or ""
    normalized_targets = {
        _normalize_dest(t, worktree_path, project_root) for t in targets
    }

    # Check each normalized target against forbidden/allowed patterns.
    forbidden_targets = [
        t for t in normalized_targets
        if _is_path_forbidden(t, forbidden_patterns, allowed_patterns)
    ]
    if not forbidden_targets:
        return None

    workflow_id = request.context.workflow_id or "<unknown>"
    return PolicyDecision(
        action="deny",
        reason=(
            f"Implementer cannot run a shell file-op that writes to forbidden scope paths. "
            f"Command: {command!r}. "
            f"Forbidden write destinations: {forbidden_targets!r}. "
            f"Workflow {workflow_id!r} prohibits writes to these paths via scope discipline. "
            f"This policy closes the shell-mediated contamination vector (slice 10): "
            f"cp/mv/rsync/ln/install/tar-extract/redirection writes into scope-forbidden paths "
            f"are banned for can_write_source actors. "
            f"(bash_shell_copy_ban, capability-gated on can_write_source)"
        ),
        policy_name="bash_shell_copy_ban",
    )


def register(registry) -> None:
    """Register bash_shell_copy_ban into the given PolicyRegistry.

    Priority 635: between bash_cross_branch_restore_ban (630) and
    bash_worktree_removal (700). Fires after both stash-pop and cross-branch-
    restore contamination vectors have been evaluated, completing the trio of
    contamination-vector guards in the 625–635 priority band.
    """
    registry.register(
        "bash_shell_copy_ban",
        check,
        event_types=["Bash", "PreToolUse"],
        priority=635,
    )

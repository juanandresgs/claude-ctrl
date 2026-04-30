"""Python ports of shell utility functions for the policy engine.

Each function in this module is a direct port of a shell function from
hooks/context-lib.sh or hooks/guard.sh. The docstring of each function
cites the exact source location.

These helpers are imported by policy_engine.py (build_context) and by
individual policy modules in runtime/core/policies/. They must NOT import
from hooks/ — this is a clean Python layer.

@decision DEC-PE-003
Title: policy_utils.py is a pure-Python port of shell classification helpers
Status: accepted
Rationale: Policies run in Python (via the PolicyRegistry). They need the
  same path classification logic the shell hooks use so that a file
  allowed by guard.sh is also allowed by a Python policy. Porting to
  Python (rather than shelling out) eliminates subprocess overhead on
  every hook call and makes the logic unit-testable without bash. Each
  function cites its shell source so future maintainers can verify parity.

@decision DEC-CONV-001
Title: normalize_path() is the single canonical path normalizer for project_root/worktree_path
Status: accepted
Rationale: On macOS /tmp is a symlink to /private/tmp and /var/folders resolves
  to /private/var/folders. Git always resolves symlinks when returning
  rev-parse --show-toplevel. Without normalization a path written via
  os.getcwd() or CLAUDE_PROJECT_DIR may differ from the git-resolved form,
  causing DB row misses on every cross-boundary lookup. normalize_path() uses
  os.path.realpath() — the same mechanism git uses — applied at every persist
  and query boundary for project_root and worktree_path. No ad-hoc inline
  normalization exists elsewhere; all callers must funnel through this function.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any, Optional

from runtime.core.constitution_registry import is_constitution_level, normalize_repo_path

# ---------------------------------------------------------------------------
# Scope-list parsing — single canonical authority
# @decision DEC-DISCIPLINE-SCOPE-PARSER-SINGLE-AUTH-001
# Title: parse_scope_list is the sole canonical parser for workflow_scope JSON-TEXT
# Status: accepted
# Rationale: Four policy modules (write_plan_guard, write_who,
#   bash_cross_branch_restore_ban, bash_shell_copy_ban) each carried a byte-identical
#   local copy of _parse_scope_list. Independent copies can drift silently (e.g.,
#   one copy adds a new input type) and each update requires touching N files
#   instead of one. Slice 11 consolidates into this single authority so that:
#   (a) One function, one location, one place to audit, one place to test.
#   (b) All callers import via `from runtime.core.policy_utils import parse_scope_list
#       as _parse_scope_list` — the local alias preserves existing call-sites
#       unchanged while `<module>._parse_scope_list is parse_scope_list` becomes
#       a testable identity invariant.
#   (c) The single-authority invariant test
#       (tests/runtime/policies/test_scope_parser_single_authority.py) fails loudly
#       if any future maintainer re-introduces a local redefinition.
# ---------------------------------------------------------------------------


def parse_scope_list(raw: Any) -> list[str]:
    """Decode a workflow_scope JSON-TEXT column to list[str].

    Canonical single-authority parser shared by all policy modules that consume
    workflow_scope.forbidden_paths / allowed_paths rows. See
    DEC-DISCIPLINE-SCOPE-PARSER-SINGLE-AUTH-001.

    Semantics (match legacy callers exactly):
      - list  → keep only str elements, coerce each with str()
      - str   → JSON-decode; if result is a list, apply same str-filter
      - other → return []  (fail-open: malformed rows are not policy concerns)

    Return type is list[str] to match the historical callers' type annotation.
    The function is intentionally NOT renamed to use frozenset so existing
    caller logic (e.g. ``if forbidden:`` truthiness checks) remains unchanged.

    @decision DEC-DISCIPLINE-SCOPE-PARSER-SINGLE-AUTH-001
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


# ---------------------------------------------------------------------------
# Path identity normalization
# W-CONV-1: canonical path normalizer — applied at every DB persist/query boundary
# ---------------------------------------------------------------------------


def normalize_path(path: str) -> str:
    """Canonicalize a filesystem path by resolving symlinks and aliases.

    Uses os.path.realpath() which:
      - Resolves symlinks (e.g. /tmp → /private/tmp on macOS)
      - Resolves path aliases (e.g. /var/folders → /private/var/folders)
      - Collapses redundant separators and . / .. components

    This is the sole normalizer for project_root and worktree_path.
    No module may persist or query by a raw path — always call this first.

    Matches the behavior of git rev-parse --show-toplevel, which also
    resolves symlinks before returning the repo root.

    Called at every persist and query boundary for:
      - test_state.set_status / get_status / check_pass
      - workflows.bind_workflow / get_binding
      - leases.issue / get_current (worktree_path)
      - policy_engine.build_context (project_root)
      - cli.py _resolve_project_root / _handle_evaluate
    """
    return os.path.realpath(path)


# ---------------------------------------------------------------------------
# Source extension set
# Matches: hooks/context-lib.sh line 175
# ---------------------------------------------------------------------------

SOURCE_EXTENSIONS: frozenset[str] = frozenset(
    {
        "ts",
        "tsx",
        "js",
        "jsx",
        # Modern JS/TS module variants (DEC-SOURCEEXT-001, ENFORCE-RCA-6)
        "mjs",
        "cjs",
        "mts",
        "cts",
        "py",
        "rs",
        "go",
        "java",
        "kt",
        "swift",
        "c",
        "cpp",
        "h",
        "hpp",
        "cs",
        "rb",
        "php",
        "sh",
        "bash",
        "zsh",
    }
)

SCRATCHLANE_PARENT_REL: str = "tmp/.claude-scratch"

PATH_KIND_META: str = "meta"
PATH_KIND_ARTIFACT: str = "artifact"
PATH_KIND_ARTIFACT_CANDIDATE: str = "artifact_candidate"
PATH_KIND_TMP_SOURCE_CANDIDATE: str = "tmp_source_candidate"
PATH_KIND_GOVERNANCE: str = "governance"
PATH_KIND_CONSTITUTION: str = "constitution"
PATH_KIND_SOURCE: str = "source"
PATH_KIND_OTHER: str = "other"


@dataclass(frozen=True)
class PolicyPathInfo:
    """Canonical classification of a repo-targeted write path."""

    raw_path: str
    normalized_path: str
    repo_relative_path: Optional[str]
    kind: str
    task_slug: str = ""
    scratch_root: str = ""


def scratchlane_parent(project_root: str) -> str:
    """Return the canonical absolute project scratchlane parent."""
    return normalize_path(os.path.join(project_root, SCRATCHLANE_PARENT_REL))


def scratchlane_root(project_root: str, task_slug: str) -> str:
    """Return the canonical absolute root for a task-local scratchlane."""
    return normalize_path(os.path.join(project_root, SCRATCHLANE_PARENT_REL, sanitize_token(task_slug)))


def _strip_worktree_prefix(path: str) -> str:
    normalized = path.replace("\\", "/").lstrip("/")
    parts = normalized.split("/")
    if len(parts) >= 3 and parts[0] == ".worktrees":
        return "/".join(parts[2:])
    return normalized


def to_repo_relative_path(
    path: str,
    project_root: str | None,
    worktree_path: str | None = None,
) -> Optional[str]:
    """Convert a path to a repo-relative POSIX path when possible."""
    if not path:
        return None
    if os.path.isabs(path):
        normalized_path = normalize_path(path)
        if worktree_path:
            canonical_worktree = normalize_path(worktree_path)
            if normalized_path == canonical_worktree:
                return "."
            prefix = canonical_worktree + os.sep
            if normalized_path.startswith(prefix):
                rel = normalized_path[len(prefix) :].lstrip(os.sep).lstrip("/")
                return normalize_repo_path(rel)
        if project_root:
            canonical_root = normalize_path(project_root)
            if normalized_path == canonical_root:
                return "."
            prefix = canonical_root + os.sep
            if normalized_path.startswith(prefix):
                rel = normalized_path[len(prefix) :].lstrip(os.sep).lstrip("/")
                return normalize_repo_path(_strip_worktree_prefix(rel))
        return None
    return normalize_repo_path(_strip_worktree_prefix(path))


def is_governance_repo_path(repo_relative_path: str | None) -> bool:
    """Return True only for canonical governance paths in the repo namespace."""
    if not repo_relative_path:
        return False
    normalized = normalize_repo_path(repo_relative_path)
    if not normalized:
        return False
    if normalized in {"MASTER_PLAN.md", "CLAUDE.md"}:
        return True
    parts = normalized.split("/")
    return len(parts) == 2 and parts[0] in {"agents", "docs"} and parts[1].endswith(".md")


def suggest_scratchlane_task_slug(path: str) -> str:
    """Choose a stable task slug from a target path."""
    p = Path(path)
    if p.suffix:
        stem = p.stem
        if stem:
            return sanitize_token(stem)
    name = p.name or p.parent.name or "task"
    return sanitize_token(name)


def is_tracked_repo_path(project_root: str, repo_relative_path: str | None) -> bool:
    """Return True when ``repo_relative_path`` is tracked by git.

    Scratchlane paths are only safe to treat as artifacts when they are not
    tracked repo files. This helper deliberately lives in policy_utils so the
    write-path and bash-path gates share one tracked-file probe.
    """
    if not project_root or not repo_relative_path:
        return False
    normalized = normalize_repo_path(repo_relative_path)
    if not normalized:
        return False
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                normalize_path(project_root),
                "ls-files",
                "--error-unmatch",
                "--",
                normalized,
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _is_path_under(root: str, path: str) -> bool:
    if not root or not path:
        return False
    canonical_root = normalize_path(root)
    canonical_path = normalize_path(path)
    return canonical_path == canonical_root or canonical_path.startswith(canonical_root + os.sep)


def classify_policy_path(
    path: str,
    *,
    project_root: str = "",
    worktree_path: str = "",
    scratch_roots: tuple[str, ...] | frozenset[str] = (),
) -> PolicyPathInfo:
    """Classify a path for write/governance/artifact policy decisions.

    Classification order is authoritative:
      1. ``meta``               — under ``{project_root}/.claude/``
      2. ``artifact``           — under an approved scratchlane root
      3. ``artifact_candidate`` — under ``tmp/.claude-scratch/`` but not approved
      4. ``governance``         — canonical governance path in repo namespace
      5. ``constitution``       — canonical constitution-level repo path
      6. ``tmp_source_candidate`` — source-looking file under ``tmp/`` outside scratchlane
      7. ``source``             — regular non-skippable source file
      8. ``other``              — anything else
    """
    raw_path = path or ""
    canonical_project_root = normalize_path(project_root) if project_root else ""

    if os.path.isabs(raw_path):
        normalized_path = normalize_path(raw_path)
    elif canonical_project_root:
        normalized_path = normalize_path(os.path.join(canonical_project_root, raw_path))
    else:
        normalized_path = os.path.normpath(raw_path)

    repo_relative_path = to_repo_relative_path(
        normalized_path if os.path.isabs(normalized_path) else raw_path,
        canonical_project_root or None,
        worktree_path or None,
    )

    if canonical_project_root and _is_path_under(os.path.join(canonical_project_root, ".claude"), normalized_path):
        return PolicyPathInfo(
            raw_path=raw_path,
            normalized_path=normalized_path,
            repo_relative_path=repo_relative_path,
            kind=PATH_KIND_META,
        )

    if canonical_project_root:
        scratch_parent_path = scratchlane_parent(canonical_project_root)
        if _is_path_under(scratch_parent_path, normalized_path):
            parts = [part for part in Path(normalized_path).parts if part]
            task_slug = ""
            scratch_parts = Path(scratch_parent_path).parts
            if len(parts) > len(scratch_parts):
                task_slug = sanitize_token(parts[len(scratch_parts)])
            matched_root = ""
            for root in scratch_roots:
                if _is_path_under(root, normalized_path):
                    matched_root = normalize_path(root)
                    break
            return PolicyPathInfo(
                raw_path=raw_path,
                normalized_path=normalized_path,
                repo_relative_path=repo_relative_path,
                kind=PATH_KIND_ARTIFACT if matched_root else PATH_KIND_ARTIFACT_CANDIDATE,
                task_slug=task_slug,
                scratch_root=matched_root or (
                    scratchlane_root(canonical_project_root, task_slug)
                    if task_slug
                    else ""
                ),
            )

    if is_governance_repo_path(repo_relative_path):
        return PolicyPathInfo(
            raw_path=raw_path,
            normalized_path=normalized_path,
            repo_relative_path=repo_relative_path,
            kind=PATH_KIND_GOVERNANCE,
        )

    if repo_relative_path and is_constitution_level(repo_relative_path):
        return PolicyPathInfo(
            raw_path=raw_path,
            normalized_path=normalized_path,
            repo_relative_path=repo_relative_path,
            kind=PATH_KIND_CONSTITUTION,
        )

    if (
        repo_relative_path
        and repo_relative_path.startswith("tmp/")
        and is_source_file(normalized_path)
        and not is_skippable_path(normalized_path)
    ):
        task_slug = suggest_scratchlane_task_slug(normalized_path)
        return PolicyPathInfo(
            raw_path=raw_path,
            normalized_path=normalized_path,
            repo_relative_path=repo_relative_path,
            kind=PATH_KIND_TMP_SOURCE_CANDIDATE,
            task_slug=task_slug,
            scratch_root=scratchlane_root(canonical_project_root, task_slug)
            if canonical_project_root
            else "",
        )

    if is_source_file(normalized_path) and not is_skippable_path(normalized_path):
        return PolicyPathInfo(
            raw_path=raw_path,
            normalized_path=normalized_path,
            repo_relative_path=repo_relative_path,
            kind=PATH_KIND_SOURCE,
        )

    return PolicyPathInfo(
        raw_path=raw_path,
        normalized_path=normalized_path,
        repo_relative_path=repo_relative_path,
        kind=PATH_KIND_OTHER,
    )


def is_source_file(path: str) -> bool:
    """Check if a file has a source code extension.

    Matches: hooks/context-lib.sh:178 is_source_file()
    The shell uses a pipe-delimited regex; we use the frozenset.
    """
    ext = Path(path).suffix.lstrip(".")
    return ext in SOURCE_EXTENSIONS


def is_skippable_path(path: str) -> bool:
    """Check if a path is test/config/generated/vendor and should be skipped.

    Matches: hooks/context-lib.sh:184 is_skippable_path()

    Two groups of patterns (same as shell):
      Group 1 — file-level patterns: .config., .test., .spec., __tests__,
                 .generated., .min.
      Group 2 — directory-level patterns: node_modules, vendor, dist, build,
                 .next, __pycache__, .git
    """
    # Group 1: file-level markers
    if re.search(r"(\.config\.|\.test\.|\.spec\.|__tests__|\.generated\.|\.min\.)", path):
        return True
    # Group 2: directory-level markers
    if re.search(r"(node_modules|vendor|dist|build|\.next|__pycache__|\.git)", path):
        return True
    return False


def is_governance_markdown(filepath: str) -> bool:
    """Check if a file is a governance markdown file.

    Matches: hooks/plan-guard.sh:47 is_governance_markdown()

    Governance files:
      1. MASTER_PLAN.md — exact filename
      2. CLAUDE.md — exact filename
      3. agents/*.md — .md file with immediate parent directory named "agents"
      4. docs/*.md — .md file with immediate parent directory named "docs"

    Matching is by basename + immediate parent dir name, not by absolute path.
    """
    p = Path(filepath)
    base = p.name
    parent = p.parent.name

    if base == "MASTER_PLAN.md":
        return True
    if base == "CLAUDE.md":
        return True
    if parent == "agents" and base.endswith(".md"):
        return True
    if parent == "docs" and base.endswith(".md"):
        return True
    return False


def is_claude_meta_repo(dir_path: str) -> bool:
    """Check if a directory is the ~/.claude meta repo (or a worktree of it).

    Matches: hooks/context-lib.sh is_claude_meta_repo()

    Three-check strategy mirrors the shell version exactly:
      1. CLAUDE_PROJECT_DIR env var (realpath-dereferenced to defeat
         dual-checkout symlinks).
      2. git --show-toplevel ending in /.claude (main checkout).
      3. git --git-common-dir ending in /.claude/.git (worktrees of the
         meta-repo — fixes #163/#143 where worktree toplevel ends in a
         feature branch name, not /.claude).

    @decision DEC-META-001
    Title: Use --git-common-dir to detect meta-repo worktrees
    Status: accepted
    Rationale: git --show-toplevel returns the worktree root (e.g.
      ~/.claude/.worktrees/feature-foo), not the shared repo root.
      --git-common-dir always returns the shared .git path which ends in
      /.claude/.git for any worktree of the meta-repo. Fixes #163/#143.

    @decision DEC-META-002
    Title: CLAUDE_PROJECT_DIR is realpath-dereferenced before the /.claude
      suffix check (ENFORCE-RCA-11)
    Status: accepted
    Rationale: The prior check trusted the literal string suffix. When a
      non-meta-repo is accessed via a symlink named `.claude` — e.g. the
      dual-checkout setup where `~/.claude` is a symlink to a regular
      project repo like `~/Code/…/claude-ctrl-hardFork` — the unresolved
      literal ended with `/.claude`, so is_claude_meta_repo returned True
      and every bash_main_sacred / write policy that consults
      request.context.is_meta_repo bypassed enforcement for that session.
      Empirically verified on 2026-04-07: `git commit --allow-empty` on
      main was allowed via the symlink path but denied via the realpath
      (ENFORCE-RCA-11). Realpath-dereferencing CLAUDE_PROJECT_DIR before
      the suffix check fixes the symlink case without breaking the
      original "env var is the fastest path" intent — if the env var
      already points to a real /.claude path, realpath is idempotent.
    """
    claude_project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if claude_project_dir:
        try:
            resolved = os.path.realpath(claude_project_dir)
        except OSError:
            resolved = claude_project_dir
        if resolved.endswith("/.claude"):
            return True

    try:
        # Check 2: git toplevel (main checkout of the meta-repo)
        result = subprocess.run(
            ["git", "-C", dir_path, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip().endswith("/.claude"):
            return True

        # Check 3: git common dir (worktrees of the meta-repo)
        result = subprocess.run(
            ["git", "-C", dir_path, "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip().endswith("/.claude/.git"):
            return True
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return False


def detect_project_root(cwd: str = "") -> str:
    """Detect project root via git rev-parse --show-toplevel.

    Matches: hooks/log.sh:50 detect_project_root()

    Resolution order:
      1. CLAUDE_PROJECT_DIR env var (if set and is a directory)
      2. git rev-parse --show-toplevel from cwd (or CWD if empty)
      3. HOME as last resort

    All return values are normalized via normalize_path() (DEC-CONV-001) so
    the caller always receives a canonical realpath form, regardless of whether
    git, the env var, or HOME was used to resolve it.
    """
    claude_project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if claude_project_dir and os.path.isdir(claude_project_dir):
        return normalize_path(claude_project_dir)

    effective_cwd = cwd or os.getcwd()
    if os.path.isdir(effective_cwd):
        try:
            result = subprocess.run(
                ["git", "-C", effective_cwd, "rev-parse", "--show-toplevel"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0:
                root = result.stdout.strip()
                if root and os.path.isdir(root):
                    return normalize_path(root)
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass

    return normalize_path(os.environ.get("HOME", "/"))


def extract_git_target_dir(command: str, cwd: str = "") -> str:
    """Extract the git working directory from a command string.

    Matches: hooks/guard.sh:101 extract_git_target_dir()

    Resolution order:
      Pattern A: cd /path && git ... (unquoted/single/double-quoted)
      Pattern B: git -C /path ...
      Fallback: cwd parameter

    Unlike the shell version, we do NOT fall back to detect_project_root()
    as a final fallback — we use the cwd parameter the caller provides.
    Relative targets are resolved against cwd via resolve_path_from_base()
    before existence checks so runtime-owned intent parsing can honor
    ``git -C .worktrees/foo ...`` and ``cd ./repo && git ...`` correctly.
    """
    base = cwd or os.getcwd()

    def _resolve_existing(candidate: str) -> str:
        if not candidate:
            return ""
        resolved = resolve_path_from_base(base, candidate)
        if resolved and os.path.isdir(resolved):
            return normalize_path(resolved)
        return ""

    # Pattern A: cd ... (double-quoted, single-quoted, or unquoted)
    m = re.search(
        r'cd\s+("([^"]+)"|\'([^\']+)\'|([^\s&;]+))',
        command,
    )
    if m:
        candidate = m.group(2) or m.group(3) or m.group(4) or ""
        resolved = _resolve_existing(candidate)
        if resolved:
            return resolved

    # Pattern B: git -C ... (double-quoted, single-quoted, or unquoted)
    m = re.search(
        r'git\s+-C\s+("([^"]+)"|\'([^\']+)\'|([^\s]+))',
        command,
    )
    if m:
        candidate = m.group(2) or m.group(3) or m.group(4) or ""
        resolved = _resolve_existing(candidate)
        if resolved:
            return resolved

    # Fallback: use cwd
    return cwd


def extract_cd_target(command: str) -> Optional[str]:
    """Extract the cd target directory from a command string.

    Matches: hooks/guard.sh:58 extract_cd_target()

    Returns the first cd target found (double-quoted, single-quoted,
    or unquoted), or None if no cd is found.
    """
    m = re.search(
        r'(?:^|[;&|]\s*)cd\s+("([^"]+)"|\'([^\']+)\'|([^\s&;|]+))',
        command,
    )
    if m:
        return m.group(2) or m.group(3) or m.group(4) or None
    return None


def sanitize_token(raw: str) -> str:
    """Sanitize a string for use as a workflow ID token.

    Matches: hooks/context-lib.sh:207 sanitize_token()

    Steps (same as shell tr/tr -cd pipeline):
      1. Replace '/', ':', and ' ' with '-'
      2. Strip characters that are not alphanumeric, '.', '_', or '-'
      3. Default to 'default' if empty
    """
    if not raw:
        return "default"
    # Step 1: replace /, :, and space with -
    result = re.sub(r"[/: ]", "-", raw)
    # Step 2: strip non-alphanum (keep . _ -)
    result = re.sub(r"[^a-zA-Z0-9._-]", "", result)
    return result if result else "default"


def current_workflow_id(project_root: str = "") -> str:
    """Derive workflow ID from git branch name or project root basename.

    Matches: hooks/context-lib.sh:214 current_workflow_id()

    Resolution:
      1. Get current branch name from git
      2. If branch is non-empty and not "HEAD", sanitize it
      3. Otherwise sanitize the basename of project_root
    """
    root = project_root or detect_project_root()
    try:
        result = subprocess.run(
            ["git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            branch = result.stdout.strip()
            if branch and branch != "HEAD":
                return sanitize_token(branch)
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass

    return sanitize_token(os.path.basename(root))


def resolve_path_from_base(base: str, candidate: str) -> str:
    """Resolve a possibly-relative path against a base directory.

    Matches: hooks/guard.sh lines 42-56 resolve_path_from_base()

    If candidate is home-relative (~ or ~user), expand it first.
    If candidate is absolute, return it unchanged.
    If candidate is relative, resolve it against base using os.path.realpath
    so symlinks are resolved (equivalent to the shell's pwd -P).
    Returns the candidate unchanged if resolution fails.
    """
    if candidate.startswith("~"):
        return os.path.expanduser(candidate)

    if os.path.isabs(candidate):
        return candidate

    try:
        # Resolve base directory first, then join with the candidate's parent
        # and re-attach the basename — mirrors the shell's cd/pwd -P approach.
        parent = os.path.dirname(candidate) or "."
        name = os.path.basename(candidate)
        resolved_parent = os.path.realpath(os.path.join(base, parent))
        return os.path.join(resolved_parent, name)
    except (OSError, ValueError):
        return candidate


def extract_merge_ref(command: str) -> Optional[str]:
    """Extract the first non-flag token after 'merge' in a git command.

    Matches: hooks/guard.sh lines 66-82 extract_merge_ref()

    Tokenises the command on whitespace, finds 'merge', then returns the
    first following token that does not start with '-'. Returns None if
    no such token is found.

    Examples:
      'git merge feature/my-branch'   → 'feature/my-branch'
      'git merge --no-ff feature/foo' → 'feature/foo'
      'git merge --abort'             → None
      'git merge'                     → None
    """
    tokens = command.split()
    saw_merge = False
    for token in tokens:
        if token == "merge":
            saw_merge = True
            continue
        if saw_merge:
            if token.startswith("-"):
                continue
            return token
    return None

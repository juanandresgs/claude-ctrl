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
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from typing import Optional

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
    """Check if a directory is the ~/.claude meta repo.

    Matches: hooks/context-lib.sh:426 is_claude_meta_repo()

    Checks CLAUDE_PROJECT_DIR env var first (because symlinks cause git to
    resolve to the real path, bypassing the /.claude suffix check).
    Falls back to git toplevel ending in /.claude.
    """
    claude_project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if claude_project_dir.endswith("/.claude"):
        return True

    # Fallback: resolve git toplevel and check suffix
    try:
        result = subprocess.run(
            ["git", "-C", dir_path, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            repo_root = result.stdout.strip()
            return repo_root.endswith("/.claude")
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
    """
    claude_project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if claude_project_dir and os.path.isdir(claude_project_dir):
        return claude_project_dir

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
                    return root
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass

    return os.environ.get("HOME", "/")


def extract_git_target_dir(command: str, cwd: str = "") -> str:
    """Extract the git working directory from a command string.

    Matches: hooks/guard.sh:101 extract_git_target_dir()

    Resolution order:
      Pattern A: cd /path && git ... (unquoted/single/double-quoted)
      Pattern B: git -C /path ...
      Fallback: cwd parameter

    Unlike the shell version, we do NOT fall back to detect_project_root()
    as a final fallback — we use the cwd parameter the caller provides.
    This keeps the function pure (no subprocess calls unless the patterns
    matched a real path that needs existence-checking).
    """
    # Pattern A: cd ... (double-quoted, single-quoted, or unquoted)
    m = re.search(
        r'cd\s+("([^"]+)"|\'([^\']+)\'|([^\s&;]+))',
        command,
    )
    if m:
        candidate = m.group(2) or m.group(3) or m.group(4) or ""
        if candidate and os.path.isdir(candidate):
            return candidate

    # Pattern B: git -C ... (double-quoted, single-quoted, or unquoted)
    m = re.search(
        r'git\s+-C\s+("([^"]+)"|\'([^\']+)\'|([^\s]+))',
        command,
    )
    if m:
        candidate = m.group(2) or m.group(3) or m.group(4) or ""
        if candidate and os.path.isdir(candidate):
            return candidate

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

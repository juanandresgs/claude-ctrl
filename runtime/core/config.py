"""Runtime configuration helpers.

@decision DEC-SELF-003
@title Canonical DB resolver
@status accepted
@rationale TKT-022: split authority existed between ~/.claude/state.db and
  project .claude/state.db. Hook calls from inside a project were writing proof
  state to the home DB while guard.sh was reading from the project DB (or vice
  versa), causing proof-not-found denials when the proof was real. The resolver
  family unifies all DB resolution into a single code path with deterministic
  priority. All paths that previously called Path.home() / ".claude" / "state.db"
  now go through default_db_path() or resolve_db_path(). Adjacent components:
  runtime/cli.py imports this; guard.sh uses CLAUDE_POLICY_DB env (step 1
  override); log.sh sets CLAUDE_PROJECT_DIR (step 3 optimization to avoid git
  subprocess per call).
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


def _forbidden_policy_db_override(path: Path) -> bool:
    """Return True when ``path`` is a known-invalid policy DB override.

    ``runtime/policy.db`` surfaced in the field as an empty untracked artifact
    that poisoned carrier/bootstrap routing. The runtime state DB authority is
    ``state.db`` under ``.claude/``; ``policy.db`` is not a valid override.
    """
    return path.expanduser().name == "policy.db"


def resolve_project_db() -> Path | None:
    """Detect project DB from git root.

    Runs `git rev-parse --show-toplevel` in CWD. If the git root contains a
    `.claude/` directory, returns `<git-root>/.claude/state.db`. Returns None
    if not in a git repo, no .claude/ dir exists, or git is unavailable.

    This is the git-discovery helper for the canonical resolver family. Direct
    callers should prefer default_db_path() / resolve_db_path() for the full
    priority order.
    """
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            git_root = Path(result.stdout.strip())
            claude_dir = git_root / ".claude"
            if claude_dir.is_dir():
                return claude_dir / "state.db"
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return None


def resolve_db_path(project_root: str | None = None) -> Path:
    """Canonical DB resolver with optional explicit project-root hint.

    Priority (highest to lowest):

    1. CLAUDE_POLICY_DB env var — explicit override, always wins. Used by
       test harnesses and CI to point at a specific DB file.

    2. Explicit ``project_root`` argument — used by commands that are operating
       on a repo/worktree other than the caller's cwd. This keeps bootstrap and
       other explicit-target commands on the same DB authority as the target
       repo instead of whatever ambient session repo happens to be active.

    3. CLAUDE_PROJECT_DIR env var — set by hooks/log.sh auto-export. Avoids
       a git subprocess per cc_policy call when the project root is already
       known. Must point to an existing directory; non-existent paths fall
       through to step 4.

    4. CWD inside a git repo with .claude/ dir — subprocess git detection.
       Covers direct `python3 runtime/cli.py` invocations from a project CWD
       where CLAUDE_PROJECT_DIR was not pre-exported by a hook.

    5. ~/.claude/state.db — global fallback for non-project contexts
       (global config queries, outside-git CWDs, fresh installs).

    This is the sole resolver family. ``default_db_path()`` is the no-arg
    wrapper used by callers that have no explicit repo hint.
    """
    # Step 1: explicit override
    override = os.environ.get("CLAUDE_POLICY_DB")
    if override:
        override_path = Path(override).expanduser()
        if not _forbidden_policy_db_override(override_path):
            return override_path

    # Step 2: explicit project root supplied by the caller.
    if project_root:
        project_path = Path(project_root)
        if project_path.is_dir():
            return Path(os.path.realpath(project_root)) / ".claude" / "state.db"

    # Step 3: project dir env var (hook-exported, avoids git subprocess)
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if project_dir:
        project_path = Path(project_dir)
        if project_path.is_dir():
            return project_path / ".claude" / "state.db"

    # Step 4: git root detection (direct CLI invocation path)
    project_db = resolve_project_db()
    if project_db is not None:
        return project_db

    # Step 5: global fallback
    return Path.home() / ".claude" / "state.db"


def default_db_path() -> Path:
    """Canonical no-arg DB resolver.

    Priority (highest to lowest):

    1. CLAUDE_POLICY_DB env var — explicit override, always wins. Used by
       test harnesses and CI to point at a specific DB file.

    2. CLAUDE_PROJECT_DIR env var — set by hooks/log.sh auto-export. Avoids
       a git subprocess per cc_policy call when the project root is already
       known. Must point to an existing directory; non-existent paths fall
       through to step 3.

    3. CWD inside a git repo with .claude/ dir — subprocess git detection.
       Covers direct `python3 runtime/cli.py` invocations from a project CWD
       where CLAUDE_PROJECT_DIR was not pre-exported by a hook.

    4. ~/.claude/state.db — global fallback for non-project contexts
       (global config queries, outside-git CWDs, fresh installs).

    @decision DEC-SELF-003
    """
    return resolve_db_path()

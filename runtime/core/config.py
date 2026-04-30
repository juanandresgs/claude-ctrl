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


def _resolve_shared_git_root(path: Path) -> Path | None:
    """Resolve the shared checkout root for a git repo or linked worktree.

    For a normal checkout, ``git rev-parse --git-common-dir`` resolves to the
    repo's ``.git`` directory, so the shared root is its parent. For a linked
    worktree, ``--git-common-dir`` still points at the shared ``<repo>/.git``
    rather than the feature worktree's private admin dir. This keeps all
    worktrees on the repo-level ``.claude/state.db`` authority instead of
    accidentally routing feature worktrees into ``<worktree>/.claude/state.db``.
    """
    candidate = Path(os.path.realpath(str(path.expanduser())))
    try:
        result = subprocess.run(
            ["git", "-C", str(candidate), "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            common_dir = result.stdout.strip()
            if common_dir:
                common_path = Path(common_dir)
                if not common_path.is_absolute():
                    common_path = (candidate / common_path).resolve()
                shared_root = common_path.parent
                if shared_root.is_dir():
                    return shared_root
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass

    try:
        result = subprocess.run(
            ["git", "-C", str(candidate), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            root = result.stdout.strip()
            if root:
                shared_root = Path(os.path.realpath(root))
                if shared_root.is_dir():
                    return shared_root
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass

    return None


def resolve_project_db(cwd: str | None = None) -> Path | None:
    """Detect project DB from the shared root of the current git checkout.

    Uses the shared-root resolver so linked worktrees resolve to the repo-level
    ``.claude/state.db`` authority rather than a private feature-worktree path.
    If the shared root contains a `.claude/` directory, returns
    `<shared-root>/.claude/state.db`. Returns None if not in a git repo, no
    `.claude/` dir exists, or git is unavailable.

    This is the git-discovery helper for the canonical resolver family. Direct
    callers should prefer default_db_path() / resolve_db_path() for the full
    priority order.
    """
    shared_root = _resolve_shared_git_root(Path(cwd or os.getcwd()))
    if shared_root is not None:
        claude_dir = shared_root / ".claude"
        if claude_dir.is_dir():
            return claude_dir / "state.db"
    return None


def resolve_db_path(project_root: str | None = None) -> Path:
    """Canonical DB resolver with optional explicit project-root hint.

    Priority (highest to lowest):

    1. CLAUDE_POLICY_DB env var — explicit override, always wins. Used by
       test harnesses and CI to point at a specific DB file.

    2. Explicit ``project_root`` argument — used by commands that are operating
       on a repo/worktree other than the caller's cwd. Worktree paths collapse
       to the shared repo root before the DB path is chosen, so feature
       worktrees stay on the repo-level state DB authority.

    3. CLAUDE_PROJECT_DIR env var — set by hooks/log.sh auto-export. Avoids
       a git subprocess per cc_policy call when the project root is already
       known. If it points at a linked worktree, the shared repo root still
       wins. Non-existent paths fall through to step 4.

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
            shared_root = _resolve_shared_git_root(project_path)
            if shared_root is not None:
                return shared_root / ".claude" / "state.db"
            return Path(os.path.realpath(project_root)) / ".claude" / "state.db"

    # Step 3: project dir env var (hook-exported, avoids git subprocess)
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if project_dir:
        project_path = Path(project_dir)
        if project_path.is_dir():
            shared_root = _resolve_shared_git_root(project_path)
            if shared_root is not None:
                return shared_root / ".claude" / "state.db"
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

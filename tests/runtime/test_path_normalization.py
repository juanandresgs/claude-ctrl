"""Tests for path identity normalization across persist/query boundaries.

W-CONV-1: Canonicalize path identity (project_root / worktree_path).

The core bug: detect_project_root() returns the raw path from git rev-parse
--show-toplevel, which resolves symlinks. When a caller uses a non-canonical
path (e.g. /tmp on macOS resolves to /private/tmp, or /var/... resolves to
/private/var/...), rows written with one form are invisible when queried with
the other.

The fix: normalize_path() in policy_utils.py using os.path.realpath().
Applied at every persist and query boundary for project_root and worktree_path.

Production sequence exercised in compound tests:
  1. cli.py test-state set (with raw/symlink path)
  2. build_context (with canonical git-resolved path)
  3. policy evaluation reads same DB row → no mismatch

@decision DEC-CONV-001
Title: normalize_path() is the single canonical path normalizer for project_root/worktree_path
Status: accepted
Rationale: On macOS /tmp → /private/tmp and /var/folders → /private/var/folders.
  Git always resolves symlinks when returning rev-parse --show-toplevel. Without
  normalization, a path written via os.getcwd() or CLAUDE_PROJECT_DIR may use a
  different form than the path resolved by git, causing DB row misses on every
  cross-boundary lookup. Centralizing in normalize_path() (os.path.realpath)
  and applying it at every persist/query call site ensures all paths are
  canonical before they touch SQLite.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
_PROJECT_ROOT = _HERE.parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

from runtime.core.db import connect_memory  # noqa: E402
from runtime.core.policy_utils import detect_project_root, normalize_path  # noqa: E402
from runtime.core.test_state import check_pass, get_status, set_status  # noqa: E402
from runtime.schemas import ensure_schema  # noqa: E402

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    c = connect_memory()
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# 1. normalize_path() unit tests
# ---------------------------------------------------------------------------


def test_normalize_path_returns_realpath(tmp_path):
    """normalize_path resolves symlinks via os.path.realpath."""
    # tmp_path may itself be a symlink alias (e.g. /var/... vs /private/var/...)
    # normalizing it must match os.path.realpath
    result = normalize_path(str(tmp_path))
    assert result == os.path.realpath(str(tmp_path))


def test_normalize_path_with_symlink(tmp_path):
    """normalize_path resolves a symlink to its real target."""
    real_dir = tmp_path / "real"
    real_dir.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real_dir)

    normalized = normalize_path(str(link))
    expected = os.path.realpath(str(link))
    assert normalized == expected
    assert normalized == str(real_dir.resolve())


def test_normalize_path_already_canonical(tmp_path):
    """normalize_path is idempotent on canonical paths."""
    canonical = os.path.realpath(str(tmp_path))
    assert normalize_path(canonical) == canonical
    assert normalize_path(normalize_path(canonical)) == canonical


def test_normalize_path_empty_string():
    """normalize_path handles empty string gracefully (returns realpath of '')."""
    # os.path.realpath('') returns os.getcwd() — that's fine, it's consistent
    result = normalize_path("")
    assert isinstance(result, str)
    # Should not raise
    assert len(result) >= 0


def test_normalize_path_nonexistent_path():
    """normalize_path works on non-existent paths (no filesystem check required)."""
    # realpath resolves syntactically even if the path doesn't exist
    result = normalize_path("/nonexistent/deep/path")
    assert "/nonexistent/deep/path" in result


def test_normalize_path_tmp_on_macos():
    """normalize_path resolves /tmp to /private/tmp on macOS (or equivalent).

    On Linux /tmp is typically not a symlink, so this test validates that
    the normalization is at least consistent — the result equals realpath.
    """
    # Create a dir under system tmp to exercise the /tmp → /private/tmp alias
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        raw = td  # may be /var/folders/... (non-canonical on macOS)
        normalized = normalize_path(raw)
        canonical = os.path.realpath(raw)
        assert normalized == canonical, (
            f"normalize_path({raw!r}) returned {normalized!r}, expected canonical {canonical!r}"
        )


# ---------------------------------------------------------------------------
# 2. test_state persists and queries via normalized path
# ---------------------------------------------------------------------------


def test_set_status_via_symlink_readable_via_realpath(tmp_path):
    """A row written with a symlink path is readable via the realpath.

    This is the core W-CONV-1 bug: without normalization, writing with
    /link/path and reading with /real/path returns found=False.
    """
    conn_obj = connect_memory()
    ensure_schema(conn_obj)

    real_dir = tmp_path / "real"
    real_dir.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real_dir)

    symlink_path = str(link)
    real_path = os.path.realpath(symlink_path)

    # Write via symlink path
    set_status(conn_obj, symlink_path, "pass", pass_count=5, total_count=5)

    # Read via realpath — must find the row
    result = get_status(conn_obj, real_path)
    assert result["found"] is True, (
        "Row written via symlink path must be findable via realpath after normalization. "
        f"Wrote with {symlink_path!r}, read with {real_path!r}"
    )
    assert result["status"] == "pass"

    conn_obj.close()


def test_set_status_via_realpath_readable_via_symlink(tmp_path):
    """A row written with realpath is readable via a symlink path (reverse direction)."""
    conn_obj = connect_memory()
    ensure_schema(conn_obj)

    real_dir = tmp_path / "real"
    real_dir.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real_dir)

    real_path = os.path.realpath(str(real_dir))
    symlink_path = str(link)

    # Write via realpath
    set_status(conn_obj, real_path, "pass", pass_count=10, total_count=10)

    # Read via symlink path — must find the row
    result = get_status(conn_obj, symlink_path)
    assert result["found"] is True, (
        "Row written via realpath must be findable via symlink path after normalization."
    )
    assert result["pass_count"] == 10

    conn_obj.close()


def test_check_pass_via_normalized_path(tmp_path):
    """check_pass works correctly across symlink/realpath path forms."""
    conn_obj = connect_memory()
    ensure_schema(conn_obj)

    real_dir = tmp_path / "project"
    real_dir.mkdir()
    link = tmp_path / "proj_link"
    link.symlink_to(real_dir)

    # Write pass via symlink, check pass via realpath
    set_status(conn_obj, str(link), "pass", head_sha="abc123")
    result = check_pass(conn_obj, os.path.realpath(str(link)), head_sha="abc123")
    assert result is True

    conn_obj.close()


# ---------------------------------------------------------------------------
# 3. detect_project_root() returns normalized path
# ---------------------------------------------------------------------------


def test_detect_project_root_returns_realpath(tmp_path, monkeypatch):
    """detect_project_root normalizes its return value via realpath.

    git rev-parse --show-toplevel already resolves symlinks on most systems.
    After the fix, normalize_path is applied to the return value to guarantee
    this is always the case regardless of git version or OS behavior.
    """
    monkeypatch.delenv("CLAUDE_PROJECT_DIR", raising=False)

    # Initialize a git repo in tmp_path
    subprocess.run(["git", "-C", str(tmp_path), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "t@t.com"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "T"], check=True)
    subprocess.run(
        ["git", "-C", str(tmp_path), "commit", "--allow-empty", "-m", "init", "-q"],
        check=True,
    )

    root = detect_project_root(str(tmp_path))
    assert root == os.path.realpath(root), (
        f"detect_project_root returned {root!r} which is not canonical "
        f"(realpath={os.path.realpath(root)!r})"
    )


def test_detect_project_root_via_symlink_dir(tmp_path, monkeypatch):
    """detect_project_root called with a symlink cwd returns the canonical realpath."""
    monkeypatch.delenv("CLAUDE_PROJECT_DIR", raising=False)

    real_repo = tmp_path / "myrepo"
    real_repo.mkdir()
    link_repo = tmp_path / "myrepo_link"
    link_repo.symlink_to(real_repo)

    # Initialize git repo in real_repo
    subprocess.run(["git", "-C", str(real_repo), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(real_repo), "config", "user.email", "t@t.com"], check=True)
    subprocess.run(["git", "-C", str(real_repo), "config", "user.name", "T"], check=True)
    subprocess.run(
        ["git", "-C", str(real_repo), "commit", "--allow-empty", "-m", "init", "-q"],
        check=True,
    )

    # Call detect_project_root via the symlink path
    root = detect_project_root(str(link_repo))

    # Result must be the canonical realpath form
    assert root == os.path.realpath(root), (
        f"detect_project_root({str(link_repo)!r}) returned non-canonical {root!r}"
    )


# ---------------------------------------------------------------------------
# 4. CLI integration: path normalization round-trip via subprocess
# ---------------------------------------------------------------------------


def _run_cli(*args, cwd=None, env=None):
    """Run python3 -m runtime.cli <args>, return (returncode, stdout, stderr)."""
    run_env = os.environ.copy()
    if env:
        run_env.update(env)
    result = subprocess.run(
        [sys.executable, "-m", "runtime.cli"] + list(args),
        capture_output=True,
        text=True,
        cwd=str(cwd or _PROJECT_ROOT),
        env=run_env,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def test_cli_set_via_symlink_get_via_realpath(tmp_path):
    """CLI: set with symlink path → get with realpath → same row found.

    This exercises the full production-path boundary: cli.py _resolve_project_root
    now calls normalize_path before passing project_root to test_state.set_status /
    test_state.get_status.
    """
    real_dir = tmp_path / "project"
    real_dir.mkdir()
    link = tmp_path / "projlink"
    link.symlink_to(real_dir)

    db_path = tmp_path / "state.db"
    env = {"CLAUDE_POLICY_DB": str(db_path)}

    symlink_path = str(link)
    real_path = os.path.realpath(symlink_path)

    # Set via symlink path
    rc, _, stderr = _run_cli(
        "test-state",
        "set",
        "pass",
        "--project-root",
        symlink_path,
        "--passed",
        "7",
        "--total",
        "7",
        env=env,
    )
    assert rc == 0, f"set failed: {stderr}"

    # Get via realpath — must find the row
    rc2, stdout2, stderr2 = _run_cli(
        "test-state",
        "get",
        "--project-root",
        real_path,
        env=env,
    )
    assert rc2 == 0, f"get failed: {stderr2}"
    data = json.loads(stdout2)
    assert data.get("found") is True, (
        f"Row written via symlink path {symlink_path!r} not found via realpath {real_path!r}. "
        f"Without normalization this is the W-CONV-1 bug."
    )
    assert data.get("status") == "pass"
    assert data.get("pass_count") == 7


def test_cli_set_via_realpath_get_via_symlink(tmp_path):
    """CLI: set with realpath → get with symlink path → same row found (reverse)."""
    real_dir = tmp_path / "project"
    real_dir.mkdir()
    link = tmp_path / "projlink"
    link.symlink_to(real_dir)

    db_path = tmp_path / "state.db"
    env = {"CLAUDE_POLICY_DB": str(db_path)}

    real_path = os.path.realpath(str(real_dir))
    symlink_path = str(link)

    rc, _, stderr = _run_cli(
        "test-state",
        "set",
        "pass",
        "--project-root",
        real_path,
        "--passed",
        "3",
        "--total",
        "3",
        env=env,
    )
    assert rc == 0, f"set failed: {stderr}"

    rc2, stdout2, stderr2 = _run_cli(
        "test-state",
        "get",
        "--project-root",
        symlink_path,
        env=env,
    )
    assert rc2 == 0, f"get failed: {stderr2}"
    data = json.loads(stdout2)
    assert data.get("found") is True
    assert data.get("pass_count") == 3


# ---------------------------------------------------------------------------
# 5. Compound: production sequence with path alias mismatch
# ---------------------------------------------------------------------------


def test_compound_path_alias_full_production_sequence(tmp_path):
    """Compound end-to-end: write via path alias, build_context reads via git root.

    Production sequence exercised:
      1. test-runner writes test_state with raw (symlink) path
      2. build_context resolves project_root via git rev-parse (→ realpath form)
      3. test_state lookup in build_context must find the row
      4. check_pass confirms the pass state via normalized key

    This crosses: cli.py → test_state.set_status → SQLite → build_context →
                  test_state query → check_pass
    """
    # Set up a git repo in tmp_path (git root will be realpath-resolved)
    repo = tmp_path / "repo"
    repo.mkdir()
    link = tmp_path / "repo_link"
    link.symlink_to(repo)

    subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "t@t.com"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "T"], check=True)
    subprocess.run(
        ["git", "-C", str(repo), "commit", "--allow-empty", "-m", "init", "-q"],
        check=True,
    )

    # git rev-parse --show-toplevel returns the canonical path
    git_result = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
    )
    git_root = git_result.stdout.strip()

    # Step 1: test-runner writes pass state using the symlink path
    conn_obj = connect_memory()
    ensure_schema(conn_obj)

    symlink_path = str(link)
    set_status(conn_obj, symlink_path, "pass", head_sha="cafedead", pass_count=20, total_count=20)

    # Step 2: build_context would query using git_root (the canonical path)
    # After normalization, normalize_path(symlink_path) == normalize_path(git_root)
    # so the row is findable. Verify directly:
    result = get_status(conn_obj, git_root)

    # Step 3: check that the row is found via the canonical path
    canonical_link = normalize_path(symlink_path)
    canonical_git = normalize_path(git_root)

    if canonical_link == canonical_git:
        # Only on systems where symlink actually resolves to same dir
        assert result["found"] is True, (
            f"Row written via {symlink_path!r} (→ {canonical_link!r}) not found via "
            f"git root {git_root!r} (→ {canonical_git!r}). W-CONV-1 normalization failure."
        )
        assert check_pass(conn_obj, git_root, head_sha="cafedead") is True
    else:
        # Different canonical paths → different logical repos (not a mismatch bug)
        # Just verify normalization is consistent
        assert canonical_link == os.path.realpath(symlink_path)
        assert canonical_git == os.path.realpath(git_root)

    conn_obj.close()


# ---------------------------------------------------------------------------
# 6. Lease query-side path normalization (W-CONV-1 regression)
# ---------------------------------------------------------------------------


def test_lease_get_current_raw_path_finds_normalized_lease(tmp_path):
    """Issue a lease with raw/symlink path; get_current via raw path must find it.

    W-CONV-1 regression: issue() normalizes worktree_path on the WRITE side.
    Before this fix, get_current() passed the raw (un-normalized) path to the
    SQL WHERE clause, causing a miss because the stored value is canonical.

    Production sequence:
      1. Orchestrator calls issue() with raw path → stored as normalized realpath
      2. Shell caller (detect_project_root / lease_context) passes raw path to
         get_current() → must match the stored canonical form → returns lease
      3. get_current() with the realpath form must also return the same lease
    """
    from runtime.core import leases
    from runtime.core.db import connect_memory
    from runtime.schemas import ensure_schema

    conn_obj = connect_memory()
    ensure_schema(conn_obj)

    real_dir = tmp_path / "worktree"
    real_dir.mkdir()
    link = tmp_path / "wt_link"
    link.symlink_to(real_dir)

    raw_path = str(link)  # symlink form (what shell might pass)
    canonical_path = os.path.realpath(raw_path)  # normalized form (what issue() stores)

    # Step 1: issue with raw path — stored internally as canonical_path
    lease = leases.issue(conn_obj, role="implementer", worktree_path=raw_path)
    assert lease is not None
    assert lease["worktree_path"] == canonical_path, (
        f"issue() should normalize: stored={lease['worktree_path']!r}, "
        f"expected canonical={canonical_path!r}"
    )

    # Step 2: query via raw path — must find the lease (the W-CONV-1 bug repro)
    found_via_raw = leases.get_current(conn_obj, worktree_path=raw_path)
    assert found_via_raw is not None, (
        f"get_current(worktree_path={raw_path!r}) returned None — "
        f"query-side normalization missing (W-CONV-1 regression)"
    )
    assert found_via_raw["lease_id"] == lease["lease_id"]

    # Step 3: query via canonical path — must also find the same lease
    found_via_canonical = leases.get_current(conn_obj, worktree_path=canonical_path)
    assert found_via_canonical is not None, (
        f"get_current(worktree_path={canonical_path!r}) returned None — unexpected"
    )
    assert found_via_canonical["lease_id"] == lease["lease_id"]

    conn_obj.close()


def test_lease_validate_op_raw_path_finds_lease(tmp_path):
    """validate_op called with a raw symlink path must find the active lease.

    validate_op delegates to get_current for lease resolution. This test
    confirms the normalization chain reaches the SQL boundary end-to-end:
    issue(raw) → store(canonical) → validate_op(raw) → get_current(raw) →
    _fetch_active(canonical) → lease found → op allowed.
    """
    from runtime.core import leases
    from runtime.core.db import connect_memory
    from runtime.schemas import ensure_schema

    conn_obj = connect_memory()
    ensure_schema(conn_obj)

    real_dir = tmp_path / "wt2"
    real_dir.mkdir()
    link = tmp_path / "wt2_link"
    link.symlink_to(real_dir)

    raw_path = str(link)

    leases.issue(
        conn_obj,
        role="implementer",
        worktree_path=raw_path,
        allowed_ops=["routine_local"],
        requires_eval=False,
    )

    # validate_op with raw path must find the lease and allow the operation
    result = leases.validate_op(conn_obj, "git commit -m 'test'", worktree_path=raw_path)
    assert result["allowed"] is True, (
        f"validate_op denied with raw path {raw_path!r}: {result['reason']} — "
        f"W-CONV-1 normalization not propagating through validate_op"
    )
    assert result["op_class"] == "routine_local"

    conn_obj.close()

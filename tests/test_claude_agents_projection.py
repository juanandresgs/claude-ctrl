"""Deterministic temp-repo coverage for the agents/ -> .claude/agents projection.

@decision DEC-CLAUDEX-AGENTS-PROJECTION-001
Title: agents/ is the sole authority; .claude/agents is a local derived
  projection and MUST NOT become a tracked or assumed source of truth.
Status: accepted
Rationale: CUTOVER_PLAN treats role lists / prompt surfaces as derived
  surfaces, not parallel authorities. In this repo, ``.claude/`` is
  gitignored by design — a fresh checkout does not carry the projection
  and should not be required to.

  Earlier versions of this test asserted that ``<REPO_ROOT>/.claude/agents``
  exists on disk and byte-equals ``<REPO_ROOT>/agents``. That made the
  landable test bundle depend on ignored working-tree state — a clean
  clone without a prior ``scripts/claudex-sync-claude-agents.sh`` run
  would fail the test, and a stale local projection would silently
  succeed. Neither shape is right.

  This test file now exercises the sync script against **temp git
  repos** only: each test case seeds its own ``agents/`` source and
  ``.claude/agents`` target under a fresh ``git init`` tmp tree, copies
  the sync script into that tree, and drives it in either sync or
  ``--check`` mode. Nothing in this file reads or writes the real
  ``.claude/agents`` under the worktree's repo root.

  What this proves (deterministic, tmp-only):
    * sync populates an empty target from source
    * sync is idempotent (second run is a no-op)
    * sync replaces a stale target file byte-for-byte
    * sync removes an orphan target file not backed by source
    * ``--check`` passes on a matching projection
    * ``--check`` fails when a target is missing
    * ``--check`` fails when a target has drifted
    * ``--check`` fails when an orphan exists in the target
    * unknown CLI args fail cleanly
    * missing source dir fails cleanly with a named error

  What this explicitly does NOT do:
    * no reference to ``<REPO_ROOT>/.claude/agents`` — that path is
      ignored by ``.gitignore`` for a reason and is not authoritative.
    * no modification of ``.gitignore``.
    * no assumption that a fresh checkout has already run the sync.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
SYNC_SCRIPT_SOURCE = REPO_ROOT / "scripts" / "claudex-sync-claude-agents.sh"


# ---------------------------------------------------------------------------
# Temp-repo fixture
# ---------------------------------------------------------------------------


def _agent_names(path: Path) -> list[str]:
    return sorted(file.name for file in path.glob("*.md"))


def _init_temp_repo(tmp_path: Path) -> tuple[Path, Path, Path]:
    """Create a fresh git repo with agents/ and a sync-script copy.

    Returns ``(repo_root, source_dir, sync_script_path)``. The target
    directory (``<repo_root>/.claude/agents``) is NOT created — each
    test case is responsible for setting its own target-dir state so
    the scenario under test is explicit.
    """
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    source_dir = tmp_path / "agents"
    scripts_dir = tmp_path / "scripts"
    source_dir.mkdir()
    scripts_dir.mkdir()
    sync_script = scripts_dir / "claudex-sync-claude-agents.sh"
    sync_script.write_text(SYNC_SCRIPT_SOURCE.read_text(encoding="utf-8"), encoding="utf-8")
    sync_script.chmod(0o755)
    return tmp_path, source_dir, sync_script


def _seed_canonical_agents(source_dir: Path, *, entries: dict[str, str] | None = None) -> None:
    """Seed a minimal canonical agents/ under the temp repo."""
    if entries is None:
        entries = {
            "planner.md": "---\nname: planner\n---\nplanner body\n",
            "guardian.md": "---\nname: guardian\n---\nguardian body\n",
            "reviewer.md": "---\nname: reviewer\n---\nreviewer body\n",
        }
    for name, body in entries.items():
        (source_dir / name).write_text(body, encoding="utf-8")


def _run(sync_script: Path, repo_root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(sync_script), *args],
        cwd=str(repo_root),
        capture_output=True,
        text=True,
    )


# ---------------------------------------------------------------------------
# Sync mode
# ---------------------------------------------------------------------------


class TestSyncMode:

    def test_sync_populates_empty_target_from_source(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir)
        target_dir = repo_root / ".claude" / "agents"
        assert not target_dir.exists()

        result = _run(sync_script, repo_root)

        assert result.returncode == 0, result.stderr
        assert _agent_names(target_dir) == _agent_names(source_dir)
        for name in _agent_names(source_dir):
            assert (target_dir / name).read_text(encoding="utf-8") == (
                source_dir / name
            ).read_text(encoding="utf-8")

    def test_sync_is_idempotent(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir)
        target_dir = repo_root / ".claude" / "agents"

        first = _run(sync_script, repo_root)
        assert first.returncode == 0

        mtimes_before = {p.name: p.stat().st_mtime_ns for p in target_dir.glob("*.md")}
        second = _run(sync_script, repo_root)
        assert second.returncode == 0

        mtimes_after = {p.name: p.stat().st_mtime_ns for p in target_dir.glob("*.md")}
        # Second sync must not rewrite files that already match source byte-for-byte.
        assert mtimes_before == mtimes_after, (
            "sync must be a no-op when the projection already matches source"
        )

    def test_sync_replaces_stale_target_byte_for_byte(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir)
        target_dir = repo_root / ".claude" / "agents"
        target_dir.mkdir(parents=True)
        (target_dir / "planner.md").write_text("STALE\n", encoding="utf-8")

        result = _run(sync_script, repo_root)

        assert result.returncode == 0, result.stderr
        assert (target_dir / "planner.md").read_text(encoding="utf-8") == (
            source_dir / "planner.md"
        ).read_text(encoding="utf-8")

    def test_sync_removes_orphan_target_file(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir)
        target_dir = repo_root / ".claude" / "agents"
        target_dir.mkdir(parents=True)
        (target_dir / "orphan.md").write_text("---\nname: orphan\n---\n", encoding="utf-8")

        result = _run(sync_script, repo_root)

        assert result.returncode == 0, result.stderr
        assert not (target_dir / "orphan.md").exists()
        assert _agent_names(target_dir) == _agent_names(source_dir)

    def test_sync_creates_target_dir_if_missing(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir, entries={"planner.md": "only me\n"})
        target_dir = repo_root / ".claude" / "agents"
        # Neither .claude/ nor .claude/agents exists yet.
        assert not (repo_root / ".claude").exists()

        result = _run(sync_script, repo_root)

        assert result.returncode == 0, result.stderr
        assert target_dir.is_dir()
        assert (target_dir / "planner.md").read_text(encoding="utf-8") == "only me\n"


# ---------------------------------------------------------------------------
# Check mode
# ---------------------------------------------------------------------------


class TestCheckMode:

    def test_check_passes_on_matching_projection(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir)
        # Establish a matching projection first via a sync run.
        populate = _run(sync_script, repo_root)
        assert populate.returncode == 0

        result = _run(sync_script, repo_root, "--check")

        assert result.returncode == 0, result.stderr

    def test_check_fails_when_target_is_missing(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir)
        # NO prior sync — target does not exist.
        result = _run(sync_script, repo_root, "--check")
        assert result.returncode != 0
        assert "Missing projected Claude agent" in result.stderr

    def test_check_fails_when_projection_has_drifted(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir)
        target_dir = repo_root / ".claude" / "agents"
        target_dir.mkdir(parents=True)
        # Project only one file, drift the contents.
        (target_dir / "planner.md").write_text("DRIFTED\n", encoding="utf-8")

        result = _run(sync_script, repo_root, "--check")

        assert result.returncode != 0
        # Missing files and drifted files both show up.
        assert "Missing projected Claude agent" in result.stderr or \
               "drifted from canonical source" in result.stderr

    def test_check_fails_on_orphan_target_file(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir)
        # Populate a matching projection first.
        populate = _run(sync_script, repo_root)
        assert populate.returncode == 0
        # Introduce an orphan that is not backed by canonical source.
        target_dir = repo_root / ".claude" / "agents"
        (target_dir / "orphan.md").write_text("---\nname: orphan\n---\n", encoding="utf-8")

        result = _run(sync_script, repo_root, "--check")

        assert result.returncode != 0
        assert "Unexpected projected Claude agent" in result.stderr

    def test_check_does_not_mutate_target_on_failure(self, tmp_path: Path) -> None:
        """--check must be pure observation; it must not silently repair."""
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir)
        target_dir = repo_root / ".claude" / "agents"
        target_dir.mkdir(parents=True)
        (target_dir / "planner.md").write_text("DRIFTED\n", encoding="utf-8")
        (target_dir / "orphan.md").write_text("orphan\n", encoding="utf-8")

        before = {p.name: p.read_text(encoding="utf-8") for p in target_dir.glob("*.md")}

        result = _run(sync_script, repo_root, "--check")
        assert result.returncode != 0

        after = {p.name: p.read_text(encoding="utf-8") for p in target_dir.glob("*.md")}
        assert before == after, "--check must not rewrite files"


# ---------------------------------------------------------------------------
# CLI argument handling
# ---------------------------------------------------------------------------


class TestCliArgs:

    def test_unknown_argument_fails_cleanly(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir)
        result = _run(sync_script, repo_root, "--not-a-real-flag")
        assert result.returncode != 0
        assert "Unknown argument" in result.stderr

    def test_help_flag_exits_zero_and_prints_usage(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        _seed_canonical_agents(source_dir)
        result = _run(sync_script, repo_root, "--help")
        assert result.returncode == 0
        assert "Usage:" in result.stdout or "Sync" in result.stdout


# ---------------------------------------------------------------------------
# Missing-source error surface
# ---------------------------------------------------------------------------


class TestMissingSource:

    def test_missing_canonical_source_fails_with_named_error(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        # Do NOT seed agents/; remove it to make the failure explicit.
        source_dir.rmdir()
        result = _run(sync_script, repo_root)
        assert result.returncode != 0
        assert "Missing canonical agents directory" in result.stderr

    def test_empty_canonical_source_fails_cleanly(self, tmp_path: Path) -> None:
        repo_root, source_dir, sync_script = _init_temp_repo(tmp_path)
        # agents/ exists but is empty.
        result = _run(sync_script, repo_root)
        assert result.returncode != 0
        assert "No canonical agent files found" in result.stderr


# ---------------------------------------------------------------------------
# Canonical-authority invariant (pure read, no .claude/agents dependency)
# ---------------------------------------------------------------------------


class TestCanonicalAuthority:

    def test_real_repo_has_canonical_agents_directory(self) -> None:
        """The real repo's ``agents/`` directory is the sole authority and
        must exist with at least one role prompt. This is a pure read of
        tracked files — no ``.claude/agents`` involvement.
        """
        source_dir = REPO_ROOT / "agents"
        assert source_dir.is_dir(), "canonical agents/ directory is missing"
        names = _agent_names(source_dir)
        assert names, "canonical agents/ directory must carry at least one .md"

    def test_sync_script_points_at_agents_as_source(self) -> None:
        """The sync script's SOURCE_DIR must be ``${ROOT}/agents`` (the
        canonical authority) — not some other ``.claude/agents``-like
        alternative that would invert the single-authority direction.
        """
        text = SYNC_SCRIPT_SOURCE.read_text(encoding="utf-8")
        assert 'SOURCE_DIR="${ROOT}/agents"' in text
        assert 'TARGET_DIR="${ROOT}/.claude/agents"' in text
        # Guard: the source must not accidentally be inverted.
        assert 'SOURCE_DIR="${ROOT}/.claude/agents"' not in text

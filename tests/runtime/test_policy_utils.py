"""Unit tests for runtime.core.policy_utils.

Tests the Python ports of shell utility functions from hooks/context-lib.sh
and hooks/guard.sh. Each test asserts IDENTICAL behavior to the shell original.

@decision DEC-PE-001
Title: policy_utils.py ports shell logic verbatim so Python policies share exact
       classification semantics with hooks
Status: accepted
Rationale: Policies that run in Python must make the same path/token decisions
  the shell hooks make. Porting to Python and testing against the same cases
  as the shell originals ensures behavioral parity.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from runtime.core.policy_utils import (
    SOURCE_EXTENSIONS,
    extract_cd_target,
    extract_git_target_dir,
    is_claude_meta_repo,
    is_governance_markdown,
    is_skippable_path,
    is_source_file,
    resolve_path_from_base,
    sanitize_token,
)

# ---------------------------------------------------------------------------
# is_source_file
# ---------------------------------------------------------------------------


def test_is_source_file_py():
    assert is_source_file("foo.py") is True


def test_is_source_file_ts():
    assert is_source_file("bar.ts") is True


def test_is_source_file_tsx():
    assert is_source_file("App.tsx") is True


def test_is_source_file_md_false():
    assert is_source_file("README.md") is False


def test_is_source_file_no_ext_false():
    assert is_source_file("Makefile") is False


def test_is_source_file_sh():
    assert is_source_file("deploy.sh") is True


def test_is_source_file_json_false():
    assert is_source_file("config.json") is False


def test_is_source_file_all_extensions():
    """Every extension in SOURCE_EXTENSIONS must return True."""
    for ext in SOURCE_EXTENSIONS:
        assert is_source_file(f"file.{ext}") is True, f"expected True for .{ext}"


def test_is_source_file_mjs():
    """ENFORCE-RCA-6 (DEC-SOURCEEXT-001): .mjs is a source extension."""
    assert is_source_file("module.mjs") is True


def test_is_source_file_cjs():
    """ENFORCE-RCA-6 (DEC-SOURCEEXT-001): .cjs is a source extension."""
    assert is_source_file("legacy.cjs") is True


def test_is_source_file_mts():
    """ENFORCE-RCA-6 (DEC-SOURCEEXT-001): .mts is a source extension."""
    assert is_source_file("typed-module.mts") is True


def test_is_source_file_cts():
    """ENFORCE-RCA-6 (DEC-SOURCEEXT-001): .cts is a source extension."""
    assert is_source_file("typed-legacy.cts") is True


def test_source_extensions_contains_modern_js_variants():
    """Regression guard: ENFORCE-RCA-6 gap where policies skipped .mjs/.cjs/.mts/.cts.

    Before this fix the orchestrator could edit .mjs files on main with no
    policy intervention — branch_guard, write_who, doc_gate, plan_guard,
    test_gate_pretool, and mock_gate all gate on is_source_file() and all
    returned False for .mjs. Verified via direct cc-policy evaluate call.
    """
    assert "mjs" in SOURCE_EXTENSIONS
    assert "cjs" in SOURCE_EXTENSIONS
    assert "mts" in SOURCE_EXTENSIONS
    assert "cts" in SOURCE_EXTENSIONS


def test_source_extensions_python_shell_parity():
    """Python SOURCE_EXTENSIONS must match the shell mirror in hooks/context-lib.sh.

    DEC-PE-001 / DEC-SOURCEEXT-001: Python policy modules and shell hooks make
    the same source-file classification decision. Drift between the two lists
    creates an enforcement gap where one layer denies and the other allows
    (the exact root cause of ENFORCE-RCA-6). This test reads the shell file
    directly and asserts the extension lists are identical.
    """
    import re
    from pathlib import Path

    shell_file = Path(__file__).resolve().parent.parent.parent / "hooks" / "context-lib.sh"
    text = shell_file.read_text(encoding="utf-8")

    # Extract: SOURCE_EXTENSIONS='ts|tsx|js|jsx|...|zsh'
    match = re.search(r"^SOURCE_EXTENSIONS='([^']+)'", text, re.MULTILINE)
    assert match, "Could not find SOURCE_EXTENSIONS in hooks/context-lib.sh"

    shell_exts = set(match.group(1).split("|"))
    python_exts = set(SOURCE_EXTENSIONS)

    missing_in_shell = python_exts - shell_exts
    missing_in_python = shell_exts - python_exts

    assert not missing_in_shell and not missing_in_python, (
        f"SOURCE_EXTENSIONS drift detected.\n"
        f"  In Python but not in shell: {sorted(missing_in_shell)}\n"
        f"  In shell but not in Python: {sorted(missing_in_python)}\n"
        f"  Update both: runtime/core/policy_utils.py:77 AND hooks/context-lib.sh:164"
    )


# ---------------------------------------------------------------------------
# is_skippable_path
# ---------------------------------------------------------------------------


def test_is_skippable_node_modules():
    assert is_skippable_path("node_modules/react/index.js") is True


def test_is_skippable_test_file():
    assert is_skippable_path("src/foo.test.ts") is True


def test_is_skippable_spec_file():
    assert is_skippable_path("src/bar.spec.js") is True


def test_is_skippable_tests_dir():
    assert is_skippable_path("src/__tests__/helpers.py") is True


def test_is_skippable_vendor():
    assert is_skippable_path("vendor/lib/mod.go") is True


def test_is_skippable_dist():
    assert is_skippable_path("dist/bundle.js") is True


def test_is_skippable_build():
    assert is_skippable_path("build/output.js") is True


def test_is_skippable_pycache():
    assert is_skippable_path("__pycache__/foo.cpython-311.pyc") is True


def test_not_skippable_src_file():
    assert is_skippable_path("src/foo.py") is False


def test_not_skippable_plain_source():
    assert is_skippable_path("runtime/core/policy.py") is False


# ---------------------------------------------------------------------------
# is_governance_markdown
# ---------------------------------------------------------------------------


def test_governance_master_plan():
    assert is_governance_markdown("MASTER_PLAN.md") is True


def test_governance_master_plan_path():
    assert is_governance_markdown("/some/project/MASTER_PLAN.md") is True


def test_governance_claude_md():
    assert is_governance_markdown("CLAUDE.md") is True


def test_governance_agents_md():
    assert is_governance_markdown("agents/planner.md") is True


def test_governance_agents_md_absolute():
    assert is_governance_markdown("/project/agents/implementer.md") is True


def test_governance_docs_md():
    assert is_governance_markdown("docs/ARCH.md") is True


def test_governance_docs_md_absolute():
    assert is_governance_markdown("/project/docs/design.md") is True


def test_not_governance_src_md():
    assert is_governance_markdown("src/foo.md") is False


def test_not_governance_nested_agents():
    # Only immediate parent 'agents' counts
    assert is_governance_markdown("deep/agents/sub/file.md") is False


def test_not_governance_py_file():
    assert is_governance_markdown("agents/planner.py") is False


# ---------------------------------------------------------------------------
# is_claude_meta_repo (via env var)
# ---------------------------------------------------------------------------


def test_is_claude_meta_repo_via_env(monkeypatch, tmp_path):
    fake_claude = tmp_path / ".claude"
    fake_claude.mkdir()
    monkeypatch.setenv("CLAUDE_PROJECT_DIR", str(fake_claude))
    assert is_claude_meta_repo(str(fake_claude)) is True


def test_is_not_claude_meta_repo(monkeypatch, tmp_path):
    monkeypatch.delenv("CLAUDE_PROJECT_DIR", raising=False)
    # A plain temp dir with no .claude suffix should return False
    assert is_claude_meta_repo(str(tmp_path)) is False


def test_is_claude_meta_repo_env_not_dot_claude(monkeypatch, tmp_path):
    monkeypatch.setenv("CLAUDE_PROJECT_DIR", str(tmp_path))
    assert is_claude_meta_repo(str(tmp_path)) is False


def test_is_claude_meta_repo_via_git_toplevel(monkeypatch, tmp_path):
    """Check 2: git --show-toplevel ending in /.claude returns True (main checkout)."""
    import subprocess

    monkeypatch.delenv("CLAUDE_PROJECT_DIR", raising=False)
    meta_repo = tmp_path / ".claude"
    meta_repo.mkdir()
    subprocess.run(["git", "init", "-q", str(meta_repo)], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(meta_repo),
            "-c",
            "user.email=t@t.com",
            "-c",
            "user.name=T",
            "commit",
            "--allow-empty",
            "-m",
            "init",
            "-q",
        ],
        check=True,
    )
    assert is_claude_meta_repo(str(meta_repo)) is True


def test_is_claude_meta_repo_worktree(monkeypatch, tmp_path):
    """Check 3: worktree of ~/.claude returns True via --git-common-dir (#163/#143).

    Before the fix, --show-toplevel returns the worktree path which does NOT
    end in /.claude, causing is_claude_meta_repo() to return False.
    The fix adds --git-common-dir which DOES end in /.claude/.git for any
    worktree of the meta-repo.
    """
    import subprocess

    monkeypatch.delenv("CLAUDE_PROJECT_DIR", raising=False)

    # Set up simulated ~/.claude repo
    meta_repo = tmp_path / ".claude"
    meta_repo.mkdir()
    subprocess.run(["git", "init", "-q", str(meta_repo)], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(meta_repo),
            "-c",
            "user.email=t@t.com",
            "-c",
            "user.name=T",
            "commit",
            "--allow-empty",
            "-m",
            "init",
            "-q",
        ],
        check=True,
    )

    # Create a worktree — its toplevel is NOT /.claude
    worktree_dir = meta_repo / ".worktrees" / "feature-test"
    (meta_repo / ".worktrees").mkdir()
    subprocess.run(
        [
            "git",
            "-C",
            str(meta_repo),
            "worktree",
            "add",
            str(worktree_dir),
            "-b",
            "feature/test",
            "-q",
        ],
        check=True,
    )

    # Verify the test precondition: toplevel does NOT end in /.claude
    result = subprocess.run(
        ["git", "-C", str(worktree_dir), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    worktree_toplevel = result.stdout.strip()
    assert not worktree_toplevel.endswith("/.claude"), (
        f"Precondition failed: worktree toplevel '{worktree_toplevel}' "
        "ends in /.claude — test is not exercising the bug path"
    )

    # The fix: is_claude_meta_repo must return True for the worktree
    assert is_claude_meta_repo(str(worktree_dir)) is True, (
        "is_claude_meta_repo() returned False for a worktree of ~/.claude — "
        "Check 3 (--git-common-dir) is not working"
    )


def test_is_not_claude_meta_repo_plain_repo(monkeypatch, tmp_path):
    """A plain repo whose name does not end in .claude must return False."""
    import subprocess

    monkeypatch.delenv("CLAUDE_PROJECT_DIR", raising=False)
    plain_repo = tmp_path / "myproject"
    plain_repo.mkdir()
    subprocess.run(["git", "init", "-q", str(plain_repo)], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(plain_repo),
            "-c",
            "user.email=t@t.com",
            "-c",
            "user.name=T",
            "commit",
            "--allow-empty",
            "-m",
            "init",
            "-q",
        ],
        check=True,
    )
    assert is_claude_meta_repo(str(plain_repo)) is False


# ---------------------------------------------------------------------------
# sanitize_token
# ---------------------------------------------------------------------------


def test_sanitize_token_branch():
    assert sanitize_token("feat/foo-bar") == "feat-foo-bar"


def test_sanitize_token_spaces():
    # spaces → dashes, then stripped of non-alphanum
    result = sanitize_token("hello world")
    assert " " not in result


def test_sanitize_token_colon():
    result = sanitize_token("fix:some-bug")
    assert ":" not in result


def test_sanitize_token_empty():
    assert sanitize_token("") == "default"


def test_sanitize_token_special_chars():
    result = sanitize_token("v1.2.3")
    # dots are allowed by [[:alnum:]._-]
    assert "." in result or result == "v123"


def test_sanitize_token_slash():
    result = sanitize_token("feature/my-feature")
    assert "/" not in result
    assert "-" in result


# ---------------------------------------------------------------------------
# extract_cd_target
# ---------------------------------------------------------------------------


def test_extract_cd_target_double_quoted():
    cmd = 'cd "/path/to/dir" && git status'
    assert extract_cd_target(cmd) == "/path/to/dir"


def test_extract_cd_target_single_quoted():
    cmd = "cd '/path/to/dir' && git status"
    assert extract_cd_target(cmd) == "/path/to/dir"


def test_extract_cd_target_unquoted():
    cmd = "cd /path/to/dir && git status"
    result = extract_cd_target(cmd)
    assert result == "/path/to/dir"


def test_extract_cd_target_no_cd():
    cmd = "git status"
    assert extract_cd_target(cmd) is None


# ---------------------------------------------------------------------------
# extract_git_target_dir
# ---------------------------------------------------------------------------


def test_extract_git_target_dir_dash_c(tmp_path):
    cmd = f"git -C {tmp_path} commit -m 'msg'"
    result = extract_git_target_dir(cmd, cwd=str(tmp_path))
    assert result == str(tmp_path)


def test_extract_git_target_dir_cd_pattern(tmp_path):
    cmd = f'cd "{tmp_path}" && git status'
    result = extract_git_target_dir(cmd, cwd=str(tmp_path))
    assert result == str(tmp_path)


def test_extract_git_target_dir_relative_dash_c(tmp_path):
    target = tmp_path / ".worktrees" / "feature-a"
    target.mkdir(parents=True)
    cmd = "git -C .worktrees/feature-a status"
    result = extract_git_target_dir(cmd, cwd=str(tmp_path))
    assert result == str(target)


def test_extract_git_target_dir_fallback_cwd(tmp_path):
    cmd = "git status"
    result = extract_git_target_dir(cmd, cwd=str(tmp_path))
    # Falls back to cwd when no cd or -C pattern found
    assert result == str(tmp_path)


def test_resolve_path_from_base_expands_home():
    result = resolve_path_from_base("/tmp/project", "~")
    assert result == os.path.expanduser("~")

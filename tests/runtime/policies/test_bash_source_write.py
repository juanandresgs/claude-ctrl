"""Tests for Bash source-write guard."""

from __future__ import annotations

import subprocess

from runtime.core.command_intent import build_bash_command_intent
from runtime.core.policies.bash_source_write import check
from tests.runtime.policies.conftest import make_context, make_request


def test_command_intent_extracts_heredoc_output_target() -> None:
    intent = build_bash_command_intent(
        "cat > /project/src/app.py <<'PY'\nprint('x')\nPY",
        cwd="/project",
    )
    assert intent is not None
    assert "/project/src/app.py" in intent.shell_write_targets


def test_orchestrator_cat_redirect_to_source_denied() -> None:
    ctx = make_context(actor_role="", actor_id="", project_root="/project", branch="feature/test")
    req = make_request(
        "cat > /project/src/app.py <<'PY'\nprint('x')\nPY",
        context=ctx,
        cwd="/project",
    )
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert decision.policy_name == "bash_source_write"
    assert "small-source mode" in decision.reason


def test_orchestrator_tee_to_source_denied() -> None:
    ctx = make_context(actor_role="", actor_id="", project_root="/project", branch="feature/test")
    req = make_request("printf x | tee /project/src/app.py >/dev/null", context=ctx, cwd="/project")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"


def test_implementer_source_redirect_allowed_on_feature_branch() -> None:
    ctx = make_context(actor_role="implementer", project_root="/project", branch="feature/test")
    req = make_request("cat > /project/src/app.py <<'PY'\nprint('x')\nPY", context=ctx, cwd="/project")
    assert check(req) is None


def test_guardian_small_source_redirect_allowed_on_main(tmp_path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "-C", str(repo), "init"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo), "checkout", "-B", "main"], check=True, capture_output=True)
    (repo / "src").mkdir()
    target = repo / "src" / "app.py"
    ctx = make_context(actor_role="guardian", project_root=str(repo), branch="main")
    req = make_request(
        f"cat > {target} <<'PY'\nprint('x')\nPY",
        context=ctx,
        cwd=str(repo),
    )
    assert check(req) is None


def test_implementer_source_redirect_denied_on_main() -> None:
    ctx = make_context(actor_role="implementer", project_root="/project", branch="main")
    req = make_request("cat > /project/src/app.py <<'PY'\nprint('x')\nPY", context=ctx, cwd="/project")
    decision = check(req)
    assert decision is not None
    assert decision.action == "deny"
    assert "main branch" in decision.reason


def test_non_source_redirect_allowed() -> None:
    ctx = make_context(actor_role="", actor_id="", project_root="/project", branch="feature/test")
    req = make_request("cat > /project/notes.txt <<'TXT'\nhello\nTXT", context=ctx, cwd="/project")
    assert check(req) is None

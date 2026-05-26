"""v6 prompt router, strict contracts, settings render, and dispatch pump tests."""

import json
import sqlite3

import pytest

from runtime.core import dispatch_pump, prompt_router, settings_renderer, stage_runs
from runtime.schemas import ensure_schema


FULL_SHA = "a" * 40


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def test_prompt_router_bootstraps_every_non_meta_prompt(conn, tmp_path):
    route = prompt_router.route_prompt(
        conn,
        workflow_id="wf-router",
        worktree_path=str(tmp_path),
        prompt="Create a frontier lab founder calculator",
    )
    assert route["action"] == "bootstrap"
    assert "V6_DISPATCH_READY" in route["dispatch_context"]
    assert route["bootstrap"]["stage_id"] == "planner"
    assert route["bootstrap"]["goal_id"].startswith("goal-")
    assert route["bootstrap"]["work_item_id"].startswith("wi-")


def test_prompt_router_native_plan_handoff_starts_guardian(conn, tmp_path):
    route = prompt_router.route_prompt(
        conn,
        workflow_id="wf-native-plan",
        worktree_path=str(tmp_path),
        prompt="Follow the dispatch. Guardian creates your worktree, then implementer does the work.",
    )
    assert route["action"] == "bootstrap"
    assert route["reason"] == "native_plan_handoff"
    assert "V6_DISPATCH_READY: launch guardian" in route["dispatch_context"]
    assert "Native Plan mode handoff" in route["dispatch_context"]
    assert route["bootstrap"]["stage_id"] == "guardian:provision"
    assert route["bootstrap"]["subagent_type"] == "guardian"


def test_prompt_router_implement_the_plan_uses_native_plan_handoff(conn, tmp_path):
    route = prompt_router.route_prompt(
        conn,
        workflow_id="wf-implement-plan",
        worktree_path=str(tmp_path),
        prompt="Implement the plan.",
    )
    assert route["action"] == "bootstrap"
    assert route["reason"] == "native_plan_handoff"
    assert route["bootstrap"]["stage_id"] == "guardian:provision"


def test_prompt_router_embedded_ticket_selects_ticket_workflow(conn, tmp_path):
    boot = stage_runs.bootstrap_planner(
        conn,
        workflow_id="fix-extraction-scoring",
        worktree_path=str(tmp_path),
        prompt="existing work",
    )
    route = prompt_router.route_prompt(
        conn,
        workflow_id="main",
        worktree_path=str(tmp_path),
        prompt=f"Continue dispatch from runtime state. Expected ticket {boot['prompt_prefix']}.",
    )

    assert route["action"] == "bootstrap"
    assert route["workflow_id"] == "fix-extraction-scoring"
    assert "V6_DISPATCH_READY: launch planner for stage planner" in route["dispatch_context"]
    assert boot["prompt_prefix"] not in route["dispatch_context"]


def test_prompt_router_resume_prefers_active_nonplanner_over_branch_planner(conn, tmp_path):
    stage_runs.bootstrap_planner(conn, workflow_id="main", worktree_path=str(tmp_path), prompt="stale")
    fix = stage_runs.bootstrap_planner(conn, workflow_id="fix-extraction-scoring", worktree_path=str(tmp_path), prompt="fix")
    stage_runs.submit_result(
        conn,
        stage_run_id=fix["stage_run"]["id"],
        payload={
            "stage_run_id": fix["stage_run"]["id"],
            "stage_id": "planner",
            "verdict": "next_work_item",
            "summary": "planned",
        },
    )

    route = prompt_router.route_prompt(
        conn,
        workflow_id="main",
        worktree_path=str(tmp_path),
        prompt="Continue the dispatch from the runtime state.",
    )

    assert route["workflow_id"] == "fix-extraction-scoring"
    assert route["bootstrap"]["stage_id"] == "guardian:provision"
    assert "launch guardian" in route["dispatch_context"]


def test_prompt_router_explicit_chat_passthrough(conn, tmp_path):
    route = prompt_router.route_prompt(
        conn,
        workflow_id="wf-router",
        worktree_path=str(tmp_path),
        prompt="/chat explain dilution",
    )
    assert route["action"] == "pass_through"
    assert route["reason"] == "explicit_passthrough:/chat"


def test_result_contract_rejects_stage_run_id_mismatch(conn):
    run = stage_runs.create_stage_run(conn, workflow_id="wf", stage_id="planner")
    out = stage_runs.submit_result(
        conn,
        stage_run_id=run["id"],
        payload={"stage_run_id": "wrong", "stage_id": "planner", "verdict": "next_work_item", "summary": "x"},
    )
    assert out["validation"]["valid"] is False
    assert "stage_run_id_mismatch" in out["validation"]["missing_fields"]


def test_result_contract_requires_full_head_sha(conn):
    run = stage_runs.create_stage_run(conn, workflow_id="wf", stage_id="reviewer")
    out = stage_runs.submit_result(
        conn,
        stage_run_id=run["id"],
        payload={
            "stage_run_id": run["id"],
            "stage_id": "reviewer",
            "verdict": "ready_for_guardian",
            "summary": "x",
            "head_sha": "abc123",
            "findings": [],
        },
    )
    assert out["validation"]["valid"] is False
    assert "head_sha_full_40" in out["validation"]["missing_fields"]


def test_strict_final_result_block(conn):
    run = stage_runs.create_stage_run(conn, workflow_id="wf", stage_id="planner")
    response = (
        '```claude_ctrl_result\n'
        + json.dumps({"stage_run_id": run["id"], "stage_id": "planner", "verdict": "next_work_item", "summary": "x"})
        + "\n```\ntrailing"
    )
    with pytest.raises(ValueError, match="final"):
        stage_runs.extract_and_submit_response(conn, response_text=response)


def test_critic_contract_includes_findings(conn):
    run = stage_runs.create_stage_run(conn, workflow_id="wf", stage_id="critic")
    contract = stage_runs.result_contract_for_stage("critic", run["id"])
    assert "findings" in contract
    assert "execution_proof" in contract


def test_dispatch_pump_returns_launch_envelope(conn):
    boot = stage_runs.bootstrap_planner(conn, workflow_id="wf-pump", worktree_path="/tmp/repo", prompt="x")
    launch = dispatch_pump.launch_for_ticket(conn, boot["ticket"]["id"])
    assert launch["authority"] == "v6_stage_machine"
    assert launch["launch"]["subagent_type"] == "planner"
    assert launch["launch"]["prompt_first_line"].startswith(stage_runs.TICKET_PREFIX)


def test_settings_renderer_rewrites_home_claude(tmp_path):
    src = tmp_path / "settings.json"
    out = tmp_path / "out.json"
    src.write_text(json.dumps({"hooks": {"X": [{"hooks": [{"command": "$HOME/.claude/hooks/a.sh"}]}]}}))
    rendered = settings_renderer.render_settings(src, "/repo/fullRefactor", out)
    assert rendered["hooks"]["X"][0]["hooks"][0]["command"] == "/repo/fullRefactor/hooks/a.sh"
    assert json.loads(out.read_text()) == rendered


def test_settings_renderer_syncs_bundled_codex_plugin_cache(tmp_path):
    root = tmp_path / "root"
    src = root / "settings.json"
    plugin = root / "plugins" / "marketplaces" / "openai-codex" / "plugins" / "codex"
    plugin_hooks = plugin / "hooks"
    plugin_hooks.mkdir(parents=True)
    (root / "plugins" / "marketplaces" / "openai-codex").mkdir(parents=True, exist_ok=True)
    (root / "plugins" / "marketplaces" / "openai-codex" / "package.json").write_text('{"version":"1.0.4"}')
    (plugin_hooks / "hooks.json").write_text('{"hooks":{"SessionStart":[]}}')
    src.write_text(json.dumps({"hooks": {}}))

    settings_renderer.render_settings(src, root, root / "tmp" / "settings.json")

    cached = root / "plugins" / "cache" / "openai-codex" / "codex" / "1.0.4" / "hooks" / "hooks.json"
    assert cached.exists()
    assert json.loads(cached.read_text()) == {"hooks": {"SessionStart": []}}

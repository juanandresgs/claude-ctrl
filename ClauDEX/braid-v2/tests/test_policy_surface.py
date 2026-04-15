"""Tests for braid2.policy_surface — policy integration contract.

Design contract for these tests
--------------------------------
* Live-wiring tests (marked ``_real_module``) use the actual runtime/core
  implementations, not mocks. They verify interface compatibility — that the
  policy surface calls the real function with the right signature and gets a
  real result back. These tests will be skipped if runtime.core is not importable.
* Stub tests verify that when live wiring is unavailable (or when the required
  inputs are absent), the function returns an honest ``not_wired`` verdict with
  a provenance block that contains enough information for a future implementer
  to complete the wiring.
* Mock tests are used only for isolation (testing error-path fallback when a
  live module raises), not to pretend that a mock-accepting call shape is also
  accepted by the real module.
"""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path
from typing import Optional
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Path setup: make both braid2 and runtime.core importable
# ---------------------------------------------------------------------------

# braid2 package root (ClauDEX/braid-v2)
_BRAID2_ROOT = Path(__file__).resolve().parent.parent
if str(_BRAID2_ROOT) not in sys.path:
    sys.path.insert(0, str(_BRAID2_ROOT))

# Project root (two levels up from ClauDEX/braid-v2) — needed for runtime.core
_PROJECT_ROOT = _BRAID2_ROOT.parent.parent
if str(_PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(_PROJECT_ROOT))

from braid2.policy_surface import (
    PolicyVerdict,
    PromptPackResult,
    LaunchProfileResult,
    _adaptation_capability,
    compile_prompt_pack,
    evaluate_self_adaptation,
    evaluate_spawn_request,
    resolve_launch_profile,
)

# ---------------------------------------------------------------------------
# Check runtime.core availability for live-module tests
# ---------------------------------------------------------------------------

def _runtime_core_available() -> bool:
    try:
        import importlib
        importlib.import_module("runtime.core.authority_registry")
        return True
    except Exception:
        return False


_RUNTIME_AVAILABLE = _runtime_core_available()

# ---------------------------------------------------------------------------
# Required provenance field sets
# ---------------------------------------------------------------------------

_RUNTIME_MODULES = {
    "runtime/core/policy_engine.py",
    "runtime/core/authority_registry.py",
    "runtime/core/prompt_pack.py",
    "runtime/core/prompt_pack_resolver.py",
}
_REQUIRED_NOT_WIRED_KEYS = {"module", "function", "status", "wiring_requirements"}


def _assert_not_wired_provenance(provenance: dict, expected_module: str) -> None:
    assert provenance.get("module") == expected_module, (
        f"provenance.module should be {expected_module!r}, got {provenance.get('module')!r}"
    )
    assert provenance.get("status") == "not_wired"
    missing = _REQUIRED_NOT_WIRED_KEYS - set(provenance.keys())
    assert not missing, f"provenance missing keys: {missing}"
    assert provenance["module"] in _RUNTIME_MODULES
    assert provenance["wiring_requirements"], "wiring_requirements must be non-empty"


# ===========================================================================
# evaluate_spawn_request — always not_wired (build_context requires runtime DB)
# ===========================================================================

class TestEvaluateSpawnRequest:
    def test_returns_policy_verdict(self):
        result = evaluate_spawn_request(
            worker_harness="claude-code",
            supervisor_harness="claudex-supervisor",
        )
        assert isinstance(result, PolicyVerdict)

    def test_always_not_wired(self):
        """evaluate_spawn_request is always not_wired: requires runtime DB connection."""
        result = evaluate_spawn_request(
            worker_harness="claude-code",
            supervisor_harness="claudex-supervisor",
        )
        assert result.status == "not_wired"
        assert result.wired is False

    def test_not_wired_even_when_runtime_core_available(self):
        """Even if runtime.core is importable, spawn evaluation cannot proceed
        without a pre-built PolicyContext from the runtime DB."""
        result = evaluate_spawn_request(
            worker_harness="w",
            supervisor_harness="s",
            actor_role="implementer",
            worktree_path="/tmp",
            project_root="/tmp",
        )
        # Must still be not_wired — runtime DB connection is absent
        assert result.status == "not_wired"
        assert result.wired is False

    def test_provenance_points_at_policy_engine(self):
        result = evaluate_spawn_request(
            worker_harness="claude-code",
            supervisor_harness="claudex-supervisor",
        )
        _assert_not_wired_provenance(result.provenance, "runtime/core/policy_engine.py")

    def test_provenance_documents_wiring_requirements(self):
        result = evaluate_spawn_request(
            worker_harness="w",
            supervisor_harness="s",
        )
        reqs = result.provenance["wiring_requirements"]
        assert "build_context" in reqs, "wiring_requirements must mention build_context"
        assert "cc-policy" in reqs or "CLI" in reqs, (
            "wiring_requirements must document the CLI wiring path"
        )

    def test_metadata_echoed(self):
        result = evaluate_spawn_request(
            worker_harness="wh",
            supervisor_harness="sh",
            goal_ref="goal-001",
            work_item_ref="wi-001",
            requested_by_seat="seat-abc",
            parent_bundle_id="bundle-xyz",
            transport="tmux",
        )
        assert result.metadata["worker_harness"] == "wh"
        assert result.metadata["goal_ref"] == "goal-001"
        assert result.metadata["transport"] == "tmux"

    def test_to_dict_is_serialisable(self):
        result = evaluate_spawn_request(worker_harness="w", supervisor_harness="s")
        json.dumps(result.to_dict())

    def test_approved_false_on_not_wired(self):
        result = evaluate_spawn_request(worker_harness="w", supervisor_harness="s")
        assert result.approved() is False

    def test_evaluated_at_is_recent_timestamp(self):
        import time
        before = int(time.time())
        result = evaluate_spawn_request(worker_harness="w", supervisor_harness="s")
        after = int(time.time())
        assert before <= result.evaluated_at <= after

    def test_extra_fields_in_metadata(self):
        result = evaluate_spawn_request(
            worker_harness="w",
            supervisor_harness="s",
            extra={"custom_key": "custom_value"},
        )
        assert result.metadata.get("custom_key") == "custom_value"


# ===========================================================================
# evaluate_self_adaptation — live when authority_registry importable (pure fn)
# ===========================================================================

class TestEvaluateSelfAdaptation:
    def test_returns_policy_verdict(self):
        result = evaluate_self_adaptation(
            bundle_id="b1",
            seat_id="s1",
            seat_role="implementer",
            adaptation_type="autonomy_budget_increase",
            proposed_change={"new_budget": "high"},
        )
        assert isinstance(result, PolicyVerdict)

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    def test_live_implementer_can_write_source(self):
        """Implementer role has can_write_source per authority_registry — live check."""
        result = evaluate_self_adaptation(
            bundle_id="b1",
            seat_id="s1",
            seat_role="implementer",
            adaptation_type="source_edit",
            proposed_change={},
            required_capability="can_write_source",
        )
        assert result.wired is True, f"Expected live wiring; got: {result.reason}"
        assert result.status == "approved"
        assert result.provenance.get("status") == "live"
        assert result.provenance["module"] == "runtime/core/authority_registry.py"

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    def test_live_reviewer_cannot_write_source(self):
        """Reviewer role lacks can_write_source per authority_registry — live check."""
        result = evaluate_self_adaptation(
            bundle_id="b1",
            seat_id="s1",
            seat_role="reviewer",
            adaptation_type="source_edit",
            proposed_change={},
            required_capability="can_write_source",
        )
        assert result.wired is True
        assert result.status == "denied"

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    def test_live_planner_can_set_config(self):
        """Planner role has can_set_control_config — live check."""
        result = evaluate_self_adaptation(
            bundle_id="b",
            seat_id="s",
            seat_role="planner",
            adaptation_type="config_override",
            proposed_change={},
        )
        assert result.wired is True
        assert result.status == "approved"

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    def test_live_unknown_stage_returns_denied(self):
        """A stage not in the authority registry has no capabilities; denied."""
        result = evaluate_self_adaptation(
            bundle_id="b",
            seat_id="s",
            seat_role="unknown_stage_xyz",
            adaptation_type="source_edit",
            proposed_change={},
            required_capability="can_write_source",
        )
        # stage_has_capability returns False for unknown stages
        assert result.wired is True
        assert result.status == "denied"

    def test_stub_when_authority_registry_unavailable(self):
        """When authority_registry import fails, returns not_wired stub."""
        with patch.dict("sys.modules", {"runtime.core.authority_registry": None}):
            result = evaluate_self_adaptation(
                bundle_id="b",
                seat_id="s",
                seat_role="implementer",
                adaptation_type="source_edit",
                proposed_change={},
                required_capability="can_write_source",
            )
        assert result.status == "not_wired"
        assert result.wired is False
        _assert_not_wired_provenance(result.provenance, "runtime/core/authority_registry.py")

    def test_to_dict_serialisable(self):
        result = evaluate_self_adaptation(
            bundle_id="b", seat_id="s", seat_role="implementer",
            adaptation_type="source_edit", proposed_change={},
        )
        json.dumps(result.to_dict())


# ===========================================================================
# _adaptation_capability mapping — interface to authority_registry vocabulary
# ===========================================================================

class TestAdaptationCapabilityTable:
    @pytest.mark.parametrize("adaptation_type,expected_cap", [
        ("autonomy_budget_increase", "can_set_control_config"),
        ("harness_substitution", "can_set_control_config"),
        ("config_override", "can_set_control_config"),
        ("source_edit", "can_write_source"),
        ("governance_edit", "can_write_governance"),
        ("worktree_provision", "can_provision_worktree"),
        ("git_land", "can_land_git"),
    ])
    def test_known_types(self, adaptation_type, expected_cap):
        assert _adaptation_capability(adaptation_type) == expected_cap

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    @pytest.mark.parametrize("adaptation_type", [
        "source_edit", "governance_edit", "worktree_provision", "git_land",
        "autonomy_budget_increase", "harness_substitution", "config_override",
    ])
    def test_mapped_capability_is_in_authority_registry_vocabulary(self, adaptation_type):
        """Every capability in the mapping table must be declared in CAPABILITIES."""
        from runtime.core.authority_registry import CAPABILITIES
        cap = _adaptation_capability(adaptation_type)
        assert cap in CAPABILITIES, (
            f"adaptation '{adaptation_type}' maps to '{cap}' which is not in "
            f"authority_registry.CAPABILITIES: {sorted(CAPABILITIES)}"
        )

    def test_unknown_type_returns_empty(self):
        assert _adaptation_capability("totally_unknown") == ""


# ===========================================================================
# compile_prompt_pack — live via build_prompt_pack (pure) when layers supplied
# ===========================================================================

_CANONICAL_LAYERS = (
    "constitution",
    "stage_contract",
    "workflow_contract",
    "local_decision_pack",
    "runtime_state_pack",
    "next_actions",
)


def _make_explicit_layers() -> dict:
    return {name: f"Layer content for {name}." for name in _CANONICAL_LAYERS}


class TestCompilePromptPack:
    def test_returns_prompt_pack_result(self):
        result = compile_prompt_pack(workflow_id="wf", stage_id="implementer")
        assert isinstance(result, PromptPackResult)

    def test_not_wired_when_no_explicit_layers(self):
        result = compile_prompt_pack(workflow_id="wf", stage_id="planner")
        assert result.status == "not_wired"
        assert result.wired is False
        assert result.pack is None

    def test_provenance_when_not_wired(self):
        result = compile_prompt_pack(workflow_id="wf", stage_id="planner")
        _assert_not_wired_provenance(result.provenance, "runtime/core/prompt_pack.py")

    def test_wiring_requirements_mentions_both_entry_points(self):
        result = compile_prompt_pack(workflow_id="wf", stage_id="planner")
        reqs = result.provenance["wiring_requirements"]
        assert "build_prompt_pack" in reqs
        assert "compile_prompt_pack_for_stage" in reqs

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    def test_live_with_real_build_prompt_pack(self):
        """With explicit_layers, calls the real build_prompt_pack — pure function."""
        result = compile_prompt_pack(
            workflow_id="wf-001",
            stage_id="implementer",
            explicit_layers=_make_explicit_layers(),
        )
        assert result.status == "compiled"
        assert result.wired is True
        assert result.pack is not None
        assert result.pack["workflow_id"] == "wf-001"
        assert result.pack["stage_id"] == "implementer"
        assert "content_hash" in result.pack
        assert result.pack["content_hash"].startswith("sha256:")
        assert result.provenance.get("status") == "live"

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    def test_live_different_stage_ids(self):
        """build_prompt_pack accepts any non-empty stage_id string."""
        for stage_id in ("planner", "tester", "guardian:land"):
            result = compile_prompt_pack(
                workflow_id="wf",
                stage_id=stage_id,
                explicit_layers=_make_explicit_layers(),
            )
            assert result.status == "compiled", f"failed for stage_id={stage_id!r}"
            assert result.pack["stage_id"] == stage_id

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    def test_live_missing_layer_returns_not_wired_with_error(self):
        """Passing incomplete layers causes build_prompt_pack to raise; surface
        returns not_wired with the error embedded in wiring_requirements."""
        incomplete = _make_explicit_layers()
        del incomplete["constitution"]  # Remove one required layer
        result = compile_prompt_pack(
            workflow_id="wf",
            stage_id="implementer",
            explicit_layers=incomplete,
        )
        assert result.status == "not_wired"
        assert result.wired is False
        assert "constitution" in result.provenance["wiring_requirements"]

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    def test_live_content_hash_is_deterministic(self):
        """Same inputs produce the same hash (build_prompt_pack is pure)."""
        layers = _make_explicit_layers()
        r1 = compile_prompt_pack(workflow_id="wf", stage_id="planner", explicit_layers=layers)
        r2 = compile_prompt_pack(workflow_id="wf", stage_id="planner", explicit_layers=layers)
        assert r1.pack["content_hash"] == r2.pack["content_hash"]

    def test_to_dict_serialisable(self):
        result = compile_prompt_pack(workflow_id="wf", stage_id="tester")
        json.dumps(result.to_dict())


# ===========================================================================
# resolve_launch_profile — live via resolve_prompt_pack_layers (pure)
# ===========================================================================

class TestResolveLaunchProfile:
    def test_returns_launch_profile_result(self):
        result = resolve_launch_profile(harness="h", stage="implementer", workflow_id="wf")
        assert isinstance(result, LaunchProfileResult)

    def test_not_wired_when_stage_empty(self):
        """Empty stage is always not_wired (resolver would reject it anyway)."""
        result = resolve_launch_profile(harness="h", stage="", workflow_id="wf")
        assert result.status == "not_wired"
        assert result.wired is False
        _assert_not_wired_provenance(result.provenance, "runtime/core/prompt_pack_resolver.py")

    def test_not_wired_when_workflow_id_empty(self):
        """Empty workflow_id is always not_wired (WorkflowContractSummary rejects it)."""
        result = resolve_launch_profile(harness="h", stage="implementer", workflow_id="")
        assert result.status == "not_wired"
        assert result.wired is False

    def test_wiring_requirements_mention_both_missing_fields(self):
        result = resolve_launch_profile(harness="h", stage="", workflow_id="")
        reqs = result.provenance["wiring_requirements"]
        assert "stage" in reqs
        assert "workflow_id" in reqs

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    def test_live_with_real_resolver_and_real_dataclasses(self):
        """resolve_prompt_pack_layers is pure; uses real WorkflowContractSummary etc."""
        result = resolve_launch_profile(
            harness="claude-code",
            stage="implementer",
            workflow_id="wf-live-test",
            goal_ref="goal-001",
            current_branch="feature/test",
            worktree_path="/tmp/worktree",
        )
        assert result.status == "resolved", f"Expected resolved; got: {result}"
        assert result.wired is True
        assert result.profile is not None
        assert result.profile["harness"] == "claude-code"
        assert result.profile["stage"] == "implementer"
        layers = result.profile["layers"]
        # Resolver must return exactly the six canonical layers
        from runtime.core.prompt_pack import CANONICAL_LAYER_ORDER
        assert set(layers.keys()) == set(CANONICAL_LAYER_ORDER), (
            f"Expected canonical layers {sorted(CANONICAL_LAYER_ORDER)}, "
            f"got {sorted(layers.keys())}"
        )
        for layer_name, content in layers.items():
            assert isinstance(content, str) and content.strip(), (
                f"Layer '{layer_name}' must be a non-empty string"
            )

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    @pytest.mark.parametrize("stage", ["planner", "implementer", "reviewer",
                                        "guardian:provision", "guardian:land"])
    def test_live_all_active_stages(self, stage):
        """All active stages in stage_registry.ACTIVE_STAGES should resolve."""
        result = resolve_launch_profile(
            harness="h",
            stage=stage,
            workflow_id="wf-001",
            current_branch="main",
            worktree_path="/tmp/wt",
        )
        assert result.status == "resolved", (
            f"Stage '{stage}' failed: {result.provenance}"
        )
        assert result.wired is True

    @pytest.mark.skipif(not _RUNTIME_AVAILABLE, reason="runtime.core not importable")
    def test_live_invalid_stage_returns_not_wired(self):
        """Stage not in ACTIVE_STAGES causes resolver to raise; surface returns not_wired."""
        result = resolve_launch_profile(
            harness="h",
            stage="nonexistent_stage_xyz",
            workflow_id="wf-001",
            current_branch="main",
            worktree_path="/tmp/wt",
        )
        assert result.status == "not_wired"
        assert result.wired is False
        assert "nonexistent_stage_xyz" in result.provenance["wiring_requirements"]

    def test_to_dict_serialisable(self):
        result = resolve_launch_profile(harness="h", stage="", workflow_id="")
        json.dumps(result.to_dict())


# ===========================================================================
# Kernel integration: policy_verdict embedded in spawn request request_json
# ===========================================================================

class TestKernelSpawnPolicyVerdictEmbedding:
    def _make_db(self) -> sqlite3.Connection:
        from braid2 import db as braid_db
        return braid_db.open_db(":memory:")

    def _make_bundle_and_seat(self, conn):
        from braid2 import kernel as k
        bundle = k.create_bundle(conn, bundle_type="test")
        session = k.create_session(conn, bundle_id=bundle["bundle_id"], harness="h", transport="tmux")
        seat = k.create_seat(conn, bundle_id=bundle["bundle_id"], session_id=session["session_id"], role="worker")
        return bundle, seat

    def test_policy_verdict_in_request_json_when_provided(self):
        conn = self._make_db()
        parent_bundle, parent_seat = self._make_bundle_and_seat(conn)
        verdict_dict = evaluate_spawn_request(
            worker_harness="w", supervisor_harness="s"
        ).to_dict()

        adapter = MagicMock()
        adapter.spawn_window.return_value = {"target": "sess:win.0", "cwd": "/tmp"}
        adapter.split_pane.return_value = {"target": "sess:win.1", "cwd": "/tmp"}

        from braid2 import kernel as k
        result = k.spawn_tmux_supervised_bundle(
            conn,
            parent_bundle_id=parent_bundle["bundle_id"],
            requested_by_seat=parent_seat["seat_id"],
            worker_harness="worker-harness",
            supervisor_harness="supervisor-harness",
            goal_ref="g1",
            work_item_ref="wi-1",
            worker_cwd="/tmp",
            worker_command="echo worker",
            supervisor_cwd=None,
            supervisor_command="echo supervisor",
            tmux_session="test-session",
            window_name=None,
            adapter=adapter,
            policy_verdict=verdict_dict,
        )

        spawn_req = result["spawn_request"]
        assert spawn_req is not None
        stored_json = json.loads(spawn_req["request_json"])
        assert "policy_verdict" in stored_json
        assert stored_json["policy_verdict"]["status"] == "not_wired"
        assert stored_json["policy_verdict"]["wired"] is False

    def test_no_policy_verdict_when_not_provided(self):
        conn = self._make_db()
        parent_bundle, parent_seat = self._make_bundle_and_seat(conn)

        adapter = MagicMock()
        adapter.spawn_window.return_value = {"target": "sess:win.0", "cwd": "/tmp"}
        adapter.split_pane.return_value = {"target": "sess:win.1", "cwd": "/tmp"}

        from braid2 import kernel as k
        result = k.spawn_tmux_supervised_bundle(
            conn,
            parent_bundle_id=parent_bundle["bundle_id"],
            requested_by_seat=parent_seat["seat_id"],
            worker_harness="w",
            supervisor_harness="s",
            goal_ref=None,
            work_item_ref=None,
            worker_cwd="/tmp",
            worker_command="echo w",
            supervisor_cwd=None,
            supervisor_command="echo s",
            tmux_session="sess",
            window_name=None,
            adapter=adapter,
        )
        spawn_req = result["spawn_request"]
        stored_json = json.loads(spawn_req["request_json"])
        assert "policy_verdict" not in stored_json


# ===========================================================================
# CLI integration: --eval-policy flag propagates verdict to output
# ===========================================================================

class TestCLIEvalPolicyFlag:
    def test_eval_policy_verdict_in_output(self, tmp_path):
        """With --eval-policy the CLI output payload includes a policy_verdict key."""
        import io

        db_file = tmp_path / "braid.db"
        mock_result = {
            "bundle": {"bundle_id": "b1"},
            "spawn_request": {
                "request_id": "r1",
                "request_json": json.dumps({
                    "policy_verdict": {"status": "not_wired", "wired": False}
                }),
            },
            "worker": {},
            "supervisor": {},
            "local_thread": None,
            "parent_thread": None,
        }

        with patch("braid2.tmux_adapter.TmuxAdapter") as MockAdapter, \
             patch("braid2.kernel.spawn_tmux_supervised_bundle", return_value=mock_result):
            MockAdapter.return_value = MagicMock()
            from cli import main
            captured = io.StringIO()
            with patch("sys.stdout", captured):
                rc = main([
                    "--db-path", str(db_file),
                    "bundle", "spawn",
                    "--worker-harness", "claude-code",
                    "--supervisor-harness", "supervisor",
                    "--transport", "tmux",
                    "--worker-cwd", "/tmp",
                    "--worker-command", "echo w",
                    "--supervisor-command", "echo s",
                    "--tmux-session", "test",
                    "--eval-policy",
                ])

        output = captured.getvalue()
        payload = json.loads(output)
        assert "policy_verdict" in payload
        assert payload["policy_verdict"]["status"] == "not_wired"
        assert payload["policy_verdict"]["wired"] is False

    def test_deny_verdict_exits_with_code_2(self, tmp_path):
        """If policy returns denied, CLI exits with code 2 and does not spawn."""
        import io

        # Patch evaluate_spawn_request to return an explicit deny
        denied_verdict = PolicyVerdict(
            status="denied",
            wired=True,
            reason="test denial",
            provenance={"module": "runtime/core/policy_engine.py", "function": "evaluate", "status": "live"},
        )

        db_file = tmp_path / "braid.db"
        with patch("cli.evaluate_spawn_request", return_value=denied_verdict), \
             patch("braid2.tmux_adapter.TmuxAdapter"):
            from cli import main
            captured_err = io.StringIO()
            with patch("sys.stderr", captured_err):
                rc = main([
                    "--db-path", str(db_file),
                    "bundle", "spawn",
                    "--worker-harness", "w",
                    "--supervisor-harness", "s",
                    "--transport", "tmux",
                    "--worker-cwd", "/tmp",
                    "--worker-command", "echo w",
                    "--supervisor-command", "echo s",
                    "--tmux-session", "test",
                    "--eval-policy",
                ])
        assert rc == 2
        err_output = captured_err.getvalue()
        err_payload = json.loads(err_output)
        assert err_payload["status"] == "error"
        assert "denied" in err_payload["message"]

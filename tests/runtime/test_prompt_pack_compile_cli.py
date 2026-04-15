"""Tests for `cc-policy prompt-pack compile` (read-only operator-preview CLI).

@decision DEC-CLAUDEX-PROMPT-PACK-COMPILE-CLI-TESTS-001
Title: The read-only prompt-pack compile CLI is a thin adapter over the single compiler authority
Status: proposed (Phase 2 read-only CLI, DEC-CLAUDEX-PROMPT-PACK-COMPILE-CLI-001)
Rationale: The CLI handler is a thin wrapper around
  :func:`runtime.core.prompt_pack.compile_prompt_pack_for_stage`
  in id mode only. All compile logic lives in the library; the
  CLI layer only handles argparse binding, connection management,
  and payload shaping. These tests pin:

    1. Happy-path compile against a seeded SQLite DB returns
       exit 0 with ``status=ok`` and the full operator-preview
       payload (``workflow_id``, ``stage_id``, ``layer_names``,
       ``content_hash``, ``rendered_body``, ``metadata``,
       ``inputs``).
    2. Repeated ``--finding`` flags flow through to the compiled
       pack via ``unresolved_findings`` and appear in the
       rendered ``runtime_state_pack`` layer body.
    3. ``--current-branch`` and ``--worktree-path`` overrides
       flow through and change the compiled content hash versus
       a baseline call.
    4. Missing goal row surfaces a
       ``prompt-pack compile:`` error on stderr with the goal_id
       mentioned.
    5. Missing work-item row surfaces a
       ``prompt-pack compile:`` error with the work_item_id
       mentioned.
    6. Goal/work-item cross-check mismatch surfaces a
       ``prompt-pack compile:`` error naming both ids.
    7. Output on the happy path is valid JSON on stdout; output
       on the error path is valid JSON on stderr.
    8. Read-only guarantee: the seeded DB's
       ``sqlite_master`` row counts for ``goal_contracts`` and
       ``work_items`` are unchanged across the CLI call.
    9. CLI module-level import surface still forbids a direct
       ``runtime.core.prompt_pack`` import; the compile branch
       reaches the compiler only via a function-scope import.
"""

from __future__ import annotations

import ast
import inspect
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from runtime.core import constitution_registry as cr
from runtime.core import contracts
from runtime.core import decision_work_registry as dwr
from runtime.core import goal_contract_codec
from runtime.core import prompt_pack as pp
from runtime.core import prompt_pack_validation as ppv
from runtime.core import reviewer_findings as rf
from runtime.core import workflows as workflows_mod
from runtime.schemas import ensure_schema

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_CLI = str(_REPO_ROOT / "runtime" / "cli.py")


# ---------------------------------------------------------------------------
# Fixtures — seeded on-disk SQLite DB exposed via CLAUDE_POLICY_DB
# ---------------------------------------------------------------------------


def _seed_goal(conn, *, goal_id: str = "GOAL-CLI-1") -> None:
    goal = contracts.GoalContract(
        goal_id=goal_id,
        desired_end_state="ship the compile CLI slice",
        status="active",
        autonomy_budget=3,
        continuation_rules=("rule-a",),
        stop_conditions=("cond-a",),
        escalation_boundaries=("boundary-a",),
        user_decision_boundaries=("udb-a",),
    )
    record = goal_contract_codec.encode_goal_contract(goal)
    dwr.insert_goal(conn, record)


def _seed_work_item(
    conn,
    *,
    work_item_id: str = "WI-CLI-1",
    goal_id: str = "GOAL-CLI-1",
    title: str = "compile cli slice",
) -> None:
    record = dwr.WorkItemRecord(
        work_item_id=work_item_id,
        goal_id=goal_id,
        title=title,
        status="in_progress",
        version=1,
        author="planner",
        scope_json=(
            '{"allowed_paths":["runtime/cli.py"],'
            '"required_paths":["tests/runtime/test_prompt_pack_compile_cli.py"],'
            '"forbidden_paths":[],'
            '"state_domains":["goal_contracts","work_items"]}'
        ),
        evaluation_json=(
            '{"required_tests":["pytest tests/runtime/test_prompt_pack_compile_cli.py"],'
            '"required_evidence":["verbatim pytest footer"],'
            '"rollback_boundary":"git restore runtime/cli.py",'
            '"acceptance_notes":"id-mode compile CLI returns operator-preview JSON"}'
        ),
        head_sha=None,
        reviewer_round=1,
    )
    dwr.insert_work_item(conn, record)


def _seed_workflow_binding(
    conn,
    *,
    workflow_id: str = "wf-cli",
    branch: str = "feature/prompt-pack-cli",
    worktree_path: str = "/tmp/wf-cli",
) -> None:
    workflows_mod.bind_workflow(
        conn,
        workflow_id=workflow_id,
        worktree_path=worktree_path,
        branch=branch,
    )


@pytest.fixture
def seeded_db(tmp_path: Path):
    """Create an on-disk SQLite DB with goal + work item + workflow binding."""
    db_path = tmp_path / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _seed_goal(conn)
        _seed_work_item(conn)
        _seed_workflow_binding(conn)
        conn.commit()
    finally:
        conn.close()
    return db_path


def _run_cli(args: list[str], db_path: Path) -> tuple[int, dict, str, str]:
    """Invoke cc-policy via subprocess; return (rc, parsed_json, stdout, stderr)."""
    env = {
        **os.environ,
        "PYTHONPATH": str(_REPO_ROOT),
        "CLAUDE_POLICY_DB": str(db_path),
    }
    result = subprocess.run(
        [sys.executable, _CLI] + args,
        capture_output=True,
        text=True,
        env=env,
    )
    output = result.stdout.strip() or result.stderr.strip()
    try:
        parsed = json.loads(output)
    except json.JSONDecodeError:
        parsed = {"_raw": output}
    return result.returncode, parsed, result.stdout, result.stderr


def _compile_args(
    *,
    workflow_id: str = "wf-cli",
    stage_id: str = "planner",
    goal_id: str = "GOAL-CLI-1",
    work_item_id: str = "WI-CLI-1",
    decision_scope: str = "kernel",
    generated_at: int = 1_700_000_000,
    findings: tuple[str, ...] = (),
    current_branch: str | None = None,
    worktree_path: str | None = None,
    manifest_version: str | None = None,
) -> list[str]:
    args = [
        "prompt-pack",
        "compile",
        "--workflow-id",
        workflow_id,
        "--stage-id",
        stage_id,
        "--goal-id",
        goal_id,
        "--work-item-id",
        work_item_id,
        "--decision-scope",
        decision_scope,
        "--generated-at",
        str(generated_at),
    ]
    for f in findings:
        args.extend(["--finding", f])
    if current_branch is not None:
        args.extend(["--current-branch", current_branch])
    if worktree_path is not None:
        args.extend(["--worktree-path", worktree_path])
    if manifest_version is not None:
        args.extend(["--manifest-version", manifest_version])
    return args


# ---------------------------------------------------------------------------
# 1. Happy-path compile
# ---------------------------------------------------------------------------


class TestHappyPath:
    def test_exit_zero(self, seeded_db):
        rc, _out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        assert rc == 0

    def test_status_ok(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        assert out["status"] == "ok"

    def test_workflow_and_stage_ids_echoed(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        assert out["workflow_id"] == "wf-cli"
        assert out["stage_id"] == "planner"

    def test_layer_names_match_canonical_order(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        assert out["layer_names"] == list(pp.CANONICAL_LAYER_ORDER)

    def test_content_hash_present_and_sha256_prefixed(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        assert "content_hash" in out
        assert out["content_hash"].startswith("sha256:")

    def test_rendered_body_starts_with_h1_title(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        body = out["rendered_body"]
        first_line = body.splitlines()[0]
        assert first_line == "# ClauDEX Prompt Pack: wf-cli @ planner"

    def test_rendered_body_contains_every_layer_heading(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        body = out["rendered_body"]
        headings = [
            line[3:] for line in body.splitlines() if line.startswith("## ")
        ]
        assert headings == list(pp.CANONICAL_LAYER_ORDER)

    def test_metadata_generator_version_populated(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        meta = out["metadata"]
        assert meta["generator_version"] == pp.PROMPT_PACK_GENERATOR_VERSION

    def test_metadata_generated_at_roundtrips(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(generated_at=1_700_000_777), seeded_db
        )
        assert out["metadata"]["generated_at"] == 1_700_000_777

    def test_metadata_source_versions_is_list_of_pairs(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        source_versions = out["metadata"]["source_versions"]
        assert isinstance(source_versions, list)
        assert len(source_versions) == 1
        assert source_versions[0][0] == "prompt_pack_layers"

    def test_metadata_provenance_has_one_ref_per_layer(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        provenance = out["metadata"]["provenance"]
        assert len(provenance) == len(pp.CANONICAL_LAYER_ORDER)
        for ref, layer_name in zip(provenance, pp.CANONICAL_LAYER_ORDER):
            assert ref["source_kind"] == "prompt_pack_layer"
            assert ref["source_id"] == layer_name

    def test_metadata_stale_condition_lists_watched_authorities(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        stale = out["metadata"]["stale_condition"]
        assert "rationale" in stale
        assert "hook_wiring" in stale["watched_authorities"]

    def test_metadata_stale_condition_watched_files_is_full_constitution_set(
        self, seeded_db
    ):
        """Phase 7 Slice 11: the CLI compile path emits the full concrete
        constitution-level path set, sourced from ``constitution_registry``
        rather than a hardcoded pair. Tests do not duplicate the list;
        the registry is the sole authority."""
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        watched = tuple(out["metadata"]["stale_condition"]["watched_files"])
        # Authority-derived: full concrete set in deterministic order.
        assert watched == cr.all_concrete_paths()

    def test_metadata_stale_condition_watched_files_includes_phase7_promotions(
        self, seeded_db
    ):
        """Phase 7 Slice 11: the Slice 8 + Slice 10 promotions must reach
        the CLI surface — non-trivial proof that the registry-derived
        path actually flows all the way through the compile-path JSON."""
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        watched = out["metadata"]["stale_condition"]["watched_files"]
        assert "runtime/core/prompt_pack_resolver.py" in watched
        assert "runtime/core/hook_manifest.py" in watched

    def test_inputs_echo_includes_goal_and_work_item_ids(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        inputs = out["inputs"]
        assert inputs["goal_id"] == "GOAL-CLI-1"
        assert inputs["work_item_id"] == "WI-CLI-1"
        assert inputs["decision_scope"] == "kernel"
        assert inputs["unresolved_findings"] is None

    def test_manifest_version_defaults_to_module_default(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        assert out["inputs"]["manifest_version"] == pp.MANIFEST_VERSION

    def test_manifest_version_override_flows_through(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(manifest_version="9.9.9"), seeded_db
        )
        assert out["inputs"]["manifest_version"] == "9.9.9"
        # And the provenance reflects the override.
        for ref in out["metadata"]["provenance"]:
            assert ref["source_version"] == "9.9.9"


# ---------------------------------------------------------------------------
# 2. Finding flags flow through
# ---------------------------------------------------------------------------


class TestFindingFlagsPassThrough:
    def test_single_finding_in_inputs_echo(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(findings=("finding-a",)), seeded_db
        )
        assert out["inputs"]["unresolved_findings"] == ["finding-a"]

    def test_multiple_findings_preserved_in_order(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(findings=("finding-a", "finding-b", "finding-c")),
            seeded_db,
        )
        assert out["inputs"]["unresolved_findings"] == [
            "finding-a",
            "finding-b",
            "finding-c",
        ]

    def test_finding_appears_in_runtime_state_pack_body(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(findings=("finding-e2e",)), seeded_db
        )
        body = out["rendered_body"]
        assert "finding-e2e" in body

    def test_finding_changes_content_hash(self, seeded_db):
        _rc_a, out_a, _, _ = _run_cli(_compile_args(), seeded_db)
        _rc_b, out_b, _, _ = _run_cli(
            _compile_args(findings=("finding-x",)), seeded_db
        )
        assert out_a["content_hash"] != out_b["content_hash"]


# ---------------------------------------------------------------------------
# 2b. Live findings capture + explicit override suppression
# ---------------------------------------------------------------------------


def _seed_finding(
    conn,
    *,
    finding_id: str,
    workflow_id: str = "wf-cli",
    work_item_id: str | None = "WI-CLI-1",
    severity: str = "blocking",
    title: str = "Null pointer",
    file_path: str | None = "src/app.py",
    line: int | None = 10,
) -> None:
    rf.upsert(
        conn,
        finding_id=finding_id,
        workflow_id=workflow_id,
        severity=severity,
        status="open",
        title=title,
        detail="detail",
        work_item_id=work_item_id,
        file_path=file_path,
        line=line,
    )


@pytest.fixture
def seeded_db_with_findings(tmp_path: Path):
    """Seeded DB with goal + work item + workflow binding + reviewer findings."""
    db_path = tmp_path / "state.db"
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        ensure_schema(conn)
        _seed_goal(conn)
        _seed_work_item(conn)
        _seed_workflow_binding(conn)
        # Finding for WI-CLI-1 (should appear when compiling for WI-CLI-1)
        _seed_finding(
            conn,
            finding_id="f-cli-001",
            work_item_id="WI-CLI-1",
            severity="blocking",
            title="Null pointer",
            file_path="src/app.py",
            line=10,
        )
        # Finding for a different work item (should be excluded when
        # compiling for WI-CLI-1)
        _seed_finding(
            conn,
            finding_id="f-cli-002",
            work_item_id="WI-OTHER",
            severity="concern",
            title="Stale import",
            file_path="src/util.py",
            line=5,
        )
        conn.commit()
    finally:
        conn.close()
    return db_path


class TestLiveFindingsInRenderedBody:
    """Live findings from the reviewer ledger flow into the rendered body
    when no ``--finding`` flags are supplied."""

    def test_live_finding_appears_in_rendered_body(self, seeded_db_with_findings):
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(), seeded_db_with_findings
        )
        assert out["status"] == "ok"
        body = out["rendered_body"]
        # The pinned render format: [severity] finding_id: title (file:line)
        assert "[blocking] f-cli-001: Null pointer (src/app.py:10)" in body

    def test_other_work_item_finding_excluded(self, seeded_db_with_findings):
        """Finding for WI-OTHER must not appear when compiling for WI-CLI-1."""
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(), seeded_db_with_findings
        )
        body = out["rendered_body"]
        assert "f-cli-002" not in body
        assert "Stale import" not in body

    def test_inputs_echo_is_null_when_live(self, seeded_db_with_findings):
        """When live capture is used, inputs echo shows null (not the
        rendered findings)."""
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(), seeded_db_with_findings
        )
        assert out["inputs"]["unresolved_findings"] is None


class TestExplicitOverrideSuppressesLive:
    """``--finding`` flags suppress live ledger findings in the rendered body,
    not just in the inputs echo."""

    def test_explicit_flag_replaces_live_in_body(self, seeded_db_with_findings):
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(findings=("override-finding-x",)),
            seeded_db_with_findings,
        )
        body = out["rendered_body"]
        # The explicit override is in the body.
        assert "override-finding-x" in body
        # The live finding is NOT in the body.
        assert "f-cli-001" not in body
        assert "Null pointer" not in body

    def test_explicit_empty_not_possible_via_cli(self, seeded_db_with_findings):
        """When no --finding flags are given, findings is None (live capture).
        There is no way to pass an explicit empty tuple via CLI args — this
        test documents the design: absence of --finding means live."""
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(), seeded_db_with_findings
        )
        assert out["inputs"]["unresolved_findings"] is None
        # Live capture finds the seeded finding.
        assert "f-cli-001" in out["rendered_body"]


# ---------------------------------------------------------------------------
# 3. Branch / worktree overrides flow through
# ---------------------------------------------------------------------------


class TestOverrides:
    def test_current_branch_override_changes_content_hash(self, seeded_db):
        _rc_a, out_a, _, _ = _run_cli(_compile_args(), seeded_db)
        _rc_b, out_b, _, _ = _run_cli(
            _compile_args(current_branch="feature/explicit-override"),
            seeded_db,
        )
        assert out_a["content_hash"] != out_b["content_hash"]
        assert out_b["inputs"]["current_branch"] == "feature/explicit-override"

    def test_worktree_path_override_changes_content_hash(self, seeded_db):
        _rc_a, out_a, _, _ = _run_cli(_compile_args(), seeded_db)
        _rc_b, out_b, _, _ = _run_cli(
            _compile_args(worktree_path="/tmp/explicit-override"),
            seeded_db,
        )
        assert out_a["content_hash"] != out_b["content_hash"]
        assert out_b["inputs"]["worktree_path"] == "/tmp/explicit-override"


# ---------------------------------------------------------------------------
# 3b. validation_inputs round-trip (Phase 7 Slice 2)
# ---------------------------------------------------------------------------


class TestValidationInputs:
    """Phase 7 Slice 2: compile output contains ``validation_inputs`` suitable
    for writing to the ``--inputs-path`` consumed by ``prompt-pack check``.
    This closes the derived-surface freshness gap: a compiled artifact can be
    revalidated from the compile output alone."""

    def test_validation_inputs_present_and_has_stable_keys(self, seeded_db):
        _rc, out, _, _ = _run_cli(_compile_args(), seeded_db)
        vi = out["validation_inputs"]
        # Phase 7 Slice 12: ``watched_files`` added to the stable key
        # set so metadata-path revalidation can rebuild the expected
        # ``stale_condition.watched_files`` tuple.
        assert set(vi.keys()) == {
            "workflow_id",
            "stage_id",
            "layers",
            "generated_at",
            "manifest_version",
            "watched_files",
        }

    def test_validation_inputs_ids_match_compile_args(self, seeded_db):
        _rc, out, _, _ = _run_cli(_compile_args(), seeded_db)
        vi = out["validation_inputs"]
        assert vi["workflow_id"] == "wf-cli"
        assert vi["stage_id"] == "planner"

    def test_validation_inputs_layers_keys_match_canonical_order(self, seeded_db):
        _rc, out, _, _ = _run_cli(_compile_args(), seeded_db)
        vi = out["validation_inputs"]
        assert list(vi["layers"].keys()) == list(pp.CANONICAL_LAYER_ORDER)

    def test_validation_inputs_generated_at_roundtrips(self, seeded_db):
        _rc, out, _, _ = _run_cli(
            _compile_args(generated_at=1_700_000_999), seeded_db
        )
        assert out["validation_inputs"]["generated_at"] == 1_700_000_999

    def test_validation_inputs_manifest_version_default(self, seeded_db):
        _rc, out, _, _ = _run_cli(_compile_args(), seeded_db)
        assert out["validation_inputs"]["manifest_version"] == pp.MANIFEST_VERSION

    def test_validation_inputs_manifest_version_override(self, seeded_db):
        _rc, out, _, _ = _run_cli(
            _compile_args(manifest_version="8.8.8"), seeded_db
        )
        assert out["validation_inputs"]["manifest_version"] == "8.8.8"

    def test_roundtrip_check_passes(self, seeded_db, tmp_path):
        """Write rendered_body + validation_inputs to files, invoke
        ``cc-policy prompt-pack check`` — must exit 0 with healthy=True
        and matching content hash."""
        _rc, out, _, _ = _run_cli(_compile_args(), seeded_db)
        assert _rc == 0

        body_path = tmp_path / "body.md"
        inputs_path = tmp_path / "inputs.json"
        body_path.write_text(out["rendered_body"])
        inputs_path.write_text(json.dumps(out["validation_inputs"]))

        rc, check_out, _, _ = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(body_path),
                "--inputs-path",
                str(inputs_path),
            ],
            seeded_db,
        )
        assert rc == 0, f"round-trip check failed: {check_out}"
        assert check_out["report"]["healthy"] is True
        assert check_out["report"]["exact_match"] is True

    def test_mutated_body_fails_roundtrip_check(self, seeded_db, tmp_path):
        """If rendered_body is tampered with, check must report drift."""
        _rc, out, _, _ = _run_cli(_compile_args(), seeded_db)

        body_path = tmp_path / "body.md"
        inputs_path = tmp_path / "inputs.json"
        body_path.write_text(out["rendered_body"] + "\nTAMPERED LINE\n")
        inputs_path.write_text(json.dumps(out["validation_inputs"]))

        rc, check_out, _, _ = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(body_path),
                "--inputs-path",
                str(inputs_path),
            ],
            seeded_db,
        )
        assert rc == 1, f"mutated body should have failed check: {check_out}"
        assert check_out["report"]["healthy"] is False

    def test_validation_inputs_watched_files_is_constitution_set(
        self, seeded_db
    ):
        """Phase 7 Slice 12: ``validation_inputs.watched_files`` equals the
        full concrete constitution set in deterministic registry order."""
        _rc, out, _, _ = _run_cli(_compile_args(), seeded_db)
        watched = tuple(out["validation_inputs"]["watched_files"])
        # Authority-derived: no hardcoded list duplication.
        assert watched == cr.all_concrete_paths()

    def test_validation_inputs_watched_files_matches_metadata(self, seeded_db):
        """Phase 7 Slice 12: validation_inputs.watched_files and
        metadata.stale_condition.watched_files are the same sequence —
        the compile surface cannot emit one without the other."""
        _rc, out, _, _ = _run_cli(_compile_args(), seeded_db)
        assert (
            out["validation_inputs"]["watched_files"]
            == out["metadata"]["stale_condition"]["watched_files"]
        )

    def test_compile_metadata_equals_public_serialiser(self, seeded_db):
        """Phase 7 Slice 12 correction: the compile CLI must emit
        ``payload["metadata"]`` via the public single-authority helper
        ``prompt_pack_validation.serialise_prompt_pack_metadata``. We
        prove equality by rebuilding the pack from the CLI's own
        ``validation_inputs`` + ``watched_files`` and asserting the
        serialiser output is byte-for-byte identical to
        ``out["metadata"]``. If the CLI regressed to inline construction
        and then drifted, this test would fail."""
        _rc, out, _, _ = _run_cli(_compile_args(), seeded_db)
        assert _rc == 0
        vi = out["validation_inputs"]
        rebuilt = pp.build_prompt_pack(
            workflow_id=vi["workflow_id"],
            stage_id=vi["stage_id"],
            layers=vi["layers"],
            generated_at=vi["generated_at"],
            manifest_version=vi["manifest_version"],
            watched_files=tuple(vi["watched_files"]),
        )
        assert out["metadata"] == ppv.serialise_prompt_pack_metadata(
            rebuilt.metadata
        )

    def test_roundtrip_metadata_path_check_passes(self, seeded_db, tmp_path):
        """Phase 7 Slice 12: writing rendered_body + validation_inputs +
        metadata to files and invoking ``prompt-pack check --metadata-path``
        must exit 0 with both body and metadata reports healthy."""
        _rc, out, _, _ = _run_cli(_compile_args(), seeded_db)
        assert _rc == 0

        body_path = tmp_path / "body.md"
        inputs_path = tmp_path / "inputs.json"
        metadata_path = tmp_path / "metadata.json"
        body_path.write_text(out["rendered_body"])
        inputs_path.write_text(json.dumps(out["validation_inputs"]))
        metadata_path.write_text(json.dumps(out["metadata"]))

        rc, check_out, _, _ = _run_cli(
            [
                "prompt-pack",
                "check",
                "--candidate-path",
                str(body_path),
                "--inputs-path",
                str(inputs_path),
                "--metadata-path",
                str(metadata_path),
            ],
            seeded_db,
        )
        assert rc == 0, f"metadata-path round-trip failed: {check_out}"
        assert check_out["report"]["healthy"] is True
        assert check_out["metadata_report"]["healthy"] is True
        assert check_out["metadata_report"]["exact_match"] is True
        assert check_out["metadata_path"] == str(metadata_path.resolve())


# ---------------------------------------------------------------------------
# 4. Error paths — missing goal / work item / cross-check mismatch
# ---------------------------------------------------------------------------


class TestMissingGoal:
    def test_missing_goal_returns_non_zero(self, seeded_db):
        rc, _out, _stdout, _stderr = _run_cli(
            _compile_args(goal_id="GOAL-ghost"), seeded_db
        )
        assert rc != 0

    def test_missing_goal_error_has_prefix(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(goal_id="GOAL-ghost"), seeded_db
        )
        assert out["status"] == "error"
        assert out["message"].startswith("prompt-pack compile:")

    def test_missing_goal_error_names_goal_id(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(goal_id="GOAL-ghost"), seeded_db
        )
        assert "GOAL-ghost" in out["message"]
        assert "goal_id" in out["message"]

    def test_missing_goal_error_on_stderr(self, seeded_db):
        _rc, _out, stdout, stderr = _run_cli(
            _compile_args(goal_id="GOAL-ghost"), seeded_db
        )
        assert stdout == ""
        assert stderr.strip() != ""


class TestMissingWorkItem:
    def test_missing_work_item_returns_non_zero(self, seeded_db):
        rc, _out, _stdout, _stderr = _run_cli(
            _compile_args(work_item_id="WI-ghost"), seeded_db
        )
        assert rc != 0

    def test_missing_work_item_error_has_prefix(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(work_item_id="WI-ghost"), seeded_db
        )
        assert out["status"] == "error"
        assert out["message"].startswith("prompt-pack compile:")

    def test_missing_work_item_error_names_work_item_id(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(
            _compile_args(work_item_id="WI-ghost"), seeded_db
        )
        assert "WI-ghost" in out["message"]
        assert "work_item_id" in out["message"]


class TestCrossCheckMismatch:
    def test_mismatched_goal_returns_non_zero(self, tmp_path: Path):
        db_path = tmp_path / "state.db"
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        try:
            ensure_schema(conn)
            _seed_goal(conn, goal_id="GOAL-CALLER")
            _seed_goal(conn, goal_id="GOAL-WRONG")
            _seed_work_item(
                conn,
                work_item_id="WI-MISMATCH",
                goal_id="GOAL-WRONG",
            )
            _seed_workflow_binding(conn)
            conn.commit()
        finally:
            conn.close()

        rc, out, _stdout, _stderr = _run_cli(
            _compile_args(
                goal_id="GOAL-CALLER",
                work_item_id="WI-MISMATCH",
            ),
            db_path,
        )
        assert rc != 0
        assert out["status"] == "error"
        assert out["message"].startswith("prompt-pack compile:")
        # Both ids must be named so the operator can diagnose.
        assert "GOAL-CALLER" in out["message"]
        assert "GOAL-WRONG" in out["message"]


# ---------------------------------------------------------------------------
# 5. Output formatting guarantees
# ---------------------------------------------------------------------------


class TestOutputFormatting:
    def test_happy_output_is_valid_json_on_stdout(self, seeded_db):
        _rc, _out, stdout, _stderr = _run_cli(_compile_args(), seeded_db)
        parsed = json.loads(stdout.strip())
        assert parsed["status"] == "ok"

    def test_error_output_is_valid_json_on_stderr(self, seeded_db):
        _rc, _out, _stdout, stderr = _run_cli(
            _compile_args(goal_id="GOAL-ghost"), seeded_db
        )
        parsed = json.loads(stderr.strip())
        assert parsed["status"] == "error"


# ---------------------------------------------------------------------------
# 6. Read-only guarantee
# ---------------------------------------------------------------------------


class TestReadOnly:
    def test_seeded_row_counts_unchanged(self, seeded_db):
        def _counts(conn) -> dict:
            return {
                "goal_contracts": conn.execute(
                    "SELECT COUNT(*) FROM goal_contracts"
                ).fetchone()[0],
                "work_items": conn.execute(
                    "SELECT COUNT(*) FROM work_items"
                ).fetchone()[0],
                "workflow_bindings": conn.execute(
                    "SELECT COUNT(*) FROM workflow_bindings"
                ).fetchone()[0],
            }

        conn = sqlite3.connect(str(seeded_db))
        try:
            before = _counts(conn)
        finally:
            conn.close()

        _rc, _out, _stdout, _stderr = _run_cli(_compile_args(), seeded_db)

        conn = sqlite3.connect(str(seeded_db))
        try:
            after = _counts(conn)
        finally:
            conn.close()

        assert before == after, f"CLI mutated DB: {before} -> {after}"


# ---------------------------------------------------------------------------
# 7. Shadow-only discipline — CLI module-level imports
# ---------------------------------------------------------------------------


def _module_level_imports(module) -> set[str]:
    """Return only the top-level ``import`` / ``from ... import`` names."""
    tree = ast.parse(inspect.getsource(module))
    names: set[str] = set()
    for node in tree.body:
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            base = node.module or ""
            if base:
                names.add(base)
                for alias in node.names:
                    names.add(f"{base}.{alias.name}")
    return names


class TestShadowOnlyDiscipline:
    def test_cli_does_not_module_level_import_prompt_pack(self):
        # The compile branch reaches the compiler only via a
        # function-scope import inside ``_handle_prompt_pack``.
        # The module-level import surface of ``runtime/cli.py``
        # must continue to reach the compiler only transitively
        # through ``runtime.core.prompt_pack_validation``.
        import runtime.cli as cli

        for name in _module_level_imports(cli):
            assert name != "runtime.core.prompt_pack" and not name.startswith(
                "runtime.core.prompt_pack."
            ), (
                f"cli.py module-level import {name!r} promotes the "
                f"compiler to an always-loaded CLI dependency"
            )

    def test_cli_function_scope_import_is_reachable_in_source(self):
        # Pin that the compile branch actually imports the compiler
        # somewhere in the module source (but NOT at module level).
        # This catches a regression where the function-scope import
        # is dropped in a refactor.
        import runtime.cli as cli

        source = inspect.getsource(cli)
        assert "from runtime.core import prompt_pack as prompt_pack_mod" in source

    def test_cli_does_not_module_level_import_workflow_capture(self):
        import runtime.cli as cli

        for name in _module_level_imports(cli):
            assert "workflow_contract_capture" not in name, (
                f"cli.py module-level import {name!r} promotes the "
                f"workflow capture helper to an always-loaded CLI dependency"
            )


# ---------------------------------------------------------------------------
# 8. subagent-start adapter — thin wrapper over
#    build_subagent_start_prompt_pack_response
# ---------------------------------------------------------------------------


def _valid_sa_payload(**overrides) -> dict:
    base: dict = {
        "workflow_id": "wf-cli",
        "stage_id": "planner",
        "goal_id": "GOAL-CLI-1",
        "work_item_id": "WI-CLI-1",
        "decision_scope": "kernel",
        "generated_at": 1_700_000_000,
    }
    base.update(overrides)
    return base


def _sa_args(
    *,
    payload_dict: dict | None = None,
    payload_json: str | None = None,
) -> list[str]:
    """Build CLI args for ``prompt-pack subagent-start``."""
    if payload_json is None:
        if payload_dict is None:
            payload_dict = _valid_sa_payload()
        payload_json = json.dumps(payload_dict)
    return ["prompt-pack", "subagent-start", "--payload", payload_json]


class TestSubagentStartHappyPath:
    def test_exit_zero(self, seeded_db):
        rc, _out, _stdout, _stderr = _run_cli(_sa_args(), seeded_db)
        assert rc == 0

    def test_status_ok(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_sa_args(), seeded_db)
        assert out["status"] == "ok"

    def test_healthy_true(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_sa_args(), seeded_db)
        assert out["healthy"] is True

    def test_violations_empty(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_sa_args(), seeded_db)
        assert out["violations"] == []

    def test_envelope_present(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_sa_args(), seeded_db)
        assert out["envelope"] is not None

    def test_envelope_hook_specific_output_key(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_sa_args(), seeded_db)
        assert "hookSpecificOutput" in out["envelope"]

    def test_envelope_hook_event_name(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_sa_args(), seeded_db)
        hso = out["envelope"]["hookSpecificOutput"]
        assert hso["hookEventName"] == "SubagentStart"

    def test_envelope_additional_context_non_empty(self, seeded_db):
        _rc, out, _stdout, _stderr = _run_cli(_sa_args(), seeded_db)
        hso = out["envelope"]["hookSpecificOutput"]
        assert isinstance(hso["additionalContext"], str)
        assert hso["additionalContext"].strip()

    def test_output_on_stdout_not_stderr(self, seeded_db):
        _rc, _out, stdout, stderr = _run_cli(_sa_args(), seeded_db)
        assert stdout.strip()
        assert not stderr.strip()


class TestSubagentStartInvalidPayload:
    """Invalid payloads short-circuit in the helper and come back as
    an unhealthy report on stdout (exit 1) — not as a CLI-level error
    on stderr.  The shell hook can inspect ``healthy`` without special-
    casing the CLI exit shape.
    """

    def test_missing_field_exits_nonzero(self, seeded_db):
        payload = _valid_sa_payload()
        del payload["goal_id"]
        rc, _out, _stdout, _stderr = _run_cli(_sa_args(payload_dict=payload), seeded_db)
        assert rc != 0

    def test_missing_field_status_invalid(self, seeded_db):
        payload = _valid_sa_payload()
        del payload["goal_id"]
        _rc, _out, stdout, _stderr = _run_cli(_sa_args(payload_dict=payload), seeded_db)
        parsed = json.loads(stdout.strip())
        assert parsed["status"] == "invalid"

    def test_missing_field_healthy_false(self, seeded_db):
        payload = _valid_sa_payload()
        del payload["stage_id"]
        _rc, _out, stdout, _stderr = _run_cli(_sa_args(payload_dict=payload), seeded_db)
        parsed = json.loads(stdout.strip())
        assert parsed["healthy"] is False

    def test_missing_field_violations_non_empty(self, seeded_db):
        payload = _valid_sa_payload()
        del payload["work_item_id"]
        _rc, _out, stdout, _stderr = _run_cli(_sa_args(payload_dict=payload), seeded_db)
        parsed = json.loads(stdout.strip())
        assert len(parsed["violations"]) > 0

    def test_wrong_type_generated_at_status_invalid(self, seeded_db):
        payload = _valid_sa_payload(generated_at="not-an-int")
        _rc, _out, stdout, _stderr = _run_cli(_sa_args(payload_dict=payload), seeded_db)
        parsed = json.loads(stdout.strip())
        assert parsed["status"] == "invalid"

    def test_non_mapping_payload_status_invalid(self, seeded_db):
        # A JSON array is valid JSON but fails request validation
        # → unhealthy report on stdout (exit 1), not a CLI-level error.
        _rc, _out, stdout, _stderr = _run_cli(
            _sa_args(payload_json='["not", "a", "dict"]'), seeded_db
        )
        parsed = json.loads(stdout.strip())
        assert parsed["status"] == "invalid"

    def test_non_json_payload_is_cli_error_on_stderr(self, seeded_db):
        rc, _out, _stdout, stderr = _run_cli(
            _sa_args(payload_json="not-json"), seeded_db
        )
        assert rc != 0
        parsed = json.loads(stderr.strip())
        assert parsed["status"] == "error"
        assert "prompt-pack subagent-start:" in parsed["message"]


class TestSubagentStartCompileErrors:
    """LookupError / ValueError from the compilation pipeline surface as CLI
    errors on stderr with the ``prompt-pack subagent-start:`` prefix.
    """

    def test_missing_goal_exits_nonzero(self, seeded_db):
        payload = _valid_sa_payload(goal_id="GOAL-ghost")
        rc, _out, _stdout, _stderr = _run_cli(_sa_args(payload_dict=payload), seeded_db)
        assert rc != 0

    def test_missing_goal_error_on_stderr(self, seeded_db):
        payload = _valid_sa_payload(goal_id="GOAL-ghost")
        _rc, _out, _stdout, stderr = _run_cli(_sa_args(payload_dict=payload), seeded_db)
        parsed = json.loads(stderr.strip())
        assert parsed["status"] == "error"

    def test_missing_goal_prefix_on_message(self, seeded_db):
        payload = _valid_sa_payload(goal_id="GOAL-ghost")
        _rc, _out, _stdout, stderr = _run_cli(_sa_args(payload_dict=payload), seeded_db)
        parsed = json.loads(stderr.strip())
        assert parsed["message"].startswith("prompt-pack subagent-start:")

    def test_missing_goal_id_mentioned_in_message(self, seeded_db):
        payload = _valid_sa_payload(goal_id="GOAL-ghost-999")
        _rc, _out, _stdout, stderr = _run_cli(_sa_args(payload_dict=payload), seeded_db)
        parsed = json.loads(stderr.strip())
        assert "GOAL-ghost-999" in parsed["message"]

    def test_missing_work_item_error_on_stderr(self, seeded_db):
        payload = _valid_sa_payload(work_item_id="WI-ghost")
        rc, _out, _stdout, stderr = _run_cli(_sa_args(payload_dict=payload), seeded_db)
        assert rc != 0
        parsed = json.loads(stderr.strip())
        assert parsed["status"] == "error"
        assert parsed["message"].startswith("prompt-pack subagent-start:")


class TestSubagentStartReadOnly:
    def test_seeded_row_counts_unchanged(self, seeded_db):
        def _counts(conn) -> dict:
            return {
                "goal_contracts": conn.execute(
                    "SELECT COUNT(*) FROM goal_contracts"
                ).fetchone()[0],
                "work_items": conn.execute(
                    "SELECT COUNT(*) FROM work_items"
                ).fetchone()[0],
                "workflow_bindings": conn.execute(
                    "SELECT COUNT(*) FROM workflow_bindings"
                ).fetchone()[0],
            }

        conn = sqlite3.connect(str(seeded_db))
        try:
            before = _counts(conn)
        finally:
            conn.close()

        _run_cli(_sa_args(), seeded_db)

        conn = sqlite3.connect(str(seeded_db))
        try:
            after = _counts(conn)
        finally:
            conn.close()

        assert before == after, f"CLI mutated DB: {before} -> {after}"


class TestSubagentStartShadowDiscipline:
    def test_no_module_level_prompt_pack_import(self):
        # The subagent-start branch shares the compile branch's
        # function-scope import pattern.  Module-level import surface
        # is governed by the existing TestShadowOnlyDiscipline; this
        # test just pins the subagent-start action string is present.
        import runtime.cli as cli

        for name in _module_level_imports(cli):
            assert name != "runtime.core.prompt_pack" and not name.startswith(
                "runtime.core.prompt_pack."
            ), (
                f"cli.py module-level import {name!r} promotes the "
                f"compiler to an always-loaded CLI dependency"
            )

    def test_subagent_start_action_registered_in_source(self):
        import runtime.cli as cli

        source = inspect.getsource(cli)
        assert ('"subagent-start"' in source) or ("'subagent-start'" in source), (
            "subagent-start action string not found in cli.py source — "
            "subparser may not be registered"
        )

    def test_function_scope_import_used_in_subagent_start_branch(self):
        # Both compile and subagent-start branches share the same
        # function-scope import token.  One occurrence is sufficient
        # given the module-level guard already prohibits hoisting.
        import runtime.cli as cli

        source = inspect.getsource(cli)
        assert "from runtime.core import prompt_pack as prompt_pack_mod" in source, (
            "function-scope prompt_pack import not found in cli.py — "
            "the subagent-start branch may have hoisted it to module level"
        )

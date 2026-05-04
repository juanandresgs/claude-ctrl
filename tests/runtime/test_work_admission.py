from __future__ import annotations

import subprocess
from pathlib import Path

from runtime.core import leases, scratchlanes, work_admission, workflows
from runtime.core.db import connect_memory
from runtime.schemas import ensure_schema


def _conn():
    conn = connect_memory()
    ensure_schema(conn)
    return conn


def _git_init(path: Path, *, branch: str = "feature/admission") -> None:
    subprocess.run(["git", "init", "-q", "-b", branch], cwd=path, check=True)
    subprocess.run(
        ["git", "config", "user.email", "admission@example.test"],
        cwd=path,
        check=True,
    )
    subprocess.run(
        ["git", "config", "user.name", "Admission Test"],
        cwd=path,
        check=True,
    )
    (path / "README.md").write_text("# admission\n", encoding="utf-8")
    subprocess.run(["git", "add", "README.md"], cwd=path, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "init"], cwd=path, check=True)


def _payload(root: Path, target: str = "src/app.py", **overrides):
    data = {
        "trigger": "source_write",
        "project_root": str(root),
        "cwd": str(root),
        "target_path": str(root / target),
        "workflow_id": "wf-admission",
    }
    data.update(overrides)
    return data


def test_non_git_source_edit_requires_project_onboarding(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    conn = _conn()
    try:
        result = work_admission.classify_payload(conn, _payload(root))
    finally:
        conn.close()

    assert result["verdict"] == work_admission.VERDICT_PROJECT_ONBOARDING_REQUIRED
    assert result["next_authority"] == "workflow_bootstrap"


def test_tmp_source_candidate_authorizes_scratchlane(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    conn = _conn()
    try:
        result = work_admission.classify_payload(
            conn,
            _payload(root, "tmp/dedup.py", workflow_id=""),
        )
    finally:
        conn.close()

    assert result["verdict"] == work_admission.VERDICT_SCRATCHLANE_AUTHORIZED
    assert result["scratchlane"]["task_slug"] == "dedup"
    assert result["scratchlane"]["relative_path"] == "tmp/dedup/"


def test_scratch_prompt_targeting_source_requires_user_decision(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    conn = _conn()
    try:
        result = work_admission.classify_payload(
            conn,
            _payload(root, user_prompt="quick scratch helper in src/app.py"),
        )
    finally:
        conn.close()

    assert result["verdict"] == work_admission.VERDICT_USER_DECISION_REQUIRED
    assert result["next_authority"] == "user"


def test_git_repo_without_binding_requires_workflow_bootstrap(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    _git_init(root)
    conn = _conn()
    try:
        result = work_admission.classify_payload(conn, _payload(root))
    finally:
        conn.close()

    assert result["verdict"] == work_admission.VERDICT_WORKFLOW_BOOTSTRAP_REQUIRED


def test_bound_workflow_without_scope_requires_planner(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    _git_init(root)
    conn = _conn()
    try:
        workflows.bind_workflow(
            conn,
            workflow_id="wf-admission",
            worktree_path=str(root),
            branch="feature/admission",
        )
        result = work_admission.classify_payload(conn, _payload(root))
    finally:
        conn.close()

    assert result["verdict"] == work_admission.VERDICT_PLANNER_REQUIRED
    assert result["next_authority"] == "planner"


def test_scoped_workflow_without_implementer_lease_requires_guardian(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    _git_init(root)
    conn = _conn()
    try:
        workflows.bind_workflow(
            conn,
            workflow_id="wf-admission",
            worktree_path=str(root),
            branch="feature/admission",
        )
        workflows.set_scope(
            conn,
            "wf-admission",
            allowed_paths=["src/**"],
            required_paths=[],
            forbidden_paths=[],
            authority_domains=[],
        )
        result = work_admission.classify_payload(conn, _payload(root))
    finally:
        conn.close()

    assert result["verdict"] == work_admission.VERDICT_GUARDIAN_PROVISION_REQUIRED
    assert result["next_authority"] == "guardian:provision"


def test_valid_implementer_custody_is_ready(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    _git_init(root)
    conn = _conn()
    try:
        workflows.bind_workflow(
            conn,
            workflow_id="wf-admission",
            worktree_path=str(root),
            branch="feature/admission",
        )
        workflows.set_scope(
            conn,
            "wf-admission",
            allowed_paths=["src/**"],
            required_paths=[],
            forbidden_paths=[],
            authority_domains=[],
        )
        leases.issue(
            conn,
            role="implementer",
            worktree_path=str(root),
            workflow_id="wf-admission",
            branch="feature/admission",
        )
        result = work_admission.classify_payload(conn, _payload(root))
    finally:
        conn.close()

    assert result["verdict"] == work_admission.VERDICT_READY_FOR_IMPLEMENTER
    assert result["next_authority"] == "implementer"


def test_apply_grants_scratchlane_with_guardian_admission_authority(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    conn = _conn()
    try:
        result = work_admission.apply_payload(
            conn,
            _payload(
                root,
                "tmp/dedup.py",
                workflow_id="wf-admission",
                session_id="session-1",
            ),
        )
        permit = scratchlanes.get_active(conn, str(root), "dedup")
    finally:
        conn.close()

    assert result["applied"] is True
    assert permit is not None
    assert permit["granted_by"] == "guardian_admission"
    assert permit["session_id"] == "session-1"
    assert permit["workflow_id"] == "wf-admission"


def test_apply_is_idempotent_for_existing_guardian_scratchlane(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    payload = _payload(root, "tmp/dedup.py", workflow_id="wf-admission")
    conn = _conn()
    try:
        first = work_admission.apply_payload(conn, payload)
        second = work_admission.apply_payload(conn, payload)
        permits = scratchlanes.list_active(conn, project_root=str(root))
    finally:
        conn.close()

    assert first["applied"] is True
    assert second["applied"] is True
    assert second["idempotent"] is True
    assert first["permit"]["id"] == second["permit"]["id"]
    assert len(permits) == 1

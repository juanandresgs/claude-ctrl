# @decision DEC-IMPLEMENTER-CRITIC-TESTS-001 — critic review tests pin runtime-owned retry and escalation semantics
# Why: The implementer critic loop is authoritative for inner-loop routing, so tests need to prove persistence, retry-limit escalation, repeated-fingerprint escalation, and outer-loop reset boundaries.
# Alternatives considered: Scenario-only coverage was rejected because retry/convergence logic lives in Python/runtime and needs deterministic unit tests without depending on Codex availability.
"""Unit tests for runtime.core.critic_reviews."""

from __future__ import annotations

import sqlite3

import pytest

from runtime.core import completions, critic_reviews, enforcement_config
from runtime.schemas import ensure_schema


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


def _submit_reviewer_completion(conn, lease_id: str, workflow_id: str, verdict: str = "needs_changes"):
    return completions.submit(
        conn,
        lease_id=lease_id,
        workflow_id=workflow_id,
        role="reviewer",
        payload={
            "REVIEW_VERDICT": verdict,
            "REVIEW_HEAD_SHA": "review-head",
            "REVIEW_FINDINGS_JSON": '{"findings":[]}',
        },
    )


def test_submit_round_trip_returns_resolution(conn):
    result = critic_reviews.submit(
        conn,
        workflow_id="wf-critic-001",
        lease_id="lease-critic-001",
        verdict="READY_FOR_REVIEWER",
        provider="codex",
        summary="Looks tactically complete.",
        detail="Tests and wiring line up for reviewer handoff.",
        fingerprint="fp-001",
        metadata={
            "hook": "test",
            "artifact_path": "/tmp/critic-artifact.md",
            "findings": ["No tactical blockers found."],
            "next_steps": ["Hand off to reviewer."],
            "execution_proof": {
                "provider": "test",
                "test_override": True,
                "parsed_structured_output_present": True,
            },
        },
    )
    assert result["workflow_id"] == "wf-critic-001"
    assert result["verdict"] == "READY_FOR_REVIEWER"
    assert result["metadata"]["hook"] == "test"
    assert result["resolution"]["found"] is True
    assert result["resolution"]["next_role"] == "reviewer"
    assert result["resolution"]["artifact_path"] == "/tmp/critic-artifact.md"
    assert result["resolution"]["findings"] == ["No tactical blockers found."]
    assert result["resolution"]["next_steps"] == ["Hand off to reviewer."]
    assert result["resolution"]["execution_proof_valid"] is True


def test_try_again_routes_back_to_implementer(conn):
    critic_reviews.submit(
        conn,
        workflow_id="wf-critic-002",
        lease_id="lease-critic-002",
        verdict="TRY_AGAIN",
        summary="Need another implementation pass.",
        detail="The main code path is still missing coverage.",
        fingerprint="fp-002",
    )
    resolution = critic_reviews.assess_latest(conn, workflow_id="wf-critic-002")
    assert resolution.found is True
    assert resolution.verdict == "TRY_AGAIN"
    assert resolution.next_role == "implementer"
    assert resolution.try_again_streak == 1
    assert resolution.escalated is False
    assert resolution.execution_proof_valid is False


def test_codex_execution_proof_valid(conn):
    critic_reviews.submit(
        conn,
        workflow_id="wf-critic-proof-codex",
        lease_id="lease-proof-codex",
        verdict="READY_FOR_REVIEWER",
        provider="codex",
        metadata={
            "execution_proof": {
                "provider": "codex",
                "app_server_thread_id": "thread-1",
                "turn_id": "turn-1",
                "turn_status": "completed",
                "parsed_structured_output_present": True,
                "final_message_non_empty": True,
            }
        },
    )
    resolution = critic_reviews.assess_latest(conn, workflow_id="wf-critic-proof-codex")
    assert resolution.execution_proof_valid is True


def test_gemini_execution_proof_valid(conn):
    critic_reviews.submit(
        conn,
        workflow_id="wf-critic-proof-gemini",
        lease_id="lease-proof-gemini",
        verdict="READY_FOR_REVIEWER",
        provider="gemini",
        metadata={
            "execution_proof": {
                "provider": "gemini",
                "exit_code": 0,
                "parsed_structured_output_present": True,
                "raw_response_non_empty": True,
            }
        },
    )
    resolution = critic_reviews.assess_latest(conn, workflow_id="wf-critic-proof-gemini")
    assert resolution.execution_proof_valid is True


def test_third_try_again_escalates_to_reviewer(conn):
    workflow_id = "wf-critic-003"
    critic_reviews.submit(
        conn,
        workflow_id=workflow_id,
        lease_id="lease-1",
        verdict="TRY_AGAIN",
        summary="Attempt one.",
        detail="Still missing the route.",
        fingerprint="fp-a",
    )
    critic_reviews.submit(
        conn,
        workflow_id=workflow_id,
        lease_id="lease-2",
        verdict="TRY_AGAIN",
        summary="Attempt two.",
        detail="Still missing the tests.",
        fingerprint="fp-b",
    )
    critic_reviews.submit(
        conn,
        workflow_id=workflow_id,
        lease_id="lease-3",
        verdict="TRY_AGAIN",
        summary="Attempt three.",
        detail="Still not converged.",
        fingerprint="fp-c",
    )
    resolution = critic_reviews.assess_latest(conn, workflow_id=workflow_id)
    assert resolution.verdict == "TRY_AGAIN"
    assert resolution.try_again_streak == 3
    assert resolution.retry_limit == 2
    assert resolution.next_role == "reviewer"
    assert resolution.escalated is True
    assert resolution.escalation_reason == critic_reviews.ESCALATION_RETRY_LIMIT


def test_repeated_fingerprint_escalates_before_retry_limit(conn):
    workflow_id = "wf-critic-004"
    enforcement_config.set_(
        conn,
        "critic_retry_limit",
        "5",
        actor_role="planner",
    )
    critic_reviews.submit(
        conn,
        workflow_id=workflow_id,
        lease_id="lease-a",
        verdict="TRY_AGAIN",
        summary="Attempt one.",
        detail="Same issue remains.",
        fingerprint="same-fp",
    )
    critic_reviews.submit(
        conn,
        workflow_id=workflow_id,
        lease_id="lease-b",
        verdict="TRY_AGAIN",
        summary="Attempt two.",
        detail="No source changes addressed the issue.",
        fingerprint="same-fp",
    )
    resolution = critic_reviews.assess_latest(conn, workflow_id=workflow_id)
    assert resolution.try_again_streak == 2
    assert resolution.repeated_fingerprint_streak == 2
    assert resolution.next_role == "reviewer"
    assert resolution.escalated is True
    assert resolution.escalation_reason == critic_reviews.ESCALATION_REPEATED_FINGERPRINT


def test_reviewer_completion_resets_try_again_window(conn):
    workflow_id = "wf-critic-005"
    r1 = critic_reviews.submit(
        conn,
        workflow_id=workflow_id,
        lease_id="lease-1",
        verdict="TRY_AGAIN",
        summary="Attempt one.",
        detail="Needs more work.",
        fingerprint="fp-1",
    )
    r2 = critic_reviews.submit(
        conn,
        workflow_id=workflow_id,
        lease_id="lease-2",
        verdict="TRY_AGAIN",
        summary="Attempt two.",
        detail="Still needs more work.",
        fingerprint="fp-2",
    )
    review = _submit_reviewer_completion(conn, "reviewer-lease", workflow_id)
    r3 = critic_reviews.submit(
        conn,
        workflow_id=workflow_id,
        lease_id="lease-3",
        verdict="TRY_AGAIN",
        summary="Fresh inner loop.",
        detail="A new reviewer round should reset retry counting.",
        fingerprint="fp-3",
    )

    conn.execute(
        "UPDATE critic_reviews SET created_at=? WHERE id=?",
        (100, r1["id"]),
    )
    conn.execute(
        "UPDATE critic_reviews SET created_at=? WHERE id=?",
        (110, r2["id"]),
    )
    conn.execute(
        "UPDATE completion_records SET created_at=? WHERE id=?",
        (200, review["completion_id"]),
    )
    conn.execute(
        "UPDATE critic_reviews SET created_at=? WHERE id=?",
        (300, r3["id"]),
    )

    resolution = critic_reviews.assess_latest(conn, workflow_id=workflow_id)
    assert resolution.try_again_streak == 1
    assert resolution.next_role == "implementer"
    assert resolution.escalated is False

"""A16 — mechanical invariant pins for orchestrator coordinate-only prompt/hook guardrails.

Pins four orchestrator-coordinate-only behaviors at the prompt/hook layer so
prompt-text drift cannot silently reintroduce orchestrator self-execution or
approval-boundary bounce.

Objectives:
1. Orchestrator routes seat-owned work; does not self-execute source edits.
2. Canonical dispatch uses `cc-policy dispatch agent-prompt` + exact
   `required_subagent_type`.
3. Routine commit/merge/straightforward push remains on the guardian-land path.
4. Orchestrator must NOT self-run `git push` or self-grant
   `cc-policy approval grant ... push`.
5. Canonical dispatch inside an approved bounded slice must not invent a
   second "user-only confirmation" boundary.

This file inspects the prompt and hook source files by content-substring
and by structural properties. It does NOT duplicate logic tested elsewhere
(A7 already tests supervisor/stop-loop prompt content; A15 tests runtime
authority boundaries). A16 is the consolidated contract-pin across BOTH
authorities (prompts AND write-side hooks) for the orchestrator's
coordinate-only posture.

@decision DEC-CLAUDEX-A16-PROMPT-HOOK-GUARDRAILS-001
Title: A16 prompt/hook guardrail invariants pin orchestrator coordinate-only
  posture at the content-substring authority level.
Status: accepted
Rationale: A7 already hardened prompt content and A15 pinned runtime
  authority-boundary semantics. A16 closes the remaining gap by pinning
  the prompt-text and hook-source substrings that encode the four
  orchestrator-coordinate-only behaviors. A future drift in supervisor
  prompt text (or a well-meaning edit that reintroduces self-grant push
  guidance) fails this invariant suite before reaching production.
"""

from __future__ import annotations

import pathlib
import re

import pytest


_REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def _read_repo_file(relpath: str) -> str:
    path = _REPO_ROOT / relpath
    assert path.is_file(), f"expected repo file {relpath} not found at {path}"
    return path.read_text()


# ---------------------------------------------------------------------------
# Objective 1: orchestrator routes seat-owned work; does not self-execute
# ---------------------------------------------------------------------------


class TestOrchestratorRoutesDoesNotSelfExecute:
    """Prompts and hooks encode the coordinate-only orchestrator posture."""

    def test_supervisor_prompt_names_guardian_as_sole_landing_actor(self):
        text = _read_repo_file(".codex/prompts/claudex_supervisor.txt")
        assert "Guardian remains the sole landing actor" in text or \
               "Guardian remains sole landing actor" in text, (
            "claudex_supervisor.txt does not name Guardian as sole landing actor "
            "— orchestrator coordinate-only posture not pinned in supervisor seat"
        )

    def test_handoff_prompt_names_guardian_as_sole_landing_actor(self):
        text = _read_repo_file(".codex/prompts/claudex_handoff.txt")
        assert "Guardian remains the sole landing actor" in text or \
               "Guardian remains sole landing actor" in text, (
            "claudex_handoff.txt does not name Guardian as sole landing actor"
        )

    def test_supervisor_prompt_has_no_orchestrator_self_edit_encouragement(self):
        """Supervisor prompt must not tell orchestrator to directly write source."""
        text = _read_repo_file(".codex/prompts/claudex_supervisor.txt")
        # Specifically forbid phrases like "you may edit source" / "directly modify"
        forbidden_phrases = [
            "directly write source",
            "directly edit source",
            "orchestrator may write source",
            "orchestrator should write source",
        ]
        for phrase in forbidden_phrases:
            assert phrase.lower() not in text.lower(), (
                f"claudex_supervisor.txt contains {phrase!r} — "
                f"orchestrator-self-execute encouragement forbidden"
            )

    def test_handoff_prompt_has_no_orchestrator_self_edit_encouragement(self):
        text = _read_repo_file(".codex/prompts/claudex_handoff.txt")
        forbidden_phrases = [
            "directly write source",
            "directly edit source",
            "orchestrator may write source",
            "orchestrator should write source",
        ]
        for phrase in forbidden_phrases:
            assert phrase.lower() not in text.lower(), (
                f"claudex_handoff.txt contains {phrase!r} — "
                f"orchestrator-self-execute encouragement forbidden"
            )


# ---------------------------------------------------------------------------
# Objective 2: canonical dispatch uses cc-policy dispatch agent-prompt
# ---------------------------------------------------------------------------


class TestCanonicalDispatchPathReferenced:
    """Prompts must name the canonical dispatch CLI as the authoritative entry."""

    def test_supervisor_prompt_references_cc_policy_dispatch(self):
        text = _read_repo_file(".codex/prompts/claudex_supervisor.txt")
        assert "cc-policy" in text, (
            "claudex_supervisor.txt does not mention cc-policy — "
            "canonical-dispatch authority not surfaced to supervisor seat"
        )

    def test_handoff_prompt_references_cc_policy(self):
        text = _read_repo_file(".codex/prompts/claudex_handoff.txt")
        assert "cc-policy" in text, (
            "claudex_handoff.txt does not mention cc-policy"
        )


# ---------------------------------------------------------------------------
# Objective 3: routine commit/merge/push is guardian-land path
# ---------------------------------------------------------------------------


class TestRoutineCommitMergePushOnGuardianPath:
    """Prompts must route routine git operations through guardian."""

    def test_supervisor_prompt_distinguishes_routine_from_user_decision(self):
        text = _read_repo_file(".codex/prompts/claudex_supervisor.txt")
        # Routine commit/push approval prompts must be classified as helper-path
        # drift, NOT as user-decision boundaries.
        assert "helper-path drift" in text.lower() or \
               "helper path drift" in text.lower(), (
            "claudex_supervisor.txt does not classify routine approval prompts "
            "as helper-path drift — false user-decision-boundary bounce risk"
        )
        # User-decision boundaries are destructive/history-rewrite/ambiguous/irreconcilable.
        for boundary in ("destructive", "history-rewrite", "ambiguous publish", "irreconcilable"):
            assert boundary.lower() in text.lower(), (
                f"claudex_supervisor.txt does not enumerate {boundary!r} as a "
                f"true user-decision boundary — orchestrator may over-bounce"
            )

    def test_handoff_prompt_distinguishes_routine_from_user_decision(self):
        text = _read_repo_file(".codex/prompts/claudex_handoff.txt")
        assert "helper-path drift" in text.lower() or \
               "helper path drift" in text.lower(), (
            "claudex_handoff.txt does not classify routine approval prompts "
            "as helper-path drift"
        )


# ---------------------------------------------------------------------------
# Objective 4: orchestrator MUST NOT self-run git push OR self-grant approval
# ---------------------------------------------------------------------------


class TestOrchestratorMustNotSelfPush:
    """Prompts explicitly forbid self-run git push + self-grant push approval."""

    def test_supervisor_prompt_forbids_self_grant_push_approval(self):
        text = _read_repo_file(".codex/prompts/claudex_supervisor.txt")
        # Must contain an explicit "do NOT self-grant ... push" or
        # "do NOT cc-policy approval grant ... push" directive.
        assert "self-grant" in text and "approval grant" in text and "push" in text, (
            "claudex_supervisor.txt does not explicitly forbid self-granting "
            "cc-policy approval grant ... push — supervisor seat may self-grant"
        )

    def test_supervisor_prompt_forbids_self_run_git_push(self):
        text = _read_repo_file(".codex/prompts/claudex_supervisor.txt")
        assert ("self-run" in text and "git push" in text), (
            "claudex_supervisor.txt does not explicitly forbid self-running "
            "git push — supervisor seat may bypass Guardian landing"
        )

    def test_handoff_prompt_forbids_self_grant_push_approval(self):
        text = _read_repo_file(".codex/prompts/claudex_handoff.txt")
        assert "self-grant" in text and "approval grant" in text and "push" in text, (
            "claudex_handoff.txt does not explicitly forbid self-granting "
            "cc-policy approval grant ... push"
        )

    def test_handoff_prompt_forbids_self_run_git_push(self):
        text = _read_repo_file(".codex/prompts/claudex_handoff.txt")
        assert ("self-run" in text and "git push" in text), (
            "claudex_handoff.txt does not explicitly forbid self-running git push"
        )


# ---------------------------------------------------------------------------
# Objective 5: canonical dispatch does not require extra user-only confirmation
# ---------------------------------------------------------------------------


class TestCanonicalDispatchNeedsNoSecondUserConfirmation:
    """Prompt surfaces must treat live supervisor/operator steering as sufficient."""

    def test_claude_md_rejects_second_user_only_confirmation(self):
        text = _read_repo_file("CLAUDE.md")
        assert "second user-only confirmation" in text, (
            "CLAUDE.md does not explicitly reject second user-only confirmation "
            "before canonical dispatch"
        )
        assert "supervisor steering instruction is sufficient authority" in text, (
            "CLAUDE.md does not state that supervisor steering is sufficient "
            "authority for canonical dispatch inside the active slice"
        )

    def test_supervisor_prompt_rejects_second_user_only_confirmation(self):
        text = _read_repo_file(".codex/prompts/claudex_supervisor.txt")
        assert "second user-only confirmation" in text, (
            "claudex_supervisor.txt does not explicitly reject second user-only "
            "confirmation before canonical dispatch"
        )
        assert "supervisor steering instruction is sufficient authority" in text, (
            "claudex_supervisor.txt does not treat supervisor steering as "
            "sufficient authority for canonical dispatch"
        )

    def test_handoff_prompt_rejects_second_user_only_confirmation(self):
        text = _read_repo_file(".codex/prompts/claudex_handoff.txt")
        assert "second user-only confirmation" in text, (
            "claudex_handoff.txt does not explicitly reject second user-only "
            "confirmation before canonical dispatch"
        )
        assert "supervisor steering instruction is sufficient authority" in text, (
            "claudex_handoff.txt does not treat supervisor steering as "
            "sufficient authority for canonical dispatch"
        )


# ---------------------------------------------------------------------------
# Hook-layer corroboration: write_who gates source writes at PreToolUse
# ---------------------------------------------------------------------------


class TestWriteHookLayerEnforcesCoordinateOnly:
    """Hook layer mechanically blocks orchestrator source writes via policy engine."""

    def test_pre_write_hook_routes_to_cc_policy_evaluate(self):
        """pre-write.sh must delegate to cc-policy evaluate (PE-W2 migration)."""
        text = _read_repo_file("hooks/pre-write.sh")
        assert "cc-policy" in text or "cc_policy" in text, (
            "hooks/pre-write.sh does not route to cc-policy — write-side policy "
            "engine bypassed; orchestrator self-execute gate may be missing"
        )

    def test_pre_bash_hook_routes_to_cc_policy_evaluate(self):
        """pre-bash.sh must delegate to cc-policy evaluate."""
        text = _read_repo_file("hooks/pre-bash.sh")
        assert "cc-policy" in text or "cc_policy" in text, (
            "hooks/pre-bash.sh does not route to cc-policy — bash-side policy "
            "engine bypassed; guardian-gate may be missing"
        )

    def test_write_who_policy_requires_can_write_source_capability(self):
        """write_who policy source references CAN_WRITE_SOURCE capability."""
        text = _read_repo_file("runtime/core/policies/write_who.py")
        assert "CAN_WRITE_SOURCE" in text, (
            "runtime/core/policies/write_who.py does not reference "
            "CAN_WRITE_SOURCE — write-authority gate semantics broken"
        )

    def test_plan_guard_has_scope_forbidden_gate_for_governance(self):
        """plan_guard emits scope_forbidden_path_write (A12 pin)."""
        text = _read_repo_file("runtime/core/policies/write_plan_guard.py")
        assert "scope_forbidden_path_write" in text, (
            "runtime/core/policies/write_plan_guard.py does not emit "
            "scope_forbidden_path_write — A12 role-absolute scope gate missing"
        )


# ---------------------------------------------------------------------------
# Smoke: all five objectives hold at soak HEAD
# ---------------------------------------------------------------------------


def test_a16_all_objectives_hold_at_soak_head():
    """Compound smoke: the five A16 objectives' key substrings are present."""
    supervisor = _read_repo_file(".codex/prompts/claudex_supervisor.txt")
    handoff = _read_repo_file(".codex/prompts/claudex_handoff.txt")
    pre_write = _read_repo_file("hooks/pre-write.sh")
    pre_bash = _read_repo_file("hooks/pre-bash.sh")

    # Objective 1: Guardian as sole landing actor.
    assert "Guardian remains" in supervisor
    assert "Guardian remains" in handoff

    # Objective 2: canonical dispatch CLI present.
    assert "cc-policy" in supervisor
    assert "cc-policy" in handoff

    # Objective 3: helper-path drift classification.
    assert "helper-path drift" in supervisor.lower() or "helper path drift" in supervisor.lower()

    # Objective 4: no-self-push, no-self-grant.
    assert "self-grant" in supervisor and "approval grant" in supervisor and "push" in supervisor
    assert "self-run" in supervisor and "git push" in supervisor
    assert "second user-only confirmation" in supervisor
    assert "supervisor steering instruction is sufficient authority" in supervisor

    # Hook-layer corroboration: both pre-write and pre-bash route to cc-policy.
    assert "cc-policy" in pre_write or "cc_policy" in pre_write
    assert "cc-policy" in pre_bash or "cc_policy" in pre_bash

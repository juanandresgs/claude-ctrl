"""Pin high-risk CLAUDE.md command snippets to live CLI shapes.

``cc-policy doc ref-check`` validates hook references, not operational command
syntax. These tests cover the snippets that directly steer orchestration.
"""

from __future__ import annotations

from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]


def _read(relative: str) -> str:
    return (_REPO_ROOT / relative).read_text(encoding="utf-8")


def test_claude_md_uses_current_readiness_and_scope_commands():
    text = _read("CLAUDE.md")

    assert "cc-policy evaluation get <workflow_id>" in text
    assert (
        "cc-policy workflow scope-sync <workflow_id> "
        "--work-item-id <work_item_id> --scope-file"
    ) in text
    assert "cc-policy workflow scope-set <workflow_id> --allowed" in text

    assert "cc-policy eval get --workflow-id" not in text
    assert "workflow scope-set --workflow-id" not in text


def test_claude_md_does_not_document_stale_guardian_merge_mode():
    text = _read("CLAUDE.md")

    assert "guardian (land)" in text
    assert "mode=merge" not in text
    assert "guardian (merge)" not in text
    assert "when approved) push" not in text


def test_dispatch_docs_use_current_completion_vocabulary():
    text = _read("docs/DISPATCH.md")

    assert "REVIEW_VERDICT" in text
    assert "EVAL_VERDICT" not in text
    assert "guardian(land)" in text
    assert "guardian(merge)" not in text


def test_claude_md_requires_autonomous_continuation_after_clean_landing():
    text = _read("CLAUDE.md")

    assert "### Autonomous Continuation" in text
    assert "dispatch planner continuation" in text
    assert "PLAN_VERDICT: next_work_item" in text
    assert "What's next is whatever you want" in text
    assert "not an acceptable terminal state" in text


def test_planner_prompt_treats_documented_followups_as_next_work_item():
    text = _read("agents/planner.md")

    assert "### Post-Landing Continuation" in text
    assert "PLAN_VERDICT: next_work_item" in text
    assert "unblocked follow-up" in text
    assert "needs_user_decision" in text
    assert "asking \"whatever you want\"" in text

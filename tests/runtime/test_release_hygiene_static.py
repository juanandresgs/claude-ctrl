from __future__ import annotations

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def _read(path: str) -> str:
    return (REPO_ROOT / path).read_text()


def test_installer_defaults_to_main_instead_of_checkout_branch() -> None:
    text = _read("install-claude-ctrl.sh")

    assert 'BRANCH="${BRANCH:-main}"' in text
    assert "detect_branch()" not in text
    assert "branch --show-current" not in text


def test_installer_requires_pin_for_floating_non_main_installs() -> None:
    text = _read("install-claude-ctrl.sh")

    assert "Refusing to install floating non-main branch" in text
    assert "EXPECTED_HEAD=<sha>" in text
    assert "ALLOW_FLOATING_NON_MAIN=1" in text


def test_claude_md_uses_current_evaluation_get_shape() -> None:
    text = _read("CLAUDE.md")

    assert "cc-policy eval get" not in text
    assert "cc-policy evaluation get <workflow_id>" in text


def test_claude_md_teaches_stage_packet_as_primary_dispatch_surface() -> None:
    text = _read("CLAUDE.md")

    primary = "cc-policy workflow stage-packet [<workflow_id>] --stage-id"
    low_level = "cc-policy dispatch agent-prompt --workflow-id"
    assert primary in text
    assert "Prefer the high-level stage packet producer" in text
    assert "Low-level prompt contract primitive" in text
    assert text.index(primary) < text.index(low_level)

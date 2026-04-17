"""Regression pin for the Claude worker launcher's default model.

The ClauDEX bridge's overnight-start path invokes
``scripts/claudex-claude-launch.sh`` with no explicit
``CLAUDEX_CLAUDE_MODEL`` override in the checked-in launch chain
(``claudex-overnight-start.sh`` / ``claudex-bridge-up.sh`` /
``claudex-common.sh``).  The launcher's own default therefore
determines the effective model for the active lane.  A drift from the
intended 1M-context Opus model to a non-1M variant therefore has
exactly one authoritative source: the ``MODEL="${CLAUDEX_CLAUDE_MODEL:-...}"``
default in the launcher script itself.

This test pins that default so any future edit that silently
downgrades it (e.g. to ``claude-opus-4-6`` or a non-``[1m]`` variant)
fails CI before it can reach a live lane.

@decision DEC-CLAUDEX-LAUNCH-MODEL-001
@title Claude worker launcher defaults to the 1M-context Opus model
@status accepted
@rationale The bridge's overnight loop runs long-horizon work whose
  context window regularly exceeds the standard Opus limit.  The
  effective default must be the 1M-context variant so a lane that
  omits the optional ``CLAUDEX_CLAUDE_MODEL`` override still gets the
  correct model.  Pinning the default here guards against silent
  drift.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest


_REPO_ROOT = Path(__file__).resolve().parents[2]
_LAUNCH_SCRIPT = _REPO_ROOT / "scripts" / "claudex-claude-launch.sh"


@pytest.fixture(scope="module")
def launch_src() -> str:
    assert _LAUNCH_SCRIPT.is_file(), (
        f"launcher script missing at expected path: {_LAUNCH_SCRIPT}"
    )
    return _LAUNCH_SCRIPT.read_text(encoding="utf-8")


def test_default_model_is_1m_context_opus(launch_src):
    """The launcher's default must be the 1M-context Opus identifier.

    We match the exact literal the shell script uses so a future
    downgrade cannot sneak past a permissive regex.
    """
    expected_line = 'MODEL="${CLAUDEX_CLAUDE_MODEL:-claude-opus-4-7[1m]}"'
    assert expected_line in launch_src, (
        "claudex-claude-launch.sh must default MODEL to the 1M-context "
        "Opus identifier 'claude-opus-4-7[1m]'; found:\n"
        f"{launch_src}"
    )


def test_default_model_is_not_a_non_1m_variant(launch_src):
    """No non-1M Opus default is allowed."""
    for forbidden in (
        'MODEL="${CLAUDEX_CLAUDE_MODEL:-claude-opus-4-6}"',
        'MODEL="${CLAUDEX_CLAUDE_MODEL:-claude-opus-4-7}"',      # missing [1m]
        'MODEL="${CLAUDEX_CLAUDE_MODEL:-opus}"',
        'MODEL="${CLAUDEX_CLAUDE_MODEL:-claude-sonnet-4-6}"',
        'MODEL="${CLAUDEX_CLAUDE_MODEL:-claude-haiku-4-5-20251001}"',
    ):
        assert forbidden not in launch_src, (
            f"claudex-claude-launch.sh must not carry a non-1M default: "
            f"found forbidden line {forbidden!r}"
        )


def test_launcher_still_passes_model_flag(launch_src):
    """The --model flag must still be passed; a silent removal would
    let whatever the local `claude` CLI defaults to take over."""
    assert '--model "$MODEL"' in launch_src, (
        "claudex-claude-launch.sh must forward the resolved MODEL to "
        "the Claude CLI via --model; without that, the local default "
        "wins and the launcher default becomes non-authoritative."
    )


def test_launcher_leaves_env_override_path_open(launch_src):
    """The default must still come from the CLAUDEX_CLAUDE_MODEL env var
    when set — operators need an override surface for lane-specific
    experiments without editing the script."""
    assert '${CLAUDEX_CLAUDE_MODEL:-' in launch_src, (
        "claudex-claude-launch.sh must keep CLAUDEX_CLAUDE_MODEL as "
        "the override env var so operators can set it per-lane."
    )


def test_executable_bit_preserved():
    """The launcher is invoked as an executable by overnight-start /
    bridge-up; the executable bit must not be lost by a routine edit."""
    mode = os.stat(_LAUNCH_SCRIPT).st_mode
    assert mode & 0o111, (
        f"claudex-claude-launch.sh must remain executable "
        f"(current mode: {oct(mode)})"
    )

"""Lane topology authority for the ClauDEX bridge/supervision lane.

@decision DEC-CLAUDEX-LANE-TOPOLOGY-001
Title: runtime/core/lane_topology.py is the sole interpreter for live lane pane topology
Status: proposed
Rationale: the soak lane previously reconstructed Codex/Claude pane targets in
  multiple shell scripts from different raw surfaces (`run.json.tmux_target`,
  progress snapshots, and legacy `.1` / `.2` pane assumptions). That let
  helper surfaces disagree about which pane was live, and in the worst case it
  let the control plane queue real work while the worker pane no longer
  existed.

  This module collapses the interpretation step into one runtime-owned,
  read-only probe. It does not replace the raw transport facts emitted by the
  bridge (`run.json`) or the monitor (`progress-monitor.latest.json`); instead
  it is the *only* place allowed to reconcile those facts with live tmux truth.
  Shell wrappers must consume this probe rather than guessing pane topology on
  their own.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict, Optional


def _issue(code: str, *, severity: str = "error", **extra: Any) -> Dict[str, Any]:
    payload: Dict[str, Any] = {"code": code, "severity": severity}
    payload.update(extra)
    return payload


def _resolve_braid_root(braid_root: str | os.PathLike[str] | None) -> Path:
    if braid_root:
        return Path(braid_root).expanduser().resolve()
    env = os.environ.get("BRAID_ROOT")
    if env:
        return Path(env).expanduser().resolve()
    return (Path.cwd() / ".b2r").resolve()


def _resolve_state_dir(state_dir: str | os.PathLike[str] | None) -> Path:
    if state_dir:
        return Path(state_dir).expanduser().resolve()
    env = os.environ.get("CLAUDEX_STATE_DIR")
    if env:
        return Path(env).expanduser().resolve()
    return (Path.cwd() / ".claude" / "claudex").resolve()


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _read_json(path: Path) -> Dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def _run_tmux(*args: str) -> Optional[str]:
    try:
        result = subprocess.run(
            ["tmux", *args],
            capture_output=True,
            text=True,
            check=False,
        )
    except (FileNotFoundError, OSError):
        return None
    if result.returncode != 0:
        return None
    output = result.stdout.strip()
    return output or None


def _normalize_pane_id(raw: Optional[str]) -> Optional[str]:
    if not raw:
        return None
    return raw if raw.startswith("%") else None


def _normalize_target(raw: Optional[str]) -> Optional[str]:
    if not raw or ":" not in raw or "." not in raw:
        return None
    session, remainder = raw.split(":", 1)
    window, pane = remainder.rsplit(".", 1)
    if not session or not window or not pane:
        return None
    return raw


def _pane_id_for_target(target: str) -> Optional[str]:
    if not target:
        return None
    return _normalize_pane_id(
        _run_tmux("display-message", "-p", "-t", target, "#{pane_id}")
    )


def _target_for_pane_id(pane_id: str) -> Optional[str]:
    if not pane_id:
        return None
    return _normalize_target(
        _run_tmux(
            "display-message",
            "-p",
            "-t",
            pane_id,
            "#{session_name}:#{window_index}.#{pane_index}",
        )
    )


def _parse_session_name(target: Optional[str]) -> Optional[str]:
    if not target or ":" not in target:
        return None
    return target.split(":", 1)[0] or None


def _parse_window_target(target: Optional[str]) -> Optional[str]:
    if not target or ":" not in target or "." not in target:
        return None
    session, remainder = target.split(":", 1)
    window = remainder.rsplit(".", 1)[0]
    if not session or not window:
        return None
    return f"{session}:{window}"


def _resolve_endpoint(
    *,
    role: str,
    recorded_target: Optional[str],
    target_source: Optional[str],
    recorded_pane_id: Optional[str],
    pane_id_source: Optional[str],
) -> Dict[str, Any]:
    issues: list[Dict[str, Any]] = []

    target = recorded_target or None
    target_probe_pane_id = _pane_id_for_target(target) if target else None
    target_exists = target_probe_pane_id is not None

    pane_id = recorded_pane_id or None
    pane_probe_target = _target_for_pane_id(pane_id) if pane_id else None
    pane_id_exists = pane_probe_target is not None if pane_id else None

    resolved_target = target
    if not target and pane_probe_target:
        resolved_target = pane_probe_target
        target_exists = True
    elif target and not target_exists and pane_probe_target:
        resolved_target = pane_probe_target
        target_exists = True
        issues.append(
            _issue(
                f"{role}_target_drift",
                recorded_target=target,
                observed_target=pane_probe_target,
            )
        )

    resolved_pane_id = target_probe_pane_id or pane_id
    authoritative = bool(target_source or (pane_id_source and pane_probe_target))
    if target_source == "legacy_derived_from_claude_target":
        authoritative = False
        issues.append(
            _issue(
                "codex_target_legacy_fallback",
                severity="warning",
                target=recorded_target,
            )
        )

    if target and not target_exists:
        issues.append(
            _issue(
                f"{role}_target_unavailable",
                target=target,
            )
        )
    if pane_id and pane_id_exists is False:
        issues.append(
            _issue(
                f"{role}_pane_id_unavailable",
                severity="warning",
                pane_id=pane_id,
            )
        )
    if target and pane_id and target_exists and pane_probe_target and pane_probe_target != target:
        issues.append(
            _issue(
                f"{role}_pane_id_target_mismatch",
                recorded_target=target,
                observed_target=pane_probe_target,
                recorded_pane_id=pane_id,
                observed_pane_id=target_probe_pane_id,
            )
        )
    if target and pane_id and target_probe_pane_id and target_probe_pane_id != pane_id:
        issues.append(
            _issue(
                f"{role}_pane_id_drift",
                severity="warning",
                recorded_pane_id=pane_id,
                observed_pane_id=target_probe_pane_id,
            )
        )
    if not resolved_target:
        issues.append(_issue(f"{role}_target_missing", severity="warning"))

    return {
        "target": resolved_target,
        "recorded_target": target,
        "target_source": target_source,
        "target_exists": target_exists,
        "pane_id": resolved_pane_id,
        "recorded_pane_id": pane_id,
        "pane_id_source": pane_id_source,
        "pane_id_exists": pane_id_exists,
        "authoritative": authoritative,
        "issues": issues,
    }


def probe_lane_topology(
    *,
    braid_root: str | os.PathLike[str] | None = None,
    state_dir: str | os.PathLike[str] | None = None,
    codex_target: str | None = None,
    claude_target: str | None = None,
) -> Dict[str, Any]:
    """Return a read-only snapshot of the live ClauDEX lane topology."""

    braid = _resolve_braid_root(braid_root)
    state = _resolve_state_dir(state_dir)

    runs_dir = braid / "runs"
    active_run_path = runs_dir / "active-run"
    active_run_id = _read_text(active_run_path) or None
    run_json_path = runs_dir / active_run_id / "run.json" if active_run_id else None
    status_json_path = runs_dir / active_run_id / "status.json" if active_run_id else None
    progress_snapshot_path = state / "progress-monitor.latest.json"
    progress_alert_path = state / "progress-monitor.alert.json"

    run_json = _read_json(run_json_path) if run_json_path else {}
    status_json = _read_json(status_json_path) if status_json_path else {}
    progress_snapshot = _read_json(progress_snapshot_path)
    progress_alert = _read_json(progress_alert_path)

    issues: list[Dict[str, Any]] = []
    if active_run_id and not run_json:
        issues.append(_issue("run_json_missing", run_id=active_run_id))
    if active_run_id and not status_json:
        issues.append(_issue("status_json_missing", run_id=active_run_id, severity="warning"))

    active_run_matches_snapshot = bool(
        active_run_id
        and progress_snapshot
        and progress_snapshot.get("active_run_id") == active_run_id
    )
    active_run_matches_alert = bool(
        active_run_id
        and progress_alert
        and progress_alert.get("active_run_id") == active_run_id
    )

    resolved_claude_target = claude_target or run_json.get("tmux_target") or None
    claude_target_source = (
        "explicit"
        if claude_target
        else ("run_json.tmux_target" if run_json.get("tmux_target") else None)
    )
    claude_pane_id = run_json.get("claude_pane_id") or None
    claude_pane_id_source = (
        "run_json.claude_pane_id" if run_json.get("claude_pane_id") else None
    )

    resolved_codex_target = None
    codex_target_source = None
    if codex_target:
        resolved_codex_target = codex_target
        codex_target_source = "explicit"
    elif run_json.get("codex_target"):
        resolved_codex_target = run_json.get("codex_target")
        codex_target_source = "run_json.codex_target"
    elif active_run_matches_alert and progress_alert.get("codex_target"):
        resolved_codex_target = progress_alert.get("codex_target")
        codex_target_source = "progress_alert.codex_target"
    elif active_run_matches_snapshot and progress_snapshot.get("codex_target"):
        resolved_codex_target = progress_snapshot.get("codex_target")
        codex_target_source = "progress_snapshot.codex_target"
    elif resolved_claude_target and ":" in resolved_claude_target and "." in resolved_claude_target:
        session, remainder = resolved_claude_target.split(":", 1)
        window, _pane = remainder.rsplit(".", 1)
        resolved_codex_target = f"{session}:{window}.1"
        codex_target_source = "legacy_derived_from_claude_target"

    codex_pane_id = run_json.get("codex_pane_id") or None
    codex_pane_id_source = (
        "run_json.codex_pane_id" if run_json.get("codex_pane_id") else None
    )

    claude = _resolve_endpoint(
        role="claude",
        recorded_target=resolved_claude_target,
        target_source=claude_target_source,
        recorded_pane_id=claude_pane_id,
        pane_id_source=claude_pane_id_source,
    )
    codex = _resolve_endpoint(
        role="codex",
        recorded_target=resolved_codex_target,
        target_source=codex_target_source,
        recorded_pane_id=codex_pane_id,
        pane_id_source=codex_pane_id_source,
    )

    issues.extend(claude["issues"])
    issues.extend(codex["issues"])

    session_name = _parse_session_name(codex["target"]) or _parse_session_name(claude["target"])
    pair_window_target = _parse_window_target(codex["target"]) or _parse_window_target(claude["target"])

    return {
        "status": "ok",
        "braid_root": str(braid),
        "state_dir": str(state),
        "active_run_id": active_run_id,
        "run_json_path": str(run_json_path) if run_json_path else None,
        "status_json_path": str(status_json_path) if status_json_path else None,
        "bridge_state": status_json.get("state") or None,
        "bridge_updated_at": status_json.get("updated_at") or None,
        "session_name": session_name,
        "pair_window_target": pair_window_target,
        "claude": {k: v for k, v in claude.items() if k != "issues"},
        "codex": {k: v for k, v in codex.items() if k != "issues"},
        "issues": issues,
    }

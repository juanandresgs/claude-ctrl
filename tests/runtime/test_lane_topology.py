from __future__ import annotations

import json
from pathlib import Path

from runtime.core import lane_topology as lt


class _Completed:
    def __init__(self, *, returncode: int, stdout: str = "") -> None:
        self.returncode = returncode
        self.stdout = stdout


def _seed_run(
    root: Path,
    *,
    run_id: str,
    tmux_target: str,
    claude_pane_id: str | None = None,
    codex_target: str | None = None,
    codex_pane_id: str | None = None,
) -> tuple[Path, Path]:
    braid = root / "braid"
    state = root / "state"
    run_dir = braid / "runs" / run_id
    run_dir.mkdir(parents=True)
    state.mkdir(parents=True)
    (braid / "runs" / "active-run").write_text(f"{run_id}\n", encoding="utf-8")

    run_payload = {
        "run_id": run_id,
        "project_root": str(root),
        "project_slug": "fake",
        "tmux_target": tmux_target,
        "created_at": "2026-04-18T00:00:00Z",
        "completed_at": None,
    }
    if claude_pane_id:
        run_payload["claude_pane_id"] = claude_pane_id
    if codex_target:
        run_payload["codex_target"] = codex_target
    if codex_pane_id:
        run_payload["codex_pane_id"] = codex_pane_id

    (run_dir / "run.json").write_text(json.dumps(run_payload), encoding="utf-8")
    (run_dir / "status.json").write_text(
        json.dumps({"state": "queued", "updated_at": "2026-04-18T00:00:01Z"}),
        encoding="utf-8",
    )
    return braid, state


def _fake_tmux(monkeypatch, *, target_to_pane: dict[str, str], pane_to_target: dict[str, str]) -> None:
    def _run(args, capture_output, text, check):  # noqa: ANN001
        assert args[0] == "tmux"
        assert args[1] == "display-message"
        target = args[4]
        fmt = args[5]
        if fmt == "#{pane_id}" and target in target_to_pane:
            return _Completed(returncode=0, stdout=f"{target_to_pane[target]}\n")
        if fmt == "#{session_name}:#{window_index}.#{pane_index}" and target in pane_to_target:
            return _Completed(returncode=0, stdout=f"{pane_to_target[target]}\n")
        return _Completed(returncode=1, stdout="")

    monkeypatch.setattr(lt.subprocess, "run", _run)


def test_probe_prefers_run_json_codex_target_and_confirms_live_panes(tmp_path: Path, monkeypatch) -> None:
    braid, state = _seed_run(
        tmp_path,
        run_id="run-topology-primary",
        tmux_target="soak:1.2",
        claude_pane_id="%12",
        codex_target="soak:1.1",
        codex_pane_id="%11",
    )
    _fake_tmux(
        monkeypatch,
        target_to_pane={"soak:1.2": "%12", "soak:1.1": "%11"},
        pane_to_target={"%12": "soak:1.2", "%11": "soak:1.1"},
    )

    payload = lt.probe_lane_topology(braid_root=braid, state_dir=state)

    assert payload["active_run_id"] == "run-topology-primary"
    assert payload["claude"]["target"] == "soak:1.2"
    assert payload["claude"]["target_exists"] is True
    assert payload["codex"]["target"] == "soak:1.1"
    assert payload["codex"]["target_source"] == "run_json.codex_target"
    assert payload["codex"]["authoritative"] is True
    assert payload["codex"]["target_exists"] is True
    assert payload["issues"] == []


def test_probe_uses_progress_snapshot_codex_target_before_legacy_guess(tmp_path: Path, monkeypatch) -> None:
    braid, state = _seed_run(
        tmp_path,
        run_id="run-topology-snapshot",
        tmux_target="soak:1.2",
        claude_pane_id="%12",
    )
    (state / "progress-monitor.latest.json").write_text(
        json.dumps(
            {
                "active_run_id": "run-topology-snapshot",
                "codex_target": "soak:2.3",
            }
        ),
        encoding="utf-8",
    )
    _fake_tmux(
        monkeypatch,
        target_to_pane={"soak:1.2": "%12", "soak:2.3": "%23"},
        pane_to_target={"%12": "soak:1.2", "%23": "soak:2.3"},
    )

    payload = lt.probe_lane_topology(braid_root=braid, state_dir=state)

    assert payload["codex"]["target"] == "soak:2.3"
    assert payload["codex"]["target_source"] == "progress_snapshot.codex_target"
    assert payload["codex"]["authoritative"] is True
    assert not any(issue["code"] == "codex_target_legacy_fallback" for issue in payload["issues"])


def test_probe_marks_legacy_codex_fallback_non_authoritative(tmp_path: Path, monkeypatch) -> None:
    braid, state = _seed_run(
        tmp_path,
        run_id="run-topology-legacy",
        tmux_target="soak:1.2",
        claude_pane_id="%12",
    )
    _fake_tmux(
        monkeypatch,
        target_to_pane={"soak:1.2": "%12", "soak:1.1": "%11"},
        pane_to_target={"%12": "soak:1.2", "%11": "soak:1.1"},
    )

    payload = lt.probe_lane_topology(braid_root=braid, state_dir=state)

    assert payload["codex"]["target"] == "soak:1.1"
    assert payload["codex"]["target_source"] == "legacy_derived_from_claude_target"
    assert payload["codex"]["authoritative"] is False
    assert any(issue["code"] == "codex_target_legacy_fallback" for issue in payload["issues"])

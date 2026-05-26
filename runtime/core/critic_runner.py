"""v6 critic provider runner.

This module makes critic execution a visible runtime stage artifact instead of a
hidden Stop hook. It tries configured external providers first (Codex, Gemini),
then falls back to an adversarial critic-subagent launch instruction. The
fallback is explicit and persisted: it does not fake critique results.
"""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import time
from typing import Optional

from runtime.core import stage_machine, stage_runs

DEFAULT_PROVIDERS = ["codex", "gemini", "critic-subagent"]
DEFAULT_TIMEOUT = 60


def _now() -> int:
    return int(time.time())


def _json_dumps(value: object) -> str:
    return json.dumps(value if value is not None else {}, sort_keys=True)


def _json_loads(raw: str | None, default):
    if not raw:
        return default
    try:
        return json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return default


def _row_to_dict(row: sqlite3.Row | None) -> Optional[dict]:
    if row is None:
        return None
    d = dict(row)
    d["execution_proof"] = _json_loads(d.get("execution_proof_json"), {})
    return d


def providers_from_env() -> list[str]:
    raw = os.environ.get("CLAUDE_CTRL_CRITIC_PROVIDERS", "")
    if not raw.strip():
        return list(DEFAULT_PROVIDERS)
    out: list[str] = []
    for part in raw.replace(";", ",").split(","):
        provider = part.strip()
        if provider:
            out.append(provider)
    return out or list(DEFAULT_PROVIDERS)


def build_prompt(stage_run: dict, subject: str = "") -> str:
    return "\n".join(
        [
            "You are the v6 adversarial critic.",
            "Find concrete correctness, security, scope, test, and architecture defects.",
            "Do not modify files. Return only a claude_ctrl_result JSON block.",
            f"stage_run_id: {stage_run['id']}",
            f"workflow_id: {stage_run['workflow_id']}",
            f"work_item_id: {stage_run.get('work_item_id', '')}",
            f"worktree_path: {stage_run.get('worktree_path') or '(project root)'}",
            "Allowed verdicts: ready_for_reviewer, try_again, blocked_by_plan, unavailable",
            "Required JSON keys: stage_run_id, stage_id='critic', verdict, summary, findings, execution_proof.",
            subject.strip(),
        ]
    ).strip()


def latest_for_stage(conn: sqlite3.Connection, stage_run_id: str) -> Optional[dict]:
    row = conn.execute(
        "SELECT * FROM critic_runs WHERE stage_run_id = ? ORDER BY started_at DESC, id DESC LIMIT 1",
        (stage_run_id,),
    ).fetchone()
    return _row_to_dict(row)


def run_critic(
    conn: sqlite3.Connection,
    *,
    stage_run_id: str,
    providers: Optional[list[str]] = None,
    timeout: int = DEFAULT_TIMEOUT,
    subject: str = "",
    dry_run: bool = False,
) -> dict:
    run = stage_runs.get_stage_run(conn, stage_run_id)
    if not run:
        raise ValueError(f"stage_run_id not found: {stage_run_id}")
    if run["stage_id"] != stage_machine.CRITIC:
        raise ValueError(f"critic runner requires stage_id='critic', got {run['stage_id']!r}")

    provider_list = providers if providers is not None else providers_from_env()
    if not provider_list:
        provider_list = list(DEFAULT_PROVIDERS)
    prompt = build_prompt(run, subject=subject)
    attempts: list[dict] = []

    for provider in provider_list:
        provider = provider.strip()
        if not provider:
            continue
        if provider == "critic-subagent":
            rec = _record_subagent_fallback(conn, run, prompt, timeout)
            return {"status": "fallback_required", "selected_provider": provider, "critic_run": rec, "attempts": attempts}

        started = _now()
        row_id = _insert_run(conn, run, provider, "running", prompt, started, timeout)
        if dry_run:
            output = _dry_run_output(run, provider)
            completed = _now()
            payload = stage_runs.extract_result_block(output) or {}
            verdict = str(payload.get("verdict") or "unavailable")
            proof = payload.get("execution_proof") or {"provider": provider, "valid": True, "dry_run": True}
            rec = _complete_run(conn, row_id, "completed", verdict, output, payload.get("summary", "dry-run critic"), proof, "", completed)
            return {"status": "completed", "selected_provider": provider, "critic_run": rec, "attempts": attempts}

        exe = shutil.which(provider)
        if not exe:
            completed = _now()
            rec = _complete_run(
                conn,
                row_id,
                "failed",
                "unavailable",
                "",
                "provider executable not found",
                {"provider": provider, "valid": False, "error": "not_found"},
                f"provider executable not found: {provider}",
                completed,
            )
            attempts.append(rec)
            continue

        try:
            argv, stdin_text = _provider_invocation(provider, exe, prompt, run.get("worktree_path") or "")
            proc = subprocess.run(
                argv,
                input=stdin_text,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=run.get("worktree_path") or None,
            )
            raw = (proc.stdout or "") + (("\n" + proc.stderr) if proc.stderr else "")
            payload = stage_runs.extract_result_block(raw) or {}
            verdict = str(payload.get("verdict") or "unavailable")
            proof = payload.get("execution_proof") or {
                "provider": provider,
                "valid": proc.returncode == 0,
                "returncode": proc.returncode,
            }
            status = "completed" if proc.returncode == 0 and proof.get("valid") is True and payload else "failed"
            rec = _complete_run(
                conn,
                row_id,
                status,
                verdict,
                raw,
                str(payload.get("summary") or ""),
                proof,
                "" if status == "completed" else f"provider returned invalid critic result rc={proc.returncode}",
                _now(),
            )
            if status == "completed":
                return {"status": "completed", "selected_provider": provider, "critic_run": rec, "attempts": attempts}
            attempts.append(rec)
        except subprocess.TimeoutExpired as exc:
            rec = _complete_run(
                conn,
                row_id,
                "timeout",
                "unavailable",
                (exc.stdout or "") + (exc.stderr or ""),
                "critic provider timed out",
                {"provider": provider, "valid": False, "timeout": timeout},
                f"timeout after {timeout}s",
                _now(),
            )
            attempts.append(rec)

    rec = _record_subagent_fallback(conn, run, prompt, timeout)
    return {"status": "fallback_required", "selected_provider": "critic-subagent", "critic_run": rec, "attempts": attempts}


def _provider_invocation(provider: str, exe: str, prompt: str, worktree_path: str) -> tuple[list[str], str]:
    """Return argv/stdin for a read-only non-interactive critic provider.

    Verified against local CLI help:
    - codex: `codex exec --cd <dir> --sandbox read-only -` reads prompt from stdin.
    - gemini: `gemini --prompt <prompt> --approval-mode plan --output-format text`
      runs headless and read-only-ish via plan approval mode.
    """

    if provider == "codex":
        argv = [exe, "exec", "--sandbox", "read-only", "--ephemeral"]
        if worktree_path:
            argv.extend(["--cd", worktree_path])
        argv.append("-")
        return argv, prompt
    if provider == "gemini":
        argv = [exe, "--approval-mode", "plan", "--output-format", "text", "--prompt", prompt]
        return argv, ""
    return [exe], prompt


def _dry_run_output(run: dict, provider: str) -> str:
    payload = {
        "stage_run_id": run["id"],
        "stage_id": "critic",
        "verdict": "ready_for_reviewer",
        "summary": f"dry-run {provider} critic found no blockers",
        "findings": [],
        "execution_proof": {"provider": provider, "valid": True, "dry_run": True},
    }
    return "```claude_ctrl_result\n" + json.dumps(payload, sort_keys=True) + "\n```"


def _insert_run(conn: sqlite3.Connection, run: dict, provider: str, status: str, prompt: str, started: int, timeout: int) -> int:
    with conn:
        cur = conn.execute(
            """
            INSERT INTO critic_runs (
                stage_run_id, workflow_id, provider, status, prompt_text,
                execution_proof_json, started_at, timeout_seconds
            ) VALUES (?, ?, ?, ?, ?, '{}', ?, ?)
            """,
            (run["id"], run["workflow_id"], provider, status, prompt, started, timeout),
        )
    return int(cur.lastrowid)


def _complete_run(
    conn: sqlite3.Connection,
    row_id: int,
    status: str,
    verdict: str,
    raw_output: str,
    summary: str,
    proof: dict,
    error: str,
    completed: int,
) -> dict:
    with conn:
        conn.execute(
            """
            UPDATE critic_runs
            SET status = ?, verdict = ?, raw_output = ?, summary = ?,
                execution_proof_json = ?, error = ?, completed_at = ?
            WHERE id = ?
            """,
            (status, verdict, raw_output, summary, _json_dumps(proof), error, completed, row_id),
        )
    row = conn.execute("SELECT * FROM critic_runs WHERE id = ?", (row_id,)).fetchone()
    return _row_to_dict(row) or {"id": row_id}


def _record_subagent_fallback(conn: sqlite3.Connection, run: dict, prompt: str, timeout: int) -> dict:
    started = _now()
    row_id = _insert_run(conn, run, "critic-subagent", "fallback_required", prompt, started, timeout)
    proof = {"provider": "critic-subagent", "valid": False, "fallback_required": True}
    return _complete_run(
        conn,
        row_id,
        "fallback_required",
        "unavailable",
        "",
        "External critics unavailable; dispatch critic subagent with persisted adversarial prompt.",
        proof,
        "fallback_required",
        _now(),
    )

"""Runtime-owned Bash hook lifecycle bookkeeping.

The PreToolUse Bash hook captures a source fingerprint baseline after policy
allow. The PostToolUse Bash hook compares that baseline after execution and
updates evaluation readiness through the runtime. Shell adapters call this
module; they do not decide worktree target, lease context, or landing phase.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
import re
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Any, Mapping

from runtime.core import evaluation as evaluation_mod
from runtime.core import events as events_mod
from runtime.core import leases as leases_mod
from runtime.core.hook_envelope import HookEventEnvelope, build_hook_event_envelope
from runtime.core.landing_authority import FEATURE_COMMIT_LANDED
from runtime.core.policy_utils import current_workflow_id, normalize_path, sanitize_token

SOURCE_EXTENSIONS_RE = re.compile(
    r"\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|astro|vue|svelte|css|scss|sass|less|html|htm|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)$"
)
SKIPPABLE_PATH_RE = re.compile(
    r"(\.generated\.|\.min\.|(^|/)(node_modules|vendor|dist|build|\.next|__pycache__|\.git)(/|$))"
)


@dataclass(frozen=True)
class BashLifecycleResult:
    """Diagnostic result returned by hook lifecycle handlers."""

    project_root: str
    workflow_id: str
    baseline_key: str
    baseline_file: str  # Backward-compatible JSON key; value is a state.db ref.
    source_mutation: bool = False
    promoted_commit_head: bool = False
    invalidated: bool = False
    new_head: str = ""
    landing_phase: str = ""

    def as_dict(self) -> dict[str, Any]:
        return {
            "project_root": self.project_root,
            "workflow_id": self.workflow_id,
            "baseline_key": self.baseline_key,
            "baseline_file": self.baseline_file,
            "baseline_ref": self.baseline_file,
            "source_mutation": self.source_mutation,
            "promoted_commit_head": self.promoted_commit_head,
            "invalidated": self.invalidated,
            "new_head": self.new_head,
            "landing_phase": self.landing_phase,
        }


def _is_source_file(path: str) -> bool:
    return bool(SOURCE_EXTENSIONS_RE.search(path))


def _is_skippable_path(path: str) -> bool:
    return bool(SKIPPABLE_PATH_RE.search(path))


def _is_scratchlane_path(path: str) -> bool:
    normalized = path.replace("\\", "/").lstrip("/")
    parts = normalized.split("/")
    return normalized.startswith("tmp/.claude-scratch/") or (
        len(parts) >= 3 and parts[0] == "tmp"
    )


def _git_lines(project_root: str, args: list[str]) -> list[str]:
    try:
        result = subprocess.run(
            ["git", "-C", project_root, *args],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return []
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line]


def source_fingerprint(project_root: str) -> str:
    """Return the source-mutation fingerprint used by Bash lifecycle hooks."""
    root = normalize_path(project_root)
    files = set(_git_lines(root, ["diff", "--name-only", "HEAD"]))
    files.update(_git_lines(root, ["ls-files", "--others", "--exclude-standard"]))

    rows: list[str] = []
    for relpath in sorted(files):
        if (
            not _is_source_file(relpath)
            or _is_skippable_path(relpath)
            or _is_scratchlane_path(relpath)
        ):
            continue
        full = Path(root) / relpath
        if full.is_file():
            digest = hashlib.sha256(full.read_bytes()).hexdigest()
        else:
            digest = "DELETED"
        rows.append(f"{relpath}:{digest}")

    if not rows:
        return "EMPTY"
    data = "".join(f"{row}\n" for row in rows).encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def baseline_key(payload: Mapping[str, Any]) -> str:
    raw = str(
        payload.get("tool_use_id")
        or payload.get("session_id")
        or os.environ.get("CLAUDE_SESSION_ID", "")
        or os.getpid()
    )
    return sanitize_token(raw)


def baseline_ref(key: str) -> str:
    return f"state.db:bash-source-baseline:{key}"


def _save_baseline(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    key: str,
    fingerprint: str,
) -> None:
    with conn:
        conn.execute(
            """
            INSERT INTO bash_source_baselines
                (project_root, baseline_key, fingerprint, captured_at, consumed_at)
            VALUES (?, ?, ?, ?, NULL)
            ON CONFLICT(project_root, baseline_key) DO UPDATE SET
                fingerprint = excluded.fingerprint,
                captured_at = excluded.captured_at,
                consumed_at = NULL
            """,
            (project_root, key, fingerprint, int(time.time())),
        )


def _consume_baseline(
    conn: sqlite3.Connection,
    *,
    project_root: str,
    key: str,
) -> str:
    row = conn.execute(
        """
        SELECT fingerprint
        FROM bash_source_baselines
        WHERE project_root = ? AND baseline_key = ?
        """,
        (project_root, key),
    ).fetchone()
    fingerprint = str(row["fingerprint"] or "") if row else ""
    if row:
        with conn:
            conn.execute(
                """
                UPDATE bash_source_baselines
                SET consumed_at = ?
                WHERE project_root = ? AND baseline_key = ?
                """,
                (int(time.time()), project_root, key),
            )
    return fingerprint


def _has_git_subcommand(envelope: HookEventEnvelope, subcommand: str) -> bool:
    intent = envelope.command_intent
    if intent is None:
        return False
    return any(op.invocation.subcommand == subcommand for op in intent.git_operations)


def _head(project_root: str) -> str:
    return "\n".join(_git_lines(project_root, ["rev-parse", "HEAD"])).strip()


def capture_pre_bash_baseline(
    conn: sqlite3.Connection,
    payload: Mapping[str, Any],
) -> BashLifecycleResult:
    """Capture the per-command source fingerprint baseline after policy allow."""
    envelope = build_hook_event_envelope(payload)
    project_root = envelope.project_root
    key = baseline_key(payload)
    ref = baseline_ref(key) if project_root else ""
    if project_root:
        _save_baseline(
            conn,
            project_root=project_root,
            key=key,
            fingerprint=source_fingerprint(project_root),
        )
    return BashLifecycleResult(
        project_root=project_root,
        workflow_id="",
        baseline_key=key,
        baseline_file=ref,
    )


def handle_post_bash(conn: sqlite3.Connection, payload: Mapping[str, Any]) -> BashLifecycleResult:
    """Handle PostToolUse Bash lifecycle updates for one executed command."""
    envelope = build_hook_event_envelope(payload)
    project_root = envelope.project_root
    key = baseline_key(payload)
    ref = baseline_ref(key) if project_root else ""

    if not project_root:
        return BashLifecycleResult(
            project_root="",
            workflow_id="",
            baseline_key=key,
            baseline_file=ref,
        )

    baseline = _consume_baseline(conn, project_root=project_root, key=key)
    post_fp = source_fingerprint(project_root)
    source_mutation = bool((not baseline and post_fp != "EMPTY") or (baseline and baseline != post_fp))

    lease = leases_mod.get_current(conn, worktree_path=project_root)
    workflow_id = str(lease.get("workflow_id") or "") if lease else ""
    if not workflow_id:
        workflow_id = current_workflow_id(project_root)

    promoted = False
    new_head = ""
    landing_phase = ""
    if (
        _has_git_subcommand(envelope, "commit")
        and lease
        and (lease.get("role") or "") == "guardian"
    ):
        eval_state = evaluation_mod.get(conn, workflow_id)
        if eval_state and eval_state.get("status") == "ready_for_guardian":
            new_head = _head(project_root)
            if new_head:
                evaluation_mod.set_status(
                    conn,
                    workflow_id,
                    "ready_for_guardian",
                    head_sha=new_head,
                )
                promoted = True
                landing_phase = FEATURE_COMMIT_LANDED
                events_mod.emit(
                    conn,
                    "landing_phase_transition",
                    source="post-bash",
                    detail=f"{workflow_id}:{FEATURE_COMMIT_LANDED}:{new_head}",
                )
                events_mod.emit(
                    conn,
                    "eval_head_sync",
                    source="post-bash",
                    detail=f"guardian-commit:{workflow_id}:{new_head}",
                )

    invalidated = False
    if source_mutation and not promoted:
        invalidated = evaluation_mod.invalidate_if_ready(conn, workflow_id)
        if invalidated:
            events_mod.emit(
                conn,
                "eval_reset",
                source="post-bash",
                detail=f"source-mutation:{workflow_id}",
            )

    return BashLifecycleResult(
        project_root=project_root,
        workflow_id=workflow_id,
        baseline_key=key,
        baseline_file=ref,
        source_mutation=source_mutation,
        promoted_commit_head=promoted,
        invalidated=invalidated,
        new_head=new_head,
        landing_phase=landing_phase,
    )

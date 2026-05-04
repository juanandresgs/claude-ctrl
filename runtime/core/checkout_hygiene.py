"""Runtime-owned checkout hygiene classifier.

@decision DEC-CLAUDEX-CHECKOUT-HYGIENE-001
Title: runtime/core/checkout_hygiene.py classifies checkout dirt into active, baseline, ephemeral, and unexpected buckets
Status: accepted
Rationale: statusline.sh and live slices were inferring "dirty" from raw
  ``git status --porcelain`` output, which collapses several operationally
  different states into one count:
    * active slice changes that should be visible to implementer/reviewer
    * tolerated local baseline dirt in the canonical soak checkout
    * ephemeral runtime artifacts (retired prompt counters, policy DB copies, etc.)
    * genuinely unexpected drift

  This module is the single runtime authority that classifies checkout state
  for those four buckets. The classifier is intentionally narrow and
  deterministic:
    * workflow scope remains the sole authority for whether a path is in-scope
      or unexpected — this module calls ``workflows.classify_scope_paths()``
      rather than reimplementing path-policy logic.
    * known baseline dirt and ephemeral runtime artifacts are declared once as
      module-level pattern sets so statusline, prompts, and hooks do not each
      carry their own local ignore lists.
    * output is JSON-friendly so both CLI consumers and shell renderers can
      use the same surface.
"""

from __future__ import annotations

import fnmatch
import subprocess
import sqlite3
from typing import Iterable

from runtime.core import workflows as workflows_mod
from runtime.core.policy_utils import normalize_path

_BASELINE_TOLERATED_PATTERNS = frozenset(
    {
        "scripts/statusline.sh",
        "abtop-rate-limits.json",
        "abtop-statusline.sh",
    }
)

_EPHEMERAL_RUNTIME_PATTERNS = frozenset(
    {
        # Retired flatfiles remain tolerated during migration cleanup only.
        ".prompt-count-*",
        ".claude/.prompt-count-*",
        "policy.db",
        "telemetry/**",
    }
)


def _matches_any(path: str, patterns: Iterable[str]) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


def _git_root(worktree_path: str) -> str:
    proc = subprocess.run(
        ["git", "-C", worktree_path, "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip() or f"git exit {proc.returncode}"
        raise ValueError(
            f"classify_checkout_hygiene: {worktree_path!r} is not a git worktree: {stderr}"
        )
    return normalize_path(proc.stdout.strip())


def _read_porcelain_entries(repo_root: str) -> list[dict]:
    proc = subprocess.run(
        ["git", "-C", repo_root, "status", "--short", "--untracked-files=all", "--porcelain=1"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip() or f"git exit {proc.returncode}"
        raise ValueError(
            f"classify_checkout_hygiene: cannot read git status for {repo_root!r}: {stderr}"
        )

    entries: list[dict] = []
    for raw_line in proc.stdout.splitlines():
        if not raw_line:
            continue
        status = raw_line[:2]
        path = raw_line[3:] if len(raw_line) > 3 else ""
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        entries.append({"path": path, "status": status})
    return entries


def classify_checkout_hygiene(
    conn: sqlite3.Connection,
    *,
    worktree_path: str,
) -> dict:
    """Classify checkout dirt for ``worktree_path``.

    Returns a JSON-friendly dict containing four buckets:
      * active_slice_changes
      * baseline_tolerated_changes
      * ephemeral_runtime_artifacts
      * unexpected_drift

    ``display_dirty_count`` intentionally excludes ephemeral runtime artifacts.
    """
    repo_root = _git_root(normalize_path(worktree_path))
    binding = workflows_mod.find_binding_for_worktree(conn, repo_root)
    workflow_id = binding["workflow_id"] if binding else None
    entries = _read_porcelain_entries(repo_root)

    baseline_tolerated: list[dict] = []
    ephemeral_runtime: list[dict] = []
    pending_scope_classification: list[dict] = []

    for entry in entries:
        path = entry["path"]
        if _matches_any(path, _EPHEMERAL_RUNTIME_PATTERNS):
            ephemeral_runtime.append(entry)
            continue
        if _matches_any(path, _BASELINE_TOLERATED_PATTERNS):
            baseline_tolerated.append(entry)
            continue
        pending_scope_classification.append(entry)

    active_slice_changes: list[dict] = []
    unexpected_drift: list[dict] = []
    scope_found = False

    if pending_scope_classification:
        if workflow_id:
            classified = workflows_mod.classify_scope_paths(
                conn,
                workflow_id,
                [entry["path"] for entry in pending_scope_classification],
            )
            scope_found = classified["scope_found"]
            reason_by_path = {
                item["path"]: item["reason"]
                for item in classified["classifications"]
            }
            for entry in pending_scope_classification:
                reason = reason_by_path.get(entry["path"])
                if reason is None:
                    active_slice_changes.append(entry)
                else:
                    unexpected_drift.append({**entry, "reason": reason})
        else:
            active_slice_changes.extend(pending_scope_classification)

    display_dirty_count = (
        len(active_slice_changes)
        + len(baseline_tolerated)
        + len(unexpected_drift)
    )

    return {
        "status": "ok",
        "repo_root": repo_root,
        "workflow_id": workflow_id,
        "scope_found": scope_found,
        "display_dirty_count": display_dirty_count,
        "active_slice_count": len(active_slice_changes),
        "baseline_tolerated_count": len(baseline_tolerated),
        "ephemeral_runtime_count": len(ephemeral_runtime),
        "unexpected_drift_count": len(unexpected_drift),
        "active_slice_changes": active_slice_changes,
        "baseline_tolerated_changes": baseline_tolerated,
        "ephemeral_runtime_artifacts": ephemeral_runtime,
        "unexpected_drift": unexpected_drift,
    }


__all__ = [
    "classify_checkout_hygiene",
]

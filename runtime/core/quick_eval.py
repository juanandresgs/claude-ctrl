"""Quick evaluation for Simple Task Fast Path changes.

Validates that a working-tree diff is small enough and non-source-only
to skip full tester evaluation. Writes evaluation_state=ready_for_guardian
when criteria are met.

The STFP gate is entirely mechanical: no LLM judgment is involved. If the
diff contains source code, too many files, or too many lines, it does not
qualify for the fast path — the orchestrator must spawn a full tester.

@decision DEC-QUICKEVAL-001
Title: Quick eval is scope-gated, not LLM-gated
Status: accepted
Rationale: The original #138 proposed an LLM-as-judge. Codex review found
  that STFP changes don't need LLM judgment — they need scope validation.
  The criteria (<=50 lines, <=3 files, non-source only) are mechanically
  checkable. If the diff exceeds scope, it shouldn't be on main. This keeps
  the STFP fast path deterministic and auditable without API costs.

Integration points:
  - Reads: git working tree via subprocess (git diff --name-only, --shortstat)
  - Writes: evaluation_state table via runtime.core.evaluation.set_status()
  - Emits:  audit event via runtime.core.events.emit()
  - Called by: _handle_evaluate_quick() in runtime/cli.py
"""

from __future__ import annotations

import re
import sqlite3
import subprocess

from runtime.core import evaluation, events

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Source file extensions that require full tester evaluation.
# .sh and config formats (.json, .yaml, .toml, .md) are excluded — they
# are non-source for STFP purposes (docs, hooks, config).
_SOURCE_EXTENSIONS: frozenset[str] = frozenset(
    {
        ".py",
        ".ts",
        ".tsx",
        ".js",
        ".jsx",
        ".rs",
        ".go",
        ".java",
        ".kt",
        ".swift",
        ".c",
        ".cpp",
        ".h",
        ".hpp",
        ".cs",
        ".rb",
        ".php",
    }
)

# STFP scope limits. Callers that need stricter limits can pass overrides,
# but the canonical values match the STFP definition in MASTER_PLAN.md.
_MAX_LINES: int = 50
_MAX_FILES: int = 3


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def evaluate_quick(
    conn: sqlite3.Connection,
    project_root: str,
    workflow_id: str = "",
    *,
    max_lines: int = _MAX_LINES,
    max_files: int = _MAX_FILES,
) -> dict:
    """Evaluate working-tree diff for STFP eligibility.

    Runs ``git diff --name-only HEAD`` and ``git diff --shortstat HEAD``
    against project_root to determine if the working tree diff qualifies
    for the Simple Task Fast Path (STFP).

    Criteria (all must pass):
      1. At least one changed file exists.
      2. Number of changed files <= max_files (default 3).
      3. No changed file has a source-code extension.
      4. Total lines changed (insertions + deletions) <= max_lines (default 50).

    When all criteria pass:
      - Writes evaluation_state=ready_for_guardian via evaluation.set_status().
      - Emits an ``eval_quick_judge`` audit event via events.emit().

    When any criterion fails:
      - Returns immediately with eligible=False and a descriptive reason.
      - Does NOT write evaluation_state or emit an event.

    Args:
        conn:         Open SQLite connection (schema must be applied).
        project_root: Absolute path to the git repository root.
        workflow_id:  Workflow identifier for evaluation_state rows.
                      Defaults to "stfp-quick" if empty.
        max_lines:    Override the default MAX_LINES=50 limit (tests only).
        max_files:    Override the default MAX_FILES=3 limit (tests only).

    Returns:
        dict with keys:
          eligible (bool):      True when all STFP criteria are met.
          reason (str):         Human-readable explanation (success or failure).
          files_changed (int):  Number of changed files in the diff.
          lines_changed (int):  Total insertions + deletions in the diff.
          eval_written (bool):  True only when evaluation_state was persisted.
    """
    result: dict = {
        "eligible": False,
        "reason": "",
        "files_changed": 0,
        "lines_changed": 0,
        "eval_written": False,
    }

    # --- Step 1: Enumerate changed files ---
    try:
        diff_names = subprocess.run(
            ["git", "-C", project_root, "diff", "--name-only", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        files = [f for f in diff_names.stdout.strip().split("\n") if f]
    except Exception as exc:
        result["reason"] = f"Failed to get diff: {exc}"
        return result

    if not files:
        result["reason"] = "No changes to evaluate"
        return result

    result["files_changed"] = len(files)

    # --- Step 2: File count gate ---
    if len(files) > max_files:
        result["reason"] = f"Too many files changed ({len(files)} > {max_files})"
        return result

    # --- Step 3: Source-file gate ---
    for path in files:
        # Extract extension: if no dot, treat as no extension (empty string)
        ext = ("." + path.rsplit(".", 1)[-1]) if "." in path else ""
        if ext.lower() in _SOURCE_EXTENSIONS:
            result["reason"] = f"Source file in diff: {path} — requires full tester"
            return result

    # --- Step 4: Line count gate ---
    try:
        diff_stat = subprocess.run(
            ["git", "-C", project_root, "diff", "--shortstat", "HEAD"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        stat_text = diff_stat.stdout.strip()
        ins_match = re.search(r"(\d+) insertion", stat_text)
        del_match = re.search(r"(\d+) deletion", stat_text)
        insertions = int(ins_match.group(1)) if ins_match else 0
        deletions = int(del_match.group(1)) if del_match else 0
        total_lines = insertions + deletions
    except Exception as exc:
        result["reason"] = f"Failed to get diff stats: {exc}"
        return result

    result["lines_changed"] = total_lines

    if total_lines > max_lines:
        result["reason"] = f"Too many lines changed ({total_lines} > {max_lines})"
        return result

    # --- All criteria met: write evaluation state and emit audit event ---
    result["eligible"] = True
    result["reason"] = "STFP criteria met"

    effective_wf = workflow_id or "stfp-quick"
    try:
        evaluation.set_status(conn, effective_wf, "ready_for_guardian")
        events.emit(
            conn,
            type="eval_quick_judge",
            detail=(f"{len(files)} files, {total_lines} lines — STFP criteria met"),
        )
        result["eval_written"] = True
    except Exception as exc:
        result["eligible"] = False
        result["reason"] = f"STFP criteria met but failed to write eval state: {exc}"

    return result

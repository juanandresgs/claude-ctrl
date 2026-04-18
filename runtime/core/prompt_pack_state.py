"""Pure runtime-state capture helper (shadow-only).

@decision DEC-CLAUDEX-PROMPT-PACK-STATE-001
Title: runtime/core/prompt_pack_state.py materializes a RuntimeStateSnapshot from existing runtime authorities
Status: proposed (shadow-mode, Phase 2 prompt-pack state capture)
Rationale: The prompt-pack resolver's
  :class:`runtime.core.prompt_pack_resolver.RuntimeStateSnapshot`
  was introduced as a typed carrier the caller had to fill in by
  hand. This slice delivers the first pure helper that produces
  that snapshot from **already-present** runtime authorities
  (``workflows`` bindings, ``dispatch_leases``, ``approvals``),
  without touching git, the filesystem, or any live repo-state
  walker. ``unresolved_findings`` are now captured live from the
  canonical ``reviewer_findings`` ledger when the caller does not
  supply an explicit override. A future slice can replace the
  caller-supplied ``current_branch`` / ``worktree_path`` fallbacks
  with live git sources.

  Scope discipline:

    * **Read-only.** The helper issues only SELECT queries via
      the existing authority modules (``workflows.get_binding``,
      ``leases.list_leases``, ``approvals.list_pending``). No
      INSERT / UPDATE / DELETE. No transaction is opened. A test
      captures ``conn.total_changes`` before and after the call
      and asserts it is unchanged.
    * **No filesystem / subprocess / time I/O.** No git commands,
      no ``os.walk``, no ``open()``, no ``subprocess.run``, no
      ``time.time()``. The helper is a pure projection of the
      rows it reads from SQLite.
    * **No CLI wiring.** The instruction forbids extending
      ``runtime/cli.py`` in this slice. A later slice can expose
      ``cc-policy prompt-pack state --workflow-id ...`` once the
      capture surface is proven.
    * **Findings authority**: Unresolved reviewer findings are
      sourced from the canonical ``reviewer_findings`` ledger
      (``runtime.core.reviewer_findings.list_findings``) when the
      caller does not supply an explicit override. Open findings
      for the workflow are rendered as deterministic strings and
      sorted by ``(severity, finding_id)``.

  Resolution rules for ``current_branch`` / ``worktree_path``:

    1. Explicit keyword argument wins. If the caller passes a
       non-empty string, it is used verbatim.
    2. Otherwise, if the workflow has a
       :func:`runtime.core.workflows.get_binding` row, the
       binding's ``branch`` / ``worktree_path`` column is used.
    3. Otherwise, the helper raises ``ValueError`` with a clear
       message naming the missing field. The resolver's
       :class:`RuntimeStateSnapshot` forbids blank strings for
       these fields, so there is no silent fallback to an empty
       value.

  Deterministic ordering:

    * ``active_leases`` are sorted lexicographically by
      ``lease_id`` so snapshots are independent of the lease
      table's issuance order.
    * ``open_approvals`` are rendered as ``"{op_type}#{id}"``
      strings and sorted by ``(op_type, id)`` where ``id`` is the
      integer approval row id, so "rebase#2" comes before "rebase#10"
      instead of being sorted as bare strings. This matches the
      instruction's "simple deterministic string surface that you
      pin in tests".
    * ``unresolved_findings`` are sorted by ``(severity, finding_id)``
      when captured from the live ledger. When caller-supplied
      (explicit override), the tuple is passed through verbatim.
      :class:`RuntimeStateSnapshot` validation rejects empty
      strings in the tuple.
"""

from __future__ import annotations

import sqlite3
from typing import Any, Mapping, Optional, Tuple

from runtime.core import approvals as approvals_mod
from runtime.core import leases as leases_mod
from runtime.core import reviewer_findings as rf_mod
from runtime.core import workflows as workflows_mod
from runtime.core.prompt_pack_resolver import RuntimeStateSnapshot

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------


def _resolve_field(
    *,
    explicit: Optional[str],
    binding: Optional[Mapping[str, Any]],
    binding_key: str,
    field_name: str,
    workflow_id: str,
) -> str:
    """Resolve ``current_branch`` or ``worktree_path`` via explicit → binding → error.

    ``explicit`` wins if it is a non-empty string. Otherwise the
    binding row's ``binding_key`` column is consulted (if the
    binding exists and the column is a non-empty string).
    Otherwise ``ValueError`` is raised.
    """
    if explicit is not None:
        if not isinstance(explicit, str) or not explicit.strip():
            raise ValueError(
                f"capture_runtime_state_snapshot: explicit {field_name} must be "
                f"a non-empty string when provided; got {explicit!r}"
            )
        return explicit

    if binding is not None:
        binding_value = binding.get(binding_key)
        if isinstance(binding_value, str) and binding_value.strip():
            return binding_value

    raise ValueError(
        f"capture_runtime_state_snapshot: cannot determine {field_name} for "
        f"workflow_id={workflow_id!r} — no explicit argument and no "
        f"workflow_bindings.{binding_key} entry"
    )


def _format_approval_entry(row: Mapping[str, Any]) -> Tuple[str, int, str]:
    """Return ``(op_type, id, rendered)`` for sorting + output.

    Preserving the integer ``id`` as a separate tuple element
    gives numeric sort order (rebase#2 before rebase#10) rather than
    lexicographic sort that would put rebase#10 first.
    """
    op_type = row["op_type"]
    if not isinstance(op_type, str) or not op_type:
        raise ValueError(
            f"capture_runtime_state_snapshot: approval row has invalid "
            f"op_type {op_type!r}"
        )
    raw_id = row["id"]
    try:
        id_value = int(raw_id)
    except (TypeError, ValueError) as exc:
        raise ValueError(
            f"capture_runtime_state_snapshot: approval row has invalid id "
            f"{raw_id!r}: {exc}"
        ) from exc
    rendered = f"{op_type}#{id_value}"
    return op_type, id_value, rendered


def _render_finding(finding) -> str:
    """Render a :class:`ReviewerFinding` as a stable, prompt-pack-suitable string.

    Format: ``[severity] finding_id: title`` with optional ``(file_path:line)``
    suffix when location is available. The format is pinned in tests.
    """
    parts = [f"[{finding.severity}] {finding.finding_id}: {finding.title}"]
    if finding.file_path:
        loc = finding.file_path
        if finding.line is not None:
            loc = f"{loc}:{finding.line}"
        parts.append(f"({loc})")
    return " ".join(parts)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def capture_runtime_state_snapshot(
    conn: sqlite3.Connection,
    *,
    workflow_id: str,
    unresolved_findings: Optional[Tuple[str, ...]] = None,
    work_item_id: Optional[str] = None,
    current_branch: Optional[str] = None,
    worktree_path: Optional[str] = None,
) -> RuntimeStateSnapshot:
    """Capture a :class:`RuntimeStateSnapshot` for ``workflow_id``.

    Parameters:

      * ``conn`` — open SQLite connection. The caller owns the
        connection; the helper issues only read queries and does
        not commit.
      * ``workflow_id`` — required non-empty string identifying
        the workflow whose state should be captured.
      * ``unresolved_findings`` — when ``None`` (default), open
        findings are read from the canonical reviewer findings
        ledger for this workflow, rendered as deterministic
        strings, and sorted by ``(severity, finding_id)``. When
        an explicit tuple is provided (even empty), it is passed
        through verbatim — this preserves the override path for
        tests and operator preview.
      * ``work_item_id`` — optional scope filter for live findings
        capture. Only used when ``unresolved_findings`` is ``None``.
      * ``current_branch`` — optional explicit override. If
        provided, must be a non-empty string and takes precedence
        over the workflow binding.
      * ``worktree_path`` — optional explicit override, same
        precedence rules as ``current_branch``.

    Returns a validated :class:`RuntimeStateSnapshot`. Raises
    ``ValueError`` when:

      * ``workflow_id`` is not a non-empty string
      * ``current_branch`` or ``worktree_path`` cannot be
        determined from the explicit argument **or** the workflow
        binding
      * an approval row has a malformed ``id`` / ``op_type``
        (defensive — the authority should prevent this but the
        helper guards anyway)

    The helper is read-only. It opens no transaction, writes
    nothing, spawns no subprocess, and does not consult the
    filesystem. A test pins this by snapshotting
    ``conn.total_changes`` before and after the call.
    """
    if not isinstance(workflow_id, str) or not workflow_id:
        raise ValueError(
            "capture_runtime_state_snapshot: workflow_id must be a non-empty string"
        )

    binding = workflows_mod.get_binding(conn, workflow_id)

    resolved_branch = _resolve_field(
        explicit=current_branch,
        binding=binding,
        binding_key="branch",
        field_name="current_branch",
        workflow_id=workflow_id,
    )
    resolved_worktree = _resolve_field(
        explicit=worktree_path,
        binding=binding,
        binding_key="worktree_path",
        field_name="worktree_path",
        workflow_id=workflow_id,
    )

    # Active leases — lexicographic sort of lease_id values.
    lease_rows = leases_mod.list_leases(
        conn, status="active", workflow_id=workflow_id
    )
    lease_ids: list[str] = []
    for row in lease_rows:
        lease_id = row.get("lease_id")
        if isinstance(lease_id, str) and lease_id:
            lease_ids.append(lease_id)
    active_leases: Tuple[str, ...] = tuple(sorted(lease_ids))

    # Pending approvals — render as "op_type#id" and sort by
    # (op_type, id) numerically.
    approval_rows = approvals_mod.list_pending(conn, workflow_id=workflow_id)
    approval_entries = [_format_approval_entry(row) for row in approval_rows]
    approval_entries.sort(key=lambda t: (t[0], t[1]))
    open_approvals: Tuple[str, ...] = tuple(
        rendered for _op, _id, rendered in approval_entries
    )

    # Unresolved findings — explicit override or live capture from the
    # canonical reviewer findings ledger.
    if unresolved_findings is not None:
        # Explicit override: pass through verbatim.
        resolved_findings = unresolved_findings
    else:
        # Live capture: open findings for this workflow.
        finding_filters: dict = {"workflow_id": workflow_id, "status": "open"}
        if work_item_id is not None:
            finding_filters["work_item_id"] = work_item_id
        open_findings = rf_mod.list_findings(conn, **finding_filters)
        # Render deterministic strings sorted by (severity, finding_id).
        rendered: list[tuple[str, str, str]] = []
        for f in open_findings:
            rendered.append((f.severity, f.finding_id, _render_finding(f)))
        rendered.sort(key=lambda t: (t[0], t[1]))
        resolved_findings = tuple(entry for _, _, entry in rendered)

    return RuntimeStateSnapshot(
        current_branch=resolved_branch,
        worktree_path=resolved_worktree,
        active_leases=active_leases,
        open_approvals=open_approvals,
        unresolved_findings=resolved_findings,
    )


def capture_workflow_scope(
    conn: "sqlite3.Connection", workflow_id: str
) -> Optional[dict]:
    """Return the enforcement-authority ``workflow_scope`` row as a dict, or None.

    @decision DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-001
    Title: prompt-pack scope read-through this module preserves
      runtime.core.workflows-import discipline on prompt_pack.py
    Status: accepted
    Rationale: prompt_pack.py is import-bound to shadow-only helpers
      (see ``tests/runtime/test_prompt_pack.py::TestShadowOnlyDiscipline``)
      and cannot import ``runtime.core.workflows`` directly. This module
      already imports workflows for
      :func:`capture_runtime_state_snapshot` — adding a second narrow
      read-through keeps the permitted import surface stable while
      giving ``prompt_pack`` a path to the enforcement-authority scope
      record without growing the shadow-kernel's import surface.

      This helper is read-only (one SELECT via
      :func:`workflows.get_scope`), issues no writes, and returns the
      parsed-list dict shape the prompt-pack resolver expects for
      :func:`workflow_summary_from_contracts(workflow_scope_record=...)`.
    """
    return workflows_mod.get_scope(conn, workflow_id)


__all__ = [
    "capture_runtime_state_snapshot",
    "capture_workflow_scope",
]

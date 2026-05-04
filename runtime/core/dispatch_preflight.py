"""Read-only dispatch preflight authority.

Canonical Agent launches are only safe to expose once the runtime prompt-pack
compiler accepts the same six-field contract that SubagentStart will consume.
This module centralizes that check so stage-packet, agent-prompt, and
PreToolUse:Agent carrier writes all fail before spawn material is emitted.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Mapping

_CONTRACT_FIELDS = (
    "workflow_id",
    "stage_id",
    "goal_id",
    "work_item_id",
    "decision_scope",
    "generated_at",
)


def validate_prompt_pack_preflight(
    conn: sqlite3.Connection,
    contract: Mapping[str, object],
    *,
    label: str,
) -> dict:
    """Compile the SubagentStart prompt pack in read-only preflight mode.

    Raises ``ValueError`` with diagnostic detail when request validation or the
    prompt-pack compiler rejects the contract. Returns the compiler report on
    success. The underlying prompt-pack helper is read-only; this wrapper only
    normalizes the payload and error text for launch producers.
    """
    payload = {field: contract.get(field) for field in _CONTRACT_FIELDS}
    try:
        from runtime.core.prompt_pack import build_subagent_start_prompt_pack_response

        report = build_subagent_start_prompt_pack_response(conn, payload)
    except (LookupError, ValueError) as exc:
        raise ValueError(
            f"{label}: prompt-pack preflight failed before launch material "
            f"could be emitted. Detail: {exc}"
        ) from exc

    if not bool(report.get("healthy")):
        violations = report.get("violations") or ()
        detail = "; ".join(str(v) for v in violations) or "unknown validation failure"
        raise ValueError(
            f"{label}: prompt-pack preflight failed before launch material "
            f"could be emitted. Violations: {detail}"
        )

    return report


__all__ = ["validate_prompt_pack_preflight"]

"""Shared codec for ClauDEX Agent dispatch contract blocks.

The contract block marker is a transport fact shared by the runtime-owned
producer, the policy gate, and the PreToolUse carrier writer. Keeping the
literal prefix here prevents shell hooks or adjacent runtime modules from
quietly inventing their own parser.
"""

from __future__ import annotations

import json
from typing import Any

CONTRACT_BLOCK_MARKER = "CLAUDEX_CONTRACT_BLOCK"
CONTRACT_BLOCK_PREFIX = f"{CONTRACT_BLOCK_MARKER}:"


def first_line_contract_json(prompt: str) -> str | None:
    """Return first-line contract JSON from ``prompt``, or ``None``.

    Canonical dispatch contracts are only valid when the prompt starts with the
    marker at column 0. A later matching line is intentionally ignored because
    the orchestrator contract requires ``prompt_prefix`` to be prepended
    verbatim as the first content of the Agent prompt.
    """
    first_line = prompt.split("\n", 1)[0] if prompt else ""
    if not first_line.startswith(CONTRACT_BLOCK_PREFIX):
        return None
    return first_line[len(CONTRACT_BLOCK_PREFIX):]


def parse_first_line_contract(prompt: str) -> dict[str, Any] | None:
    """Parse a first-line contract object from ``prompt``.

    Returns ``None`` when the prompt has no first-line contract. Raises
    ``ValueError`` when the marker is present but the JSON is malformed or is
    not an object.
    """
    contract_raw = first_line_contract_json(prompt)
    if contract_raw is None:
        return None
    try:
        parsed = json.loads(contract_raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"contract_block_malformed_json: {exc}") from exc
    if not isinstance(parsed, dict):
        raise ValueError("contract_block_malformed_json: contract JSON must be an object")
    return parsed

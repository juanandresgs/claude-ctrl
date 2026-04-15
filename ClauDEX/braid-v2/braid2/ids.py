from __future__ import annotations

from uuid import uuid4


def make_id(prefix: str) -> str:
    return f"{prefix}-{uuid4().hex[:12]}"


"""Commit-trailer ingestion path for the canonical decision registry.

@decision DEC-CLAUDEX-DEC-TRAILER-INGEST-001
Title: Commit trailers are the sole landed-evidence ingestion path into
  the canonical decision registry for the Phase 7/8 cutover.
Status: proposed (shadow-mode, single-writer discipline)
Rationale: CUTOVER_PLAN lines 163-164 and 862-897 name three layers:
  (1) runtime decision/work registry as canonical authority,
  (2) git commit trailers as landed evidence,
  (3) human-readable projections as derived views.
  Layers 1 and 3 were delivered by earlier slices (decision_work_registry.py
  in Phase 1; decision_digest_projection.py in Phase 7 Slice 13).
  This module delivers layer 2: a pure parser that extracts
  ``Decision: DEC-*`` / ``decision: DEC-*`` trailers from a commit
  message and an ingestion helper that writes each extracted ID into
  the ``decisions`` table via ``decision_work_registry.upsert_decision``.

  Design constraints (DEC-CLAUDEX-DW-REGISTRY-001, upstream substrate):
    * Single-writer discipline: all writes go through ``upsert_decision``.
      No direct SQL from this module.
    * Shadow-only: this module is NOT imported at module scope by any
      hook, routing, or policy module.  CLI usage is exclusively through
      the function-scope import inside ``_handle_decision`` in
      ``runtime/cli.py`` (``cc-policy decision ingest-commit``).
    * No schema changes: the ``decisions`` table already has all
      required columns per DEC-CLAUDEX-DW-REGISTRY-001.
    * Trailer parsing is conservative: only the LAST paragraph
      (the git-trailer block) is scanned.  Mentions of ``DEC-*`` in
      the commit body proper are NOT treated as decision trailers.
    * Git subprocess access (``load_commit_message``) lives here so the
      pure parser (``parse_decision_trailers``) remains I/O-free and
      trivially testable without a real git repo.
"""

from __future__ import annotations

import re
import sqlite3
import subprocess
import time
from typing import Optional

# The upstream writer is imported at function scope inside ``ingest_commit``
# to mirror the module-scope-import discipline required by the AST
# discipline tests.  See DEC-CLAUDEX-DECISION-DIGEST-CLI-001.
#
# This module does NOT import decision_work_registry at module scope.

# ---------------------------------------------------------------------------
# Regex patterns
# ---------------------------------------------------------------------------

# Matches key: value trailer lines where key is "decision" or "DEC"
# (case-insensitive).  The DEC-* id must start with "DEC-" followed by
# one or more uppercase letters/digits/hyphens.
_TRAILER_RE = re.compile(
    r"^(?:decision|DEC)\s*:\s*(DEC-[A-Z0-9][A-Z0-9-]*)$",
    re.IGNORECASE | re.MULTILINE,
)

# A "trailer block" is the last paragraph of the commit message — the
# block of lines after the final blank line.  If there is no blank line,
# the entire message is treated as the body (no trailer block).
_BLANK_LINE_RE = re.compile(r"\n\s*\n")


# ---------------------------------------------------------------------------
# Pure parser (no I/O)
# ---------------------------------------------------------------------------


def parse_decision_trailers(message: str) -> list[str]:
    """Extract DEC-* decision IDs from commit-message trailers.

    Accepts trailer forms per git commit-message convention:
      - "decision: DEC-XXX-001"  (case-insensitive key)
      - "DEC: DEC-XXX-001"
      - "Decision: DEC-XXX"

    Returns a list of DEC-* IDs (deduplicated, order preserved from
    first appearance in the trailer block).

    Only the LAST paragraph (the trailer block, the block of lines
    after the final blank line) is scanned.  Occurrences of
    ``decision: DEC-*`` in the commit subject or body paragraphs are
    intentionally ignored to avoid false positives.

    Edge cases:
      - Empty or whitespace-only message → []
      - Message with no blank line → no trailer block → []
      - Duplicate DEC-IDs → deduped, first-occurrence order preserved
      - Case-insensitive key ("DECISION:", "Dec:") → accepted
      - DEC-ID must be uppercase (the regex enforces uppercase after "DEC-")
    """
    if not message or not message.strip():
        return []

    # Split on the LAST blank line to isolate the trailer block.
    parts = _BLANK_LINE_RE.split(message)
    if len(parts) < 2:
        # No blank line → no trailer block.
        return []

    trailer_block = parts[-1]

    seen: dict[str, None] = {}  # ordered-set via dict
    for match in _TRAILER_RE.finditer(trailer_block):
        dec_id = match.group(1).upper()
        # Normalise to uppercase so "dec-foo-001" becomes "DEC-FOO-001"
        # (the DEC-ID is already constrained to [A-Z0-9-] by the regex,
        # but the IGNORECASE flag on the outer key means the value
        # capture may be mixed-case if the author wrote "dec-foo").
        if dec_id not in seen:
            seen[dec_id] = None

    return list(seen.keys())


# ---------------------------------------------------------------------------
# Git subprocess helper
# ---------------------------------------------------------------------------


def load_commit_message(
    sha: str,
    worktree_path: Optional[str] = None,
) -> tuple[str, str, int]:
    """Return ``(message, author, committed_at_epoch)`` for a commit SHA.

    Uses ``git show --no-patch --format='%B%x1f%an%x1f%at' <sha>``
    with ASCII 31 (``\\x1f``) as the field separator so commit messages
    containing newlines parse unambiguously.

    Raises ``ValueError`` if the SHA cannot be resolved (unknown ref,
    empty repo, non-zero git exit).

    ``worktree_path`` defaults to the current working directory when
    ``None``.
    """
    cmd = [
        "git",
        "show",
        "--no-patch",
        "--format=%B\x1f%an\x1f%at",
        sha,
    ]
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        cwd=worktree_path,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip()
        raise ValueError(
            f"git show failed for SHA {sha!r}: {stderr or '(no stderr)'}"
        )

    raw = result.stdout
    # The format string produces "message\x1fauthor\x1fepoch\n".
    # Strip trailing whitespace then split on the first two \x1f separators.
    parts = raw.rstrip().split("\x1f", 2)
    if len(parts) != 3:
        raise ValueError(
            f"Unexpected git show output for SHA {sha!r}: "
            f"expected 3 \\x1f-separated fields, got {len(parts)}"
        )

    message_raw, author_raw, epoch_raw = parts
    # The message field from git may have a trailing newline appended by
    # git's format; strip it but preserve internal newlines.
    message = message_raw.rstrip("\n")
    author = author_raw.strip()
    try:
        committed_at = int(epoch_raw.strip())
    except ValueError:
        raise ValueError(
            f"Unexpected epoch string from git show for SHA {sha!r}: "
            f"{epoch_raw!r}"
        )

    return message, author, committed_at


# ---------------------------------------------------------------------------
# Ingestion writer
# ---------------------------------------------------------------------------


def ingest_commit(
    conn: sqlite3.Connection,
    sha: str,
    message: str,
    author: Optional[str] = None,
    committed_at: Optional[int] = None,
) -> list[dict]:
    """Parse trailers from ``message`` and upsert each DEC-* into ``decisions``.

    Returns a list of result dicts, one per unique DEC-ID found::

        {"decision_id": "DEC-FOO-001", "sha": sha, "action": "inserted"|"updated"}

    When no trailers are present, returns an empty list.

    Calls ``decision_work_registry.upsert_decision`` per extracted ID
    with provenance encoded in the ``rationale`` field (since the
    ``decisions`` table has no dedicated ``commit_sha`` column).  The
    provenance string is of the form::

        "Ingested from commit <sha>. Author: <author>."

    so that later ``git log`` cross-checks remain possible.

    The ``scope`` field is set to ``"kernel"`` by default (the most
    common scope for control-plane decisions; callers wanting a
    different scope should post-process via a direct ``upsert_decision``
    call after ingestion).

    The ``status`` field defaults to ``"proposed"`` since trailer-only
    ingestion cannot determine the decision's review state.  Operators
    should update the status via a direct registry call once reviewed.

    Idempotent: re-ingesting the same commit produces ``action="updated"``
    entries with refreshed provenance; it never inserts duplicates.
    """
    # Function-scope import preserves the shadow-only module-scope discipline.
    from runtime.core import decision_work_registry as dwr

    dec_ids = parse_decision_trailers(message)
    if not dec_ids:
        return []

    now = int(time.time())
    ts = committed_at if committed_at is not None else now

    provenance_parts = [f"Ingested from commit {sha}."]
    if author:
        provenance_parts.append(f"Author: {author}.")
    provenance = " ".join(provenance_parts)

    results: list[dict] = []

    for dec_id in dec_ids:
        # Check whether a row already exists so we can report the action.
        existing = dwr.get_decision(conn, dec_id)

        # Build the record.  For fresh insertions we populate all fields
        # with sensible defaults.  For updates we preserve the existing
        # title/scope/version and bump rationale + updated_at.
        if existing is None:
            record = dwr.DecisionRecord(
                decision_id=dec_id,
                title=dec_id,           # placeholder — can be updated later
                status="proposed",
                rationale=provenance,
                version=1,
                author=author or "git-trailer-ingest",
                scope="kernel",
                created_at=ts,
                updated_at=ts,
            )
            action = "inserted"
        else:
            # Update: bump updated_at and refresh rationale with provenance.
            # Preserve title, status, version, scope, and supersession links.
            record = dwr.DecisionRecord(
                decision_id=existing.decision_id,
                title=existing.title,
                status=existing.status,
                rationale=provenance,
                version=existing.version,
                author=existing.author,
                scope=existing.scope,
                supersedes=existing.supersedes,
                superseded_by=existing.superseded_by,
                created_at=existing.created_at,
                updated_at=now,
            )
            action = "updated"

        dwr.upsert_decision(conn, record)
        results.append({"decision_id": dec_id, "sha": sha, "action": action})

    return results

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
    * Trailer parsing is conservative: only the TRAILING CONTIGUOUS BLOCK
      of pure-trailer paragraphs is scanned (see DEC-CLAUDEX-DEC-TRAILER-INGEST-002
      below).  Mentions of ``DEC-*`` in the commit body proper are NOT
      treated as decision trailers.
    * Git subprocess access (``load_commit_message``) lives here so the
      pure parser (``parse_decision_trailers``) remains I/O-free and
      trivially testable without a real git repo.

@decision DEC-CLAUDEX-DEC-TRAILER-INGEST-002
Title: Extend trailer-block scanning to the trailing contiguous block of
  pure trailer paragraphs, matching git interpret-trailers convention.
Status: proposed (Slice 14R hotfix)
Rationale: The strict-last-paragraph sub-rule of DEC-CLAUDEX-DEC-TRAILER-INGEST-001
  caused ``decisions_ingested: 0`` for commits where the ``decision:`` trailer
  lived in a penultimate trailer paragraph (e.g., slice-14's own landing commit
  ``a0d60e3b`` has the ``decision:`` block separated by a blank line from the
  ``Co-Authored-By:`` block). The fix walks backward from the end, collecting
  every paragraph that is a pure trailer paragraph (all non-empty,
  non-continuation lines match RFC-5322 key-token form), and stops at the first
  non-trailer paragraph. This matches git's own ``interpret-trailers`` convention
  and preserves all other constraints: single-writer discipline, shadow-only
  ingestion, and body-prose exclusion.
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

# Matches a single RFC-5322-style trailer line: a key token (starts with a
# letter, followed by letters/digits/hyphens) then a colon, optional
# whitespace, and a non-empty value.  Used by _is_pure_trailer_paragraph to
# decide whether every non-empty, non-continuation line in a paragraph is
# trailer-shaped.
#
# Conservative anchoring: the key token must begin with [A-Za-z] and contain
# only [A-Za-z0-9-] before the colon.  This rejects lines like:
#   "Added decision: DEC-X per review."  (starts with a capital verb, but
#    the full line isn't key:value — there's prose after the colon)
# while accepting:
#   "decision: DEC-CLAUDEX-DEC-TRAILER-INGEST-001"
#   "Co-Authored-By: Claude <noreply@anthropic.com>"
#   "Workflow: global-soak-main"
_TRAILER_LINE_RE = re.compile(
    r"^[A-Za-z][A-Za-z0-9-]*\s*:\s*\S.*$",
)


# ---------------------------------------------------------------------------
# Pure parser helpers (no I/O)
# ---------------------------------------------------------------------------


def _is_pure_trailer_paragraph(para: str) -> bool:
    """Return True iff every non-empty, non-continuation line in ``para``
    matches the RFC-5322 trailer token shape (key: value).

    A paragraph qualifies as a pure trailer paragraph when:
    - It has at least one non-empty line.
    - Its first non-empty line is a ``key: value`` line (not a continuation).
    - EVERY non-empty line is either:
        (a) a trailer key-value line matching ``_TRAILER_LINE_RE``, or
        (b) a continuation line (starts with whitespace, belonging to the
            preceding trailer value per git's continuation convention).

    Empty paragraphs (all whitespace) return False to avoid collecting
    spurious blank separators.

    This helper is deliberately conservative: a single prose sentence
    like "Fix: a long description of the fix" would pass the shape
    check, but a typical body paragraph contains at least one line
    without a colon or with a colon mid-prose that doesn't fit the
    anchored key-token form, disqualifying the whole paragraph.
    """
    lines = para.splitlines()
    non_empty_lines = [ln for ln in lines if ln.strip()]
    if not non_empty_lines:
        return False

    # The first non-empty line must be a trailer line (not a continuation).
    if not _TRAILER_LINE_RE.match(non_empty_lines[0]):
        return False

    # Every non-empty line must be either a trailer line or a continuation.
    for ln in non_empty_lines:
        is_continuation = ln and ln[0] in (" ", "\t")
        if is_continuation:
            continue
        if not _TRAILER_LINE_RE.match(ln):
            return False

    return True


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

    Scans the TRAILING CONTIGUOUS BLOCK of pure-trailer paragraphs.
    Walking backward from the end of the message, every paragraph that
    qualifies as a pure trailer paragraph (per ``_is_pure_trailer_paragraph``)
    is included in the scan region.  The walk stops at the first paragraph
    that is NOT a pure trailer paragraph (body prose, subject line, etc.).
    This matches git's own ``interpret-trailers`` convention
    (DEC-CLAUDEX-DEC-TRAILER-INGEST-002).

    Occurrences of ``decision: DEC-*`` in the commit subject or body
    paragraphs are intentionally ignored to avoid false positives.

    Edge cases:
      - Empty or whitespace-only message → []
      - Message with no blank line → no trailer block → []
      - Duplicate DEC-IDs → deduped, first-occurrence order preserved
      - Case-insensitive key ("DECISION:", "Dec:") → accepted
      - DEC-ID must be uppercase (the regex enforces uppercase after "DEC-")
    """
    if not message or not message.strip():
        return []

    # Split into paragraphs on blank lines.
    parts = _BLANK_LINE_RE.split(message)
    if len(parts) < 2:
        # No blank line → no trailer block.
        return []

    # Walk backward collecting all trailing contiguous pure-trailer paragraphs.
    # The last paragraph (parts[-1]) is ALWAYS included in the scan region to
    # preserve pre-existing behavior for commits where the final paragraph mixes
    # trailer and non-trailer lines (e.g., test_malformed_lines_ignored).
    # From parts[-2] onward we require each paragraph to be a pure trailer
    # paragraph; the walk stops at the first non-trailer paragraph.
    # This handles commits with multiple trailing trailer paragraphs separated
    # by blank lines (e.g., a decision:/Workflow: block followed by a blank
    # line and a Co-Authored-By: block — the motivating slice-14 repro case).
    trailer_paragraphs: list[str] = [parts[-1]]  # always include the last paragraph

    # Walk backwards through the preceding paragraphs adding any that are
    # pure trailer paragraphs (contiguous run only — stop at first non-trailer).
    for para in reversed(parts[:-1]):
        if _is_pure_trailer_paragraph(para):
            trailer_paragraphs.insert(0, para)
        else:
            break  # First non-trailer paragraph terminates the trailing block.

    # Concatenate all collected trailer paragraphs for a single regex scan.
    trailer_block = "\n\n".join(trailer_paragraphs)

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


# ---------------------------------------------------------------------------
# Range resolver (private helper)
# ---------------------------------------------------------------------------


def _resolve_revision_range(
    range_spec: str,
    worktree_path: str | None = None,
) -> list[str]:
    """Return the list of SHAs in ``range_spec``, oldest-first.

    Calls ``git rev-list --reverse <range_spec>`` via a list-form
    subprocess (no ``shell=True``) so the range spec is never
    subject to shell interpolation.

    Returns an empty list when the range resolves to zero commits
    (e.g., ``HEAD..HEAD``).

    Raises ``ValueError`` when git reports an error (unknown ref,
    ambiguous name, invalid syntax) with the git stderr preserved
    in the message.

    ``worktree_path`` defaults to the current working directory
    when ``None``.
    """
    cmd = ["git", "rev-list", "--reverse", range_spec]
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        cwd=worktree_path,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip()
        raise ValueError(
            f"git rev-list failed for range {range_spec!r}: "
            f"{stderr or '(no stderr)'}"
        )
    shas = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return shas


# ---------------------------------------------------------------------------
# Range ingestion orchestrator
# ---------------------------------------------------------------------------


def ingest_range(
    conn: sqlite3.Connection,
    range_spec: str,
    worktree_path: str | None = None,
    *,
    dry_run: bool = False,
) -> dict:
    """Ingest decision trailers from every commit in ``range_spec``.

    ``range_spec`` uses git rev-list syntax (e.g., ``"A..B"`` for
    exclusive A, inclusive B; a single SHA means just that commit;
    branch names are resolved by git).

    Iterates oldest → newest via ``git rev-list --reverse <range_spec>``.
    For each SHA, calls ``load_commit_message`` and then ``ingest_commit``
    and aggregates results.

    When ``dry_run=True``, loads and parses each commit message but does
    NOT call ``ingest_commit`` (i.e., nothing is written to the database).
    Returns a payload shaped identically to the live path, with
    ``decisions_ingested=0`` and ``rows=[]`` so callers can inspect
    what *would* be ingested.

    Returns::

        {
            "range": range_spec,
            "commits_scanned": N,
            "decisions_ingested": total_ingested,
            "rows": [
                {"sha": sha, "decision_id": dec, "action": "inserted"|"updated"},
                ...
            ],
            "dry_run": bool,
            "status": "ok"
        }

    On range resolution failure (invalid SHA, empty range): raises
    ``ValueError`` with the git stderr preserved so callers (the CLI
    handler) can surface a structured error.

    Idempotency: re-running against the same range yields
    ``"action": "updated"`` for already-ingested DECs; the registry
    accumulates no duplicates (inherited from ``ingest_commit``
    idempotency).

    @decision DEC-CLAUDEX-DEC-INGEST-BACKFILL-001
    Title: ingest_range is the canonical batch backfill surface for
      commit-trailer decisions; it is a PURE ORCHESTRATOR over ingest_commit
      and introduces zero new upsert_decision call sites.
    Status: proposed (Phase 7 Slice 15 — batch backfill)
    Rationale: CUTOVER_PLAN §"Decision and Work Record Architecture"
      lines 862-865 names git commit trailers as landed evidence (layer 2).
      Slices 14/14R delivered the per-SHA ingestion primitive
      (ingest_commit).  Slice 15 converts that primitive into operational
      authority value by making single-command batch backfill possible, so
      the registry on a deployable machine reflects landed git history
      without operator shell scripting.
      Design constraint: NO new direct upsert_decision call sites.
      ingest_range calls ingest_commit exclusively, preserving
      single-writer discipline (DEC-CLAUDEX-DW-REGISTRY-001).
    """
    # Resolve the SHA list.  Raises ValueError on git failure.
    shas = _resolve_revision_range(range_spec, worktree_path)

    if not shas:
        return {
            "range": range_spec,
            "commits_scanned": 0,
            "decisions_ingested": 0,
            "rows": [],
            "dry_run": dry_run,
            "status": "ok",
        }

    all_rows: list[dict] = []

    for sha in shas:
        # Load commit metadata — raises ValueError on git failure for a
        # specific SHA (propagated to the caller so the partial-results
        # state is visible in the error).
        message, author, committed_at = load_commit_message(sha, worktree_path)

        if dry_run:
            # Dry-run: parse only; do NOT call ingest_commit (no DB write).
            # The returned rows list stays empty for dry-run mode.
            # We still iterate all SHAs so commits_scanned is accurate.
            continue

        # Live path: delegate to the single-writer path.
        # NO direct upsert_decision call; only ingest_commit is called.
        rows = ingest_commit(conn, sha, message, author, committed_at)
        all_rows.extend(rows)

    return {
        "range": range_spec,
        "commits_scanned": len(shas),
        "decisions_ingested": len(all_rows),
        "rows": all_rows,
        "dry_run": dry_run,
        "status": "ok",
    }


# ---------------------------------------------------------------------------
# Drift detection (read-only)
# ---------------------------------------------------------------------------


def drift_check(
    conn: sqlite3.Connection,
    range_spec: str,
    worktree_path: str | None = None,
) -> dict:
    """Report drift between commit-trailer evidence in ``range_spec`` and
    the current decision registry state.

    Read-only.  Does NOT call ``upsert_decision``, ``ingest_commit``, or
    ``ingest_range``.  The only registry interaction is a function-scope
    import of ``decision_work_registry.list_decisions`` (a pure read
    helper).

    Uses:
      * ``_resolve_revision_range(range_spec, worktree_path)`` to obtain
        the ordered SHA list (oldest-first).
      * ``load_commit_message(sha, worktree_path)`` to retrieve each commit
        message without touching the DB.
      * ``parse_decision_trailers(message)`` to extract DEC-IDs per commit.
      * ``decision_work_registry.list_decisions(conn)`` to obtain current
        registry state (full unfiltered list).

    Returns::

        {
            "range": range_spec,
            "commits_scanned": N,
            "registry_decision_count": M,
            "trailer_decisions_in_range": [DEC-IDs],
            "missing_from_registry": [DEC-IDs],
            "missing_from_commits": [DEC-IDs],
            "aligned": bool,
            "status": "ok",
            "commit_provenance": [
                {"sha": sha, "decisions_found": [...]},
                ...
            ],
        }

    Alignment semantics (Option B — DEC-CLAUDEX-DEC-DRIFT-CHECK-002):

    * ``missing_from_registry``: DEC-IDs found in any trailer within
      ``range_spec`` but absent from the ``decisions`` table (full registry).
      This is the **primary alarm signal** and the sole driver of ``aligned``.
      Always globally meaningful for the scan range: a trailer-DEC absent from
      the registry is definitively a consistency violation regardless of range.

    * ``missing_from_commits``: DEC-IDs present in the ``decisions`` table
      (full registry) that are NOT found in any trailer within ``range_spec``.
      This is purely **informational** — it is scoped to the scan range.  A
      DEC in the registry whose provenance commit lies OUTSIDE the scan range
      will appear here; this is expected and is NOT a drift condition.
      Consumers wanting strict global enforcement should use a full-history
      range (``--range <root>..HEAD``).  Registry-phantom detection (DECs in
      the registry with no commit evidence anywhere in full history) is NOT
      supported by this function — it requires a provenance-sha column in the
      registry schema, which is deferred to a future slice.

    * ``aligned = True`` iff ``missing_from_registry`` is empty, i.e., every
      DEC appearing in commit-trailer evidence within the scan range is present
      in the decision registry.  ``missing_from_commits`` does NOT participate
      in the alignment decision — it is informational only.  This rule applies
      uniformly to both empty and non-empty ranges; the previous empty-range
      branch is now a stylistic no-op under the unified rule.

    Raises ``ValueError`` on invalid range (same semantics as
    ``ingest_range`` / ``_resolve_revision_range``).

    @decision DEC-CLAUDEX-DEC-DRIFT-CHECK-001
    Title: drift_check is the canonical read-only consistency surface
      between the decision registry (layer 1) and commit-trailer evidence
      (layer 2).
    Status: proposed (Phase 7 Slice 16 — registry drift detector)
    Rationale: CUTOVER_PLAN §"Decision and Work Record Architecture" lines
      862–865 names three layers: (1) runtime registry, (2) git commit
      trailers as landed evidence, (3) human-readable projections.  Slices
      14/14R/15 completed layers 2 (ingest primitives) and 3 (digest
      projection).  This function delivers the enforcement edge between
      layers 1 and 2: a deterministic, read-only consistency check that
      answers "is the runtime registry a faithful projection of landed
      commit evidence within the scanned range?"  It is a pure composer:
      zero new upsert_decision call sites; single-writer discipline
      (DEC-CLAUDEX-DW-REGISTRY-001) is preserved because this function
      never writes to the DB.

    @decision DEC-CLAUDEX-DEC-DRIFT-CHECK-002
    Title: aligned is defined solely by missing_from_registry (Option B)
    Status: accepted (Phase 7 Slice 16R — partial-range alignment fix)
    Rationale: The slice-16 conjunction `aligned = (missing_from_registry
      == [] AND missing_from_commits == [])` produced false drift alarms on
      subset-range scans because missing_from_commits is computed against the
      full unfiltered registry — historical DECs outside the range appear as
      "missing from commits" even though they are simply out of scope.  Option
      B drops the asymmetric conjunction: aligned is True iff every in-range
      trailer DEC is reflected in the registry.  missing_from_commits is
      retained as an informational diagnostic.  Option A (filter registry by
      provenance SHA) was rejected because the decisions table has no
      provenance-sha column (runtime/core/decision_work_registry.py,
      DecisionRecord, _DECISION_COLUMNS) and both decision_work_registry.py
      and runtime/schemas.py are forbidden paths for this hotfix slice.
    """
    # Function-scope import of the read-only registry helper.
    # Module-scope import of decision_work_registry is banned per
    # DEC-CLAUDEX-DEC-TRAILER-INGEST-001 (shadow-only module-scope discipline).
    # Only list_decisions (a read helper) is used — no write helpers.
    from runtime.core import decision_work_registry as dwr

    # Step 1: Resolve the SHA list.  Raises ValueError on git failure.
    shas = _resolve_revision_range(range_spec, worktree_path)

    # Step 2: Load and parse each commit message; collect per-SHA evidence.
    commit_provenance: list[dict] = []
    # Ordered union of all DEC-IDs seen across the range (deduplicated).
    trailer_ids_ordered: dict[str, None] = {}  # ordered set via dict

    for sha in shas:
        message, _author, _committed_at = load_commit_message(sha, worktree_path)
        dec_ids = parse_decision_trailers(message)
        commit_provenance.append({"sha": sha, "decisions_found": dec_ids})
        for dec_id in dec_ids:
            if dec_id not in trailer_ids_ordered:
                trailer_ids_ordered[dec_id] = None

    trailer_ids_in_range: list[str] = list(trailer_ids_ordered.keys())
    trailer_set = set(trailer_ids_in_range)

    # Step 3: Read the current registry state (full unfiltered list).
    registry_records = dwr.list_decisions(conn)
    registry_ids: list[str] = [r.decision_id for r in registry_records]
    registry_set = set(registry_ids)

    # Step 4: Compute drift sets.
    missing_from_registry = sorted(trailer_set - registry_set)
    missing_from_commits = sorted(registry_set - trailer_set)

    # Step 5: Determine alignment (Option B — DEC-CLAUDEX-DEC-DRIFT-CHECK-002).
    # aligned is True iff every DEC in commit-trailer evidence within the
    # scan range is present in the decision registry.
    # missing_from_commits is informational only and does NOT affect aligned:
    #   - For subset-range scans, out-of-scope historical DECs appear here
    #     naturally and are NOT drift conditions.
    #   - For full-history scans against a backfilled registry,
    #     missing_from_commits will be empty.
    # The empty-range branch is a no-op under this unified rule (both paths
    # evaluate to len(missing_from_registry) == 0) and is collapsed for clarity.
    aligned = len(missing_from_registry) == 0

    return {
        "range": range_spec,
        "commits_scanned": len(shas),
        "registry_decision_count": len(registry_ids),
        "trailer_decisions_in_range": trailer_ids_in_range,
        "missing_from_registry": missing_from_registry,
        "missing_from_commits": missing_from_commits,
        "aligned": aligned,
        "status": "ok",
        "commit_provenance": commit_provenance,
        "scope_note": (
            "missing_from_commits is informational only (Option B semantics, "
            "DEC-CLAUDEX-DEC-DRIFT-CHECK-002): DECs in the registry whose "
            "provenance commits lie outside the scan range appear here as "
            "expected — they are NOT drift conditions. aligned=True means "
            "every DEC trailer found in the scanned commits is present in "
            "the registry. For global enforcement, use a full-history range. "
            "Registry-phantom detection (DECs with no commit evidence) "
            "requires provenance-sha in the registry schema (future slice)."
        ),
    }

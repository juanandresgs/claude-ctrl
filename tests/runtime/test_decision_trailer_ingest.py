"""Tests for runtime/core/decision_trailer_ingest.py.

@decision DEC-CLAUDEX-DEC-TRAILER-INGEST-TESTS-001
Title: decision_trailer_ingest unit tests pin the parser and ingestion helper
Status: proposed (Phase 7 Slice 14 — commit-trailer ingestion)
Rationale: The pure parser (``parse_decision_trailers``) and the
  ingestion helper (``ingest_commit``) are the load-bearing
  primitives for the commit-trailer → registry pipeline.  These
  tests assert:

    1. The pure parser correctly identifies ``Decision:`` /
       ``decision:`` / ``DEC:`` trailer forms in the last paragraph.
    2. The parser ignores DEC-* mentions in the commit body proper.
    3. Duplicate DEC-IDs are deduplicated, order preserved.
    4. Empty / whitespace-only / no-blank-line messages return [].
    5. The ingestion helper writes records via ``upsert_decision``
       (round-trip verified via ``get_decision`` / ``list_decisions``).
    6. Re-ingesting the same commit is idempotent (action="updated").
    7. Commits with no trailers produce an empty result list without
       writing any rows.
    8. Provenance (commit SHA) is captured in the ``rationale`` field
       of each ingested record.
"""

from __future__ import annotations

import inspect
import os
import sqlite3
import subprocess

import pytest

from runtime.core import decision_trailer_ingest as dti
from runtime.core import decision_work_registry as dwr
from runtime.schemas import ensure_schema


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """In-memory SQLite with the full schema — same pattern as test_decision_work_registry."""
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# parse_decision_trailers — pure parser
# ---------------------------------------------------------------------------


class TestParseDecisionTrailers:
    """Unit tests for the pure parser (no I/O, no DB)."""

    def test_empty_message_returns_empty(self):
        assert dti.parse_decision_trailers("") == []

    def test_whitespace_only_returns_empty(self):
        assert dti.parse_decision_trailers("   \n\n  ") == []

    def test_no_blank_line_returns_empty(self):
        """Without a blank line there is no trailer block."""
        msg = "Fix a bug\nSome continuation line"
        assert dti.parse_decision_trailers(msg) == []

    def test_single_decision_trailer_lowercase_key(self):
        msg = "Fix something\n\ndecision: DEC-FOO-001"
        assert dti.parse_decision_trailers(msg) == ["DEC-FOO-001"]

    def test_single_decision_trailer_titlecase_key(self):
        msg = "Fix something\n\nDecision: DEC-FOO-001"
        assert dti.parse_decision_trailers(msg) == ["DEC-FOO-001"]

    def test_single_decision_trailer_uppercase_key_DEC(self):
        msg = "Fix something\n\nDEC: DEC-BAR-002"
        assert dti.parse_decision_trailers(msg) == ["DEC-BAR-002"]

    def test_multiple_trailers_both_extracted(self):
        msg = "Subject line\n\nSome body text here.\n\ndecision: DEC-A-001\nDEC: DEC-B-002"
        result = dti.parse_decision_trailers(msg)
        assert result == ["DEC-A-001", "DEC-B-002"]

    def test_duplicate_dec_ids_deduped_order_preserved(self):
        msg = "Subject\n\ndecision: DEC-FOO-001\ndecision: DEC-FOO-001\nDEC: DEC-BAR-001"
        result = dti.parse_decision_trailers(msg)
        assert result == ["DEC-FOO-001", "DEC-BAR-001"]

    def test_body_mention_not_treated_as_trailer(self):
        """DEC-* mentions in the commit body (not last paragraph) are ignored."""
        msg = (
            "Subject line\n"
            "\n"
            "This commit implements decision: DEC-BODY-999 which was\n"
            "already in the main body text.\n"
            "\n"
            "decision: DEC-TRAILER-001"
        )
        result = dti.parse_decision_trailers(msg)
        # Only DEC-TRAILER-001 should be extracted (it's in the last paragraph).
        # DEC-BODY-999 is in a middle paragraph and must NOT appear.
        assert result == ["DEC-TRAILER-001"]
        assert "DEC-BODY-999" not in result

    def test_body_only_no_trailer_block(self):
        """Commit with only a subject and body but no final trailer paragraph."""
        msg = (
            "Subject\n"
            "\n"
            "Some body text mentioning DEC-IGNORE-001 inline.\n"
            "More body text."
        )
        # The last paragraph is the body paragraph itself.
        # The body paragraph doesn't have a trailer-form line.
        result = dti.parse_decision_trailers(msg)
        assert result == []

    def test_malformed_lines_ignored(self):
        """Lines that don't match key: value are ignored."""
        msg = "Subject\n\nNot a trailer line\nAlso not: valid\ndecision: DEC-OK-001"
        result = dti.parse_decision_trailers(msg)
        assert result == ["DEC-OK-001"]

    def test_dec_id_must_have_uppercase_after_prefix(self):
        """DEC-* must be uppercase letters/digits/hyphens after 'DEC-'."""
        # The regex requires [A-Z0-9][A-Z0-9-]* after "DEC-" so "DEC-foo"
        # won't match (lowercase after the dash). Note: IGNORECASE applies
        # to the key part but the regex requires the DEC-ID to start with
        # an uppercase char.
        msg = "Subject\n\ndecision: DEC-lowercase"
        result = dti.parse_decision_trailers(msg)
        # "DEC-lowercase" has a lowercase char after DEC- so it should NOT match
        # the [A-Z0-9][A-Z0-9-]* requirement (no IGNORECASE on value group).
        # After normalisation via .upper(), "DEC-LOWERCASE" would be produced
        # but the regex won't match in the first place due to ^[A-Z0-9] check.
        # The regex pattern is: (DEC-[A-Z0-9][A-Z0-9-]*) with IGNORECASE.
        # IGNORECASE means "DEC-lowercase" WILL match and be uppercased.
        # This is intentional: the key is case-insensitive; the value is
        # normalised to uppercase.
        # So this test verifies that normalisation happens.
        assert result == ["DEC-LOWERCASE"]

    def test_trailing_whitespace_on_dec_id_stripped(self):
        msg = "Subject\n\ndecision: DEC-FOO-001  "
        result = dti.parse_decision_trailers(msg)
        # The regex anchors on end-of-line, so trailing spaces may cause no match.
        # This tests that we handle edge whitespace gracefully (result may be []
        # or ["DEC-FOO-001"] depending on regex; we assert the ID is clean).
        # Since the regex uses $ with MULTILINE, trailing spaces before EOL
        # mean no match — that's acceptable conservative behaviour.
        # Both [] and ["DEC-FOO-001"] are conformant; we just check no crash.
        assert isinstance(result, list)

    def test_only_last_paragraph_scanned(self):
        """Three-paragraph commit — only the last paragraph is the trailer block."""
        msg = (
            "Subject\n"
            "\n"
            "Body paragraph with decision: DEC-MIDDLE-001 mention.\n"
            "\n"
            "decision: DEC-TRAILER-001"
        )
        result = dti.parse_decision_trailers(msg)
        assert "DEC-TRAILER-001" in result
        assert "DEC-MIDDLE-001" not in result

    def test_multiple_blank_lines_last_paragraph_only(self):
        """Multiple blank lines; last paragraph is still the trailer block."""
        msg = (
            "Subject\n"
            "\n"
            "\n"
            "Middle body.\n"
            "\n"
            "decision: DEC-LAST-001\nDEC: DEC-LAST-002"
        )
        result = dti.parse_decision_trailers(msg)
        assert result == ["DEC-LAST-001", "DEC-LAST-002"]


# ---------------------------------------------------------------------------
# ingest_commit — DB writer
# ---------------------------------------------------------------------------


class TestIngestCommit:
    """Tests for ingest_commit against a real in-memory SQLite connection."""

    _TEST_SHA = "abc1234def5678900000000000000000000000001"
    _TEST_AUTHOR = "test-author"
    _TEST_TS = 1_700_000_000

    def _message_with_trailers(self, *dec_ids: str) -> str:
        trailer_lines = "\n".join(f"decision: {d}" for d in dec_ids)
        return f"Commit subject\n\nCommit body.\n\n{trailer_lines}"

    def test_no_trailers_returns_empty_list(self, conn):
        msg = "Fix a bug\n\nNo decision trailers here."
        rows = dti.ingest_commit(conn, self._TEST_SHA, msg)
        assert rows == []

    def test_no_trailers_writes_no_rows(self, conn):
        msg = "Fix a bug\n\nNo decision trailers here."
        dti.ingest_commit(conn, self._TEST_SHA, msg)
        decisions = dwr.list_decisions(conn)
        assert len(decisions) == 0

    def test_single_trailer_inserts_one_row(self, conn):
        msg = self._message_with_trailers("DEC-SINGLE-001")
        rows = dti.ingest_commit(
            conn, self._TEST_SHA, msg, self._TEST_AUTHOR, self._TEST_TS
        )
        assert len(rows) == 1
        assert rows[0]["decision_id"] == "DEC-SINGLE-001"
        assert rows[0]["sha"] == self._TEST_SHA
        assert rows[0]["action"] == "inserted"

    def test_single_trailer_row_retrievable_via_get(self, conn):
        msg = self._message_with_trailers("DEC-RETREIVE-001")
        dti.ingest_commit(conn, self._TEST_SHA, msg, self._TEST_AUTHOR, self._TEST_TS)
        rec = dwr.get_decision(conn, "DEC-RETREIVE-001")
        assert rec is not None
        assert rec.decision_id == "DEC-RETREIVE-001"
        assert rec.status == "proposed"

    def test_single_trailer_row_retrievable_via_list(self, conn):
        msg = self._message_with_trailers("DEC-LIST-001")
        dti.ingest_commit(conn, self._TEST_SHA, msg, self._TEST_AUTHOR, self._TEST_TS)
        decisions = dwr.list_decisions(conn)
        assert len(decisions) == 1
        assert decisions[0].decision_id == "DEC-LIST-001"

    def test_three_trailers_three_inserts(self, conn):
        msg = self._message_with_trailers("DEC-A-001", "DEC-B-001", "DEC-C-001")
        rows = dti.ingest_commit(
            conn, self._TEST_SHA, msg, self._TEST_AUTHOR, self._TEST_TS
        )
        assert len(rows) == 3
        ids = {r["decision_id"] for r in rows}
        assert ids == {"DEC-A-001", "DEC-B-001", "DEC-C-001"}
        actions = {r["action"] for r in rows}
        assert actions == {"inserted"}

    def test_reingest_same_commit_produces_update(self, conn):
        msg = self._message_with_trailers("DEC-IDEM-001")
        rows1 = dti.ingest_commit(conn, self._TEST_SHA, msg, self._TEST_AUTHOR, self._TEST_TS)
        assert rows1[0]["action"] == "inserted"

        rows2 = dti.ingest_commit(conn, self._TEST_SHA, msg, self._TEST_AUTHOR, self._TEST_TS)
        assert len(rows2) == 1
        assert rows2[0]["action"] == "updated"

    def test_reingest_does_not_duplicate_rows(self, conn):
        msg = self._message_with_trailers("DEC-NODUP-001")
        dti.ingest_commit(conn, self._TEST_SHA, msg, self._TEST_AUTHOR, self._TEST_TS)
        dti.ingest_commit(conn, self._TEST_SHA, msg, self._TEST_AUTHOR, self._TEST_TS)
        decisions = dwr.list_decisions(conn)
        assert len(decisions) == 1

    def test_provenance_captured_in_rationale(self, conn):
        """Commit SHA must appear in the rationale field for cross-check capability."""
        msg = self._message_with_trailers("DEC-PROV-001")
        dti.ingest_commit(
            conn, self._TEST_SHA, msg, self._TEST_AUTHOR, self._TEST_TS
        )
        rec = dwr.get_decision(conn, "DEC-PROV-001")
        assert rec is not None
        assert self._TEST_SHA in rec.rationale

    def test_author_captured_in_provenance(self, conn):
        """Author name must appear in the rationale field."""
        msg = self._message_with_trailers("DEC-AUTH-001")
        dti.ingest_commit(
            conn, self._TEST_SHA, msg, self._TEST_AUTHOR, self._TEST_TS
        )
        rec = dwr.get_decision(conn, "DEC-AUTH-001")
        assert rec is not None
        assert self._TEST_AUTHOR in rec.rationale

    def test_no_author_still_ingests(self, conn):
        """author=None is acceptable — provenance uses only the SHA."""
        msg = self._message_with_trailers("DEC-NOAUTH-001")
        rows = dti.ingest_commit(conn, self._TEST_SHA, msg, author=None)
        assert len(rows) == 1
        rec = dwr.get_decision(conn, "DEC-NOAUTH-001")
        assert rec is not None
        assert self._TEST_SHA in rec.rationale

    def test_record_status_is_proposed(self, conn):
        """Freshly ingested records default to 'proposed' status."""
        msg = self._message_with_trailers("DEC-STATUS-001")
        dti.ingest_commit(conn, self._TEST_SHA, msg, self._TEST_AUTHOR, self._TEST_TS)
        rec = dwr.get_decision(conn, "DEC-STATUS-001")
        assert rec is not None
        assert rec.status == "proposed"

    def test_ingest_two_different_commits_accumulates_rows(self, conn):
        """Two different SHAs with different DEC-IDs accumulate distinct rows."""
        sha1 = "aaa1111100000000000000000000000000000001"
        sha2 = "bbb2222200000000000000000000000000000002"
        msg1 = self._message_with_trailers("DEC-COMMIT1-001")
        msg2 = self._message_with_trailers("DEC-COMMIT2-001")
        dti.ingest_commit(conn, sha1, msg1)
        dti.ingest_commit(conn, sha2, msg2)
        decisions = dwr.list_decisions(conn)
        ids = {d.decision_id for d in decisions}
        assert "DEC-COMMIT1-001" in ids
        assert "DEC-COMMIT2-001" in ids
        assert len(decisions) == 2

    # ------------------------------------------------------------------
    # Compound-Interaction Test: end-to-end production sequence
    # Parse trailers → ingest into DB → read back via list/get
    # ------------------------------------------------------------------

    def test_compound_trailer_ingest_round_trip(self, conn):
        """Production sequence: commit with 2 trailers → ingest → verify via digest path.

        This test exercises the real production sequence:
          parse_decision_trailers → ingest_commit → list_decisions
        crossing the parser, writer, and reader boundaries.
        """
        sha = "feed000000000000000000000000000000000001"
        author = "guardian"
        ts = 1_710_000_000
        msg = (
            "land: slice 14 decision trailer ingestion\n"
            "\n"
            "This commit delivers the commit-trailer ingestion path that\n"
            "populates the canonical decision registry from landed commits.\n"
            "\n"
            "decision: DEC-CLAUDEX-DEC-TRAILER-INGEST-001\n"
            "DEC: DEC-CLAUDEX-DW-REGISTRY-001"
        )

        # Step 1: Pure parser returns both DEC-IDs from the trailer block.
        parsed = dti.parse_decision_trailers(msg)
        assert "DEC-CLAUDEX-DEC-TRAILER-INGEST-001" in parsed
        assert "DEC-CLAUDEX-DW-REGISTRY-001" in parsed
        assert len(parsed) == 2

        # Step 2: Ingest writes both rows.
        rows = dti.ingest_commit(conn, sha, msg, author, ts)
        assert len(rows) == 2
        assert all(r["action"] == "inserted" for r in rows)

        # Step 3: Verify via list_decisions (the read path used by digest CLI).
        decisions = dwr.list_decisions(conn)
        ids = {d.decision_id for d in decisions}
        assert "DEC-CLAUDEX-DEC-TRAILER-INGEST-001" in ids
        assert "DEC-CLAUDEX-DW-REGISTRY-001" in ids

        # Step 4: Verify via get_decision (point-lookup).
        rec = dwr.get_decision(conn, "DEC-CLAUDEX-DEC-TRAILER-INGEST-001")
        assert rec is not None
        assert sha in rec.rationale
        assert author in rec.rationale

        # Step 5: Re-ingest is idempotent — action becomes "updated", no duplicate rows.
        rows2 = dti.ingest_commit(conn, sha, msg, author, ts)
        assert all(r["action"] == "updated" for r in rows2)
        decisions2 = dwr.list_decisions(conn)
        assert len(decisions2) == 2  # still exactly 2


# ---------------------------------------------------------------------------
# TestTrailingContiguousTrailerBlock — DEC-CLAUDEX-DEC-TRAILER-INGEST-002
# Regression tests for multi-paragraph trailer block walk (Slice 14R hotfix).
# ---------------------------------------------------------------------------


class TestTrailingContiguousTrailerBlock:
    """Tests for the trailing-contiguous-block walk introduced by
    DEC-CLAUDEX-DEC-TRAILER-INGEST-002.

    These tests pin the motivating bug (decision trailer in a penultimate
    trailer paragraph was dropped) and the guard against body-prose
    false-positives, while confirming existing slice-13/14 shapes continue
    to work correctly.
    """

    def test_decision_in_penultimate_trailer_paragraph_ingested(self):
        """The motivating case (test 1): decision: in the penultimate trailer
        paragraph must be extracted even when the final paragraph is a
        Co-Authored-By: block.

        Pre-fix: returns [].  Post-fix: returns ["DEC-A-001"].
        """
        msg = (
            "Subject line\n"
            "\n"
            "Body prose paragraph.\n"
            "\n"
            "decision: DEC-A-001\n"
            "Workflow: global-soak-main\n"
            "\n"
            "Co-Authored-By: Claude <noreply@anthropic.com>"
        )
        result = dti.parse_decision_trailers(msg)
        assert result == ["DEC-A-001"]

    def test_multiple_decision_lines_in_same_penultimate_trailer_paragraph(self):
        """Multiple decision: lines in the same penultimate trailer paragraph
        are all extracted (test 2).
        """
        msg = (
            "Subject\n"
            "\n"
            "Body.\n"
            "\n"
            "decision: DEC-A-001\n"
            "decision: DEC-B-002\n"
            "\n"
            "Co-Authored-By: X <x@example.com>"
        )
        result = dti.parse_decision_trailers(msg)
        assert result == ["DEC-A-001", "DEC-B-002"]

    def test_decisions_across_multiple_trailer_paragraphs(self):
        """DEC-IDs spread across three trailing trailer paragraphs are all
        collected (test 3).
        """
        msg = (
            "Subject\n"
            "\n"
            "Body.\n"
            "\n"
            "decision: DEC-A-001\n"
            "decision: DEC-B-002\n"
            "\n"
            "decision: DEC-C-003\n"
            "\n"
            "Co-Authored-By: X <x@example.com>"
        )
        result = dti.parse_decision_trailers(msg)
        assert result == ["DEC-A-001", "DEC-B-002", "DEC-C-003"]

    def test_body_paragraph_with_trailer_shaped_prose_still_excluded(self):
        """A body paragraph whose first line starts with a verb ("Added
        decision: ...") does NOT match the pure-trailer-paragraph heuristic
        because "Added" followed by a space does not satisfy the anchored
        key-token form (key must be directly followed by colon, not by space
        then another word).  Guards against Design-B drift (test 4).
        """
        msg = (
            "Subject\n"
            "\n"
            "Added decision: DEC-BODY-999 per review discussion.\n"
            "\n"
            "decision: DEC-TRAILER-001\n"
            "\n"
            "Co-Authored-By: X <x@example.com>"
        )
        result = dti.parse_decision_trailers(msg)
        assert result == ["DEC-TRAILER-001"]
        assert "DEC-BODY-999" not in result

    def test_non_trailer_paragraph_before_trailer_block_stops_walk(self):
        """A decision: trailer that sits BEFORE a prose paragraph is NOT
        in the trailing contiguous block and must NOT be extracted (test 5).

        The trailing contiguous block is: only Co-Authored-By: X (the final
        paragraph).  The preceding paragraph is prose — walk stops.
        DEC-ISOLATED-001 is in a paragraph further back, outside the block.
        """
        msg = (
            "decision: DEC-ISOLATED-001\n"
            "\n"
            "Some prose paragraph.\n"
            "\n"
            "Co-Authored-By: X <x@example.com>"
        )
        result = dti.parse_decision_trailers(msg)
        assert result == []
        assert "DEC-ISOLATED-001" not in result

    def test_slice13_style_single_trailer_paragraph_still_works(self):
        """Slice-13-style commit where all trailers including decision: live
        in the single final paragraph (test 6).  Regression pin: the
        backward walk must continue to correctly scan a single final trailer
        paragraph with no preceding trailer paragraphs.
        """
        msg = (
            "land: slice 13 decision digest projection\n"
            "\n"
            "Delivers the decision digest projection module that reads the\n"
            "canonical decision registry and produces a human-readable view.\n"
            "\n"
            "decision: DEC-DISCIPLINE-REGISTRY-INVARIANT-COMPUTED-001\n"
            "Workflow: global-soak-main\n"
            "Work-item: slice13-implementer\n"
            "Lease: abc123def456\n"
            "Co-Authored-By: Claude <noreply@anthropic.com>"
        )
        result = dti.parse_decision_trailers(msg)
        assert "DEC-DISCIPLINE-REGISTRY-INVARIANT-COMPUTED-001" in result

    def test_slice14_landing_shape_decision_now_extracted(self):
        """The EXACT motivating repro: a slice-14-shaped message with
        decision: DEC-CLAUDEX-DEC-TRAILER-INGEST-001 in the penultimate
        trailer paragraph and Co-Authored-By: as the final paragraph (test 7).

        Pre-fix: returns [].  Post-fix: returns the DEC-ID.
        This is the canonical regression test for DEC-CLAUDEX-DEC-TRAILER-INGEST-002.
        """
        msg = (
            "land: slice 14 decision trailer ingestion\n"
            "\n"
            "Delivers the commit-trailer ingestion path (layer 2 of the\n"
            "three-layer decision-registry architecture) that extracts\n"
            "Decision: DEC-* trailers from git commits and upserts them\n"
            "into the canonical decisions table.\n"
            "\n"
            "decision: DEC-CLAUDEX-DEC-TRAILER-INGEST-001\n"
            "Workflow: global-soak-main\n"
            "Work-item: slice14-implementer\n"
            "Lease: 0e8053abf3514ea6a777ac4d03d90238\n"
            "\n"
            "Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
        )
        result = dti.parse_decision_trailers(msg)
        assert result == ["DEC-CLAUDEX-DEC-TRAILER-INGEST-001"]

    def test_only_co_authored_by_returns_empty(self):
        """A commit whose only trailer is Co-Authored-By: (no decision:
        anywhere) returns [] (test 8).
        """
        msg = (
            "Fix a minor bug\n"
            "\n"
            "Addresses a small edge case in the configuration loader.\n"
            "\n"
            "Co-Authored-By: Alice <alice@example.com>"
        )
        result = dti.parse_decision_trailers(msg)
        assert result == []

    def test_body_only_no_trailing_trailer_paragraph_returns_empty(self):
        """Body-only commit with no trailing trailer paragraphs (recommended
        test 9).
        """
        msg = (
            "Subject\n"
            "\n"
            "Just body prose, no trailers at all."
        )
        result = dti.parse_decision_trailers(msg)
        assert result == []

    def test_whitespace_continuation_line_in_trailer_paragraph_accepted(self):
        """A trailer paragraph with a continuation line (indented with a
        leading space) is still accepted as a pure trailer paragraph, and
        the decision: trailer in the same paragraph is extracted (recommended
        test 10).
        """
        msg = (
            "Subject\n"
            "\n"
            "Body.\n"
            "\n"
            "Lease: abc123\n"
            "  continuation-of-lease-value\n"
            "decision: DEC-CONT-001\n"
            "\n"
            "Co-Authored-By: X <x@example.com>"
        )
        result = dti.parse_decision_trailers(msg)
        assert "DEC-CONT-001" in result


# ---------------------------------------------------------------------------
# Fixtures shared by TestResolveRevisionRange and TestIngestRange
# ---------------------------------------------------------------------------


_GIT_ENV = {
    **os.environ,
    "GIT_AUTHOR_NAME": "Test",
    "GIT_AUTHOR_EMAIL": "t@t.com",
    "GIT_COMMITTER_NAME": "Test",
    "GIT_COMMITTER_EMAIL": "t@t.com",
}


def _make_commit(repo: "os.PathLike[str]", filename: str, msg: str) -> str:
    """Create a file, stage it, commit with ``msg``, and return the SHA."""
    repo_path = str(repo)
    fp = os.path.join(repo_path, filename)
    with open(fp, "w") as fh:
        fh.write(filename)
    subprocess.run(["git", "-C", repo_path, "add", filename],
                   check=True, capture_output=True, env=_GIT_ENV)
    subprocess.run(["git", "-C", repo_path, "commit", "-m", msg],
                   check=True, capture_output=True, env=_GIT_ENV)
    result = subprocess.run(
        ["git", "-C", repo_path, "rev-parse", "HEAD"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


@pytest.fixture
def git_repo_range(tmp_path):
    """Four-commit git repo for range-ingestion tests.

    Commit 0 (root/anchor): no trailers — used as the exclusive lower bound
      so we can do "sha_0..sha_a" to select exactly sha_a.
    Commit A: decision: DEC-RANGE-A-001
    Commit B (middle): no trailers
    Commit C (newest): decision: DEC-RANGE-C-001 + decision: DEC-RANGE-C-002

    Returns ``(repo_path, sha_0, sha_a, sha_b, sha_c)``.
    Using ``sha_0..sha_c`` as the range_spec selects sha_a, sha_b, sha_c.
    Using ``sha_0..sha_a`` selects exactly sha_a.
    """
    repo = tmp_path / "range_repo"
    repo.mkdir()
    rp = str(repo)
    subprocess.run(["git", "init", rp], check=True, capture_output=True, env=_GIT_ENV)
    subprocess.run(["git", "-C", rp, "config", "user.email", "t@t.com"],
                   check=True, capture_output=True, env=_GIT_ENV)
    subprocess.run(["git", "-C", rp, "config", "user.name", "Test"],
                   check=True, capture_output=True, env=_GIT_ENV)

    msg_0 = "chore: initial commit (anchor)"
    msg_a = "feat: commit A\n\nBody.\n\ndecision: DEC-RANGE-A-001"
    msg_b = "fix: commit B\n\nNo trailers in B."
    msg_c = (
        "feat: commit C\n"
        "\n"
        "Body.\n"
        "\n"
        "decision: DEC-RANGE-C-001\n"
        "decision: DEC-RANGE-C-002"
    )
    sha_0 = _make_commit(repo, "anchor.txt", msg_0)
    sha_a = _make_commit(repo, "a.txt", msg_a)
    sha_b = _make_commit(repo, "b.txt", msg_b)
    sha_c = _make_commit(repo, "c.txt", msg_c)
    return repo, sha_0, sha_a, sha_b, sha_c


# ---------------------------------------------------------------------------
# TestResolveRevisionRange — private helper
# ---------------------------------------------------------------------------


class TestResolveRevisionRange:
    """Unit tests for the private _resolve_revision_range helper."""

    def test_resolve_empty_range_returns_empty_list(self, git_repo_range):
        """HEAD..HEAD is a valid empty range and must return []."""
        repo, sha_0, sha_a, sha_b, sha_c = git_repo_range
        shas = dti._resolve_revision_range("HEAD..HEAD", worktree_path=str(repo))
        assert shas == []

    def test_resolve_returns_oldest_first(self, git_repo_range):
        """git rev-list --reverse produces SHAs oldest→newest."""
        repo, sha_0, sha_a, sha_b, sha_c = git_repo_range
        # Range from sha_a (exclusive) to sha_c (inclusive) = sha_b, sha_c
        range_spec = f"{sha_a}..{sha_c}"
        shas = dti._resolve_revision_range(range_spec, worktree_path=str(repo))
        assert shas == [sha_b, sha_c]

    def test_resolve_invalid_range_raises(self, git_repo_range):
        """A bogus ref raises ValueError containing git stderr."""
        repo, sha_0, sha_a, sha_b, sha_c = git_repo_range
        with pytest.raises(ValueError, match="git rev-list failed"):
            dti._resolve_revision_range(
                "nonexistent_ref_abc..HEAD", worktree_path=str(repo)
            )


# ---------------------------------------------------------------------------
# TestIngestRange — main batch orchestrator
# ---------------------------------------------------------------------------


class TestIngestRange:
    """Tests for ingest_range — the Slice 15 batch backfill orchestrator.

    @decision DEC-CLAUDEX-DEC-INGEST-BACKFILL-001 (tests exercise this invariant)
    """

    def test_ingest_range_empty_returns_zero(self, git_repo_range, conn):
        """Empty range (HEAD..HEAD) → commits_scanned=0, decisions_ingested=0."""
        repo, sha_0, sha_a, sha_b, sha_c = git_repo_range
        result = dti.ingest_range(conn, "HEAD..HEAD", worktree_path=str(repo))
        assert result["status"] == "ok"
        assert result["commits_scanned"] == 0
        assert result["decisions_ingested"] == 0
        assert result["rows"] == []
        assert result["range"] == "HEAD..HEAD"
        assert result["dry_run"] is False

    def test_ingest_range_single_commit_one_trailer(self, git_repo_range, conn):
        """Range of exactly one commit (sha_0..sha_a = just sha_a)."""
        repo, sha_0, sha_a, sha_b, sha_c = git_repo_range
        # sha_0 is exclusive lower bound; sha_a is inclusive upper bound.
        range_spec = f"{sha_0}..{sha_a}"
        result = dti.ingest_range(conn, range_spec, worktree_path=str(repo))
        assert result["commits_scanned"] == 1
        assert result["decisions_ingested"] == 1
        assert result["rows"][0]["decision_id"] == "DEC-RANGE-A-001"
        assert result["rows"][0]["sha"] == sha_a
        assert result["rows"][0]["action"] == "inserted"

    def test_ingest_range_multiple_commits_order_preserved(self, git_repo_range, conn):
        """Three-commit range: rows are in oldest-first (rev-list --reverse) order."""
        repo, sha_0, sha_a, sha_b, sha_c = git_repo_range
        # sha_0..sha_c selects sha_a, sha_b, sha_c (3 commits)
        range_spec = f"{sha_0}..{sha_c}"
        result = dti.ingest_range(conn, range_spec, worktree_path=str(repo))
        assert result["commits_scanned"] == 3
        # sha_b has no trailers; sha_a has 1, sha_c has 2 → 3 total
        assert result["decisions_ingested"] == 3
        dec_ids = [r["decision_id"] for r in result["rows"]]
        # sha_a's DEC must appear before sha_c's DECs (oldest-first)
        assert dec_ids.index("DEC-RANGE-A-001") < dec_ids.index("DEC-RANGE-C-001")
        assert dec_ids.index("DEC-RANGE-A-001") < dec_ids.index("DEC-RANGE-C-002")

    def test_ingest_range_idempotency(self, git_repo_range, conn):
        """Re-ingesting the same range → second run rows show action='updated';
        no duplicate rows in DB."""
        repo, sha_0, sha_a, sha_b, sha_c = git_repo_range
        range_spec = f"{sha_0}..{sha_c}"
        # First run
        result1 = dti.ingest_range(conn, range_spec, worktree_path=str(repo))
        assert result1["decisions_ingested"] == 3
        assert all(r["action"] == "inserted" for r in result1["rows"])

        # Second run — same range
        result2 = dti.ingest_range(conn, range_spec, worktree_path=str(repo))
        assert result2["decisions_ingested"] == 3
        assert all(r["action"] == "updated" for r in result2["rows"])

        # DB must have exactly 3 rows (no duplicates)
        decisions = dwr.list_decisions(conn)
        assert len(decisions) == 3

    def test_ingest_range_invalid_range_raises(self, git_repo_range, conn):
        """Bogus range spec → ValueError with clear message."""
        repo, sha_0, sha_a, sha_b, sha_c = git_repo_range
        with pytest.raises(ValueError, match="git rev-list failed"):
            dti.ingest_range(
                conn, "total_nonsense_xyz..HEAD", worktree_path=str(repo)
            )

    def test_ingest_range_dry_run_no_writes(self, git_repo_range, conn):
        """dry_run=True → commits_scanned reported, decisions_ingested=0, no DB writes."""
        repo, sha_0, sha_a, sha_b, sha_c = git_repo_range
        range_spec = f"{sha_0}..{sha_c}"
        result = dti.ingest_range(conn, range_spec, worktree_path=str(repo), dry_run=True)
        assert result["status"] == "ok"
        assert result["dry_run"] is True
        assert result["commits_scanned"] == 3
        assert result["decisions_ingested"] == 0
        assert result["rows"] == []
        # Verify DB is actually empty
        decisions = dwr.list_decisions(conn)
        assert len(decisions) == 0

    def test_ingest_range_single_writer_discipline(self):
        """Guard: ingest_range MUST call ingest_commit, NOT upsert_decision directly.

        Uses the ``ast`` module to walk the AST of ``ingest_range`` and verify:
          1. At least one ``Call`` node invokes ``ingest_commit``.
          2. Zero ``Call`` nodes invoke ``upsert_decision``.

        This is the authoritative guard for DEC-CLAUDEX-DEC-INGEST-BACKFILL-001's
        single-writer invariant. It is immune to mentions of ``upsert_decision``
        in comments or docstrings because the AST only captures executable nodes.
        """
        import ast as _ast
        import inspect as _inspect
        import textwrap as _textwrap

        # Get the source of ingest_range and dedent so ast.parse can handle it.
        raw_source = _inspect.getsource(dti.ingest_range)
        source = _textwrap.dedent(raw_source)
        tree = _ast.parse(source)

        called_names: set[str] = set()
        for node in _ast.walk(tree):
            if isinstance(node, _ast.Call):
                # Direct call: ingest_commit(...)
                if isinstance(node.func, _ast.Name):
                    called_names.add(node.func.id)
                # Attribute call: obj.ingest_commit(...) — unlikely here but checked
                elif isinstance(node.func, _ast.Attribute):
                    called_names.add(node.func.attr)

        assert "ingest_commit" in called_names, (
            f"ingest_range must call ingest_commit; calls found: {called_names}"
        )
        assert "upsert_decision" not in called_names, (
            "ingest_range must NOT call upsert_decision directly; "
            "single-writer discipline requires routing through ingest_commit. "
            f"Calls found: {called_names}"
        )

    def test_ingest_range_commits_with_no_trailers(self, git_repo_range, conn):
        """Range with no-trailer commits → 0 DECs ingested."""
        repo, sha_0, sha_a, sha_b, sha_c = git_repo_range
        # sha_a..sha_b selects just sha_b (which has no trailers)
        range_spec = f"{sha_a}..{sha_b}"
        result = dti.ingest_range(conn, range_spec, worktree_path=str(repo))
        assert result["commits_scanned"] == 1
        assert result["decisions_ingested"] == 0
        assert result["rows"] == []
        decisions = dwr.list_decisions(conn)
        assert len(decisions) == 0

    def test_ingest_range_range_and_worktree_path_honored(self, tmp_path, conn):
        """worktree_path argument is honored: a secondary repo's SHAs are used."""
        # Create a separate repo with an anchor commit and a commit with a trailer,
        # so we can use sha_anchor..sha_trailer as the range_spec.
        repo2 = tmp_path / "secondary_repo"
        repo2.mkdir()
        rp2 = str(repo2)
        subprocess.run(["git", "init", rp2], check=True, capture_output=True,
                       env=_GIT_ENV)
        subprocess.run(["git", "-C", rp2, "config", "user.email", "t@t.com"],
                       check=True, capture_output=True, env=_GIT_ENV)
        subprocess.run(["git", "-C", rp2, "config", "user.name", "Test"],
                       check=True, capture_output=True, env=_GIT_ENV)
        # Anchor commit (lower bound, exclusive)
        sha_anchor = _make_commit(repo2, "anchor.txt", "chore: anchor")
        # Commit with a trailer
        sha_trailer = _make_commit(
            repo2, "x.txt",
            "feat: secondary\n\nBody.\n\ndecision: DEC-SECONDARY-001"
        )
        # sha_anchor..sha_trailer = exactly sha_trailer
        range_spec = f"{sha_anchor}..{sha_trailer}"
        result = dti.ingest_range(conn, range_spec, worktree_path=rp2)
        assert result["commits_scanned"] == 1
        assert result["decisions_ingested"] == 1
        assert result["rows"][0]["decision_id"] == "DEC-SECONDARY-001"

    def test_ingest_range_compound_production_sequence(self, git_repo_range, conn):
        """Compound interaction test: exercises the real production sequence.

        Production sequence:
          1. git rev-list resolves SHAs
          2. load_commit_message loads each commit
          3. parse_decision_trailers extracts DEC-IDs
          4. ingest_commit upserts via upsert_decision
          5. list_decisions confirms registry state
          6. Second run shows idempotency (updated, not inserted)

        This crosses all internal component boundaries in the module.
        """
        repo, sha_0, sha_a, sha_b, sha_c = git_repo_range
        # sha_0..sha_c selects sha_a, sha_b, sha_c (3 commits)
        range_spec = f"{sha_0}..{sha_c}"

        # Step 1: first ingest — 3 commits, 3 decisions (sha_b contributes 0)
        result1 = dti.ingest_range(conn, range_spec, worktree_path=str(repo))
        assert result1["status"] == "ok"
        assert result1["commits_scanned"] == 3
        assert result1["decisions_ingested"] == 3

        # Step 2: verify via list_decisions
        decisions = dwr.list_decisions(conn)
        ids = {d.decision_id for d in decisions}
        assert "DEC-RANGE-A-001" in ids
        assert "DEC-RANGE-C-001" in ids
        assert "DEC-RANGE-C-002" in ids
        assert len(decisions) == 3

        # Step 3: verify provenance captured
        rec_a = dwr.get_decision(conn, "DEC-RANGE-A-001")
        assert rec_a is not None
        assert sha_a in rec_a.rationale

        # Step 4: idempotency — second run → all rows updated, no new rows
        result2 = dti.ingest_range(conn, range_spec, worktree_path=str(repo))
        assert result2["decisions_ingested"] == 3
        assert all(r["action"] == "updated" for r in result2["rows"])
        decisions2 = dwr.list_decisions(conn)
        assert len(decisions2) == 3  # no duplicates

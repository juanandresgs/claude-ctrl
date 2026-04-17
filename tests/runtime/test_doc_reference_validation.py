"""Unit tests for runtime.core.doc_reference_validation.

Covers the validator shape and drift-detection behavior in isolation
using small in-memory markdown strings. Real-file pins for
``MASTER_PLAN.md`` and ``AGENTS.md`` live in
``test_doc_reference_real_files.py``.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from runtime.core.doc_reference_validation import (
    DriftReport,
    validate_doc_references,
    validate_doc_references_file,
)

REPO_ROOT = Path(__file__).resolve().parents[2]


# ---------------------------------------------------------------------------
# Empty / no-references baseline
# ---------------------------------------------------------------------------


class TestEmptyAndBaseline:
    def test_empty_string_is_healthy_with_zero_refs(self):
        report = validate_doc_references("")
        assert report.healthy is True
        assert report.references_checked == 0
        assert report.unknown_adapters == []
        assert report.unknown_events == []
        assert report.unknown_matchers == []

    def test_prose_without_hook_references_is_healthy(self):
        text = (
            "# A Doc About Something Else\n\n"
            "This file talks about markdown, git commits, and apples.\n"
            "It does not name any hook adapter or harness event.\n"
        )
        report = validate_doc_references(text)
        assert report.healthy is True
        assert report.references_checked == 0

    def test_path_field_is_preserved_in_report(self):
        report = validate_doc_references("noop", path="/some/path.md")
        assert report.path == "/some/path.md"

    def test_default_path_is_inline(self):
        report = validate_doc_references("noop")
        assert report.path == "<inline>"


# ---------------------------------------------------------------------------
# Adapter-path detection
# ---------------------------------------------------------------------------


class TestAdapterPathDetection:
    def test_valid_adapter_path_is_accepted(self):
        # hooks/pre-bash.sh is a live manifest adapter.
        text = "See `hooks/pre-bash.sh` for the pre-bash guard."
        report = validate_doc_references(text)
        assert report.healthy is True
        assert report.references_checked == 1
        assert report.unknown_adapters == []

    def test_undocumented_ghost_adapter_path_is_reported_as_drift(self):
        # A ghost name that is NOT in the manifest, NOT on disk, and
        # NOT in the retirement registry must be flagged.
        text = "Typo: `hooks/autoo-reviewww.sh` with extra letters."
        report = validate_doc_references(text)
        assert report.healthy is False
        assert "hooks/autoo-reviewww.sh" in report.unknown_adapters

    def test_known_retired_adapter_is_accepted_not_drift(self):
        # Documented retirement should NOT be drift.
        text = "Retired: `hooks/check-tester.sh` parsed TESTER_* trailers."
        report = validate_doc_references(text)
        assert report.healthy is True
        assert "hooks/check-tester.sh" not in report.unknown_adapters

    def test_duplicate_adapter_references_deduplicate_in_report(self):
        text = (
            "Line A references `hooks/ghost.sh`.\n"
            "Line B also references `hooks/ghost.sh`.\n"
        )
        report = validate_doc_references(text)
        assert report.unknown_adapters == ["hooks/ghost.sh"]

    def test_mixed_valid_and_ghost_adapter_references(self):
        text = (
            "The pre-bash guard is `hooks/pre-bash.sh` (valid) and a "
            "typo like `hooks/totally-made-up.sh` (ghost)."
        )
        report = validate_doc_references(text)
        assert report.healthy is False
        assert report.unknown_adapters == ["hooks/totally-made-up.sh"]
        # pre-bash.sh was not reported as drift.
        assert "hooks/pre-bash.sh" not in report.unknown_adapters


# ---------------------------------------------------------------------------
# Event-matcher detection
# ---------------------------------------------------------------------------


class TestEventMatcherDetection:
    def test_valid_event_matcher_pair_is_accepted(self):
        # PreToolUse:Bash is a live manifest entry.
        text = "The `PreToolUse:Bash` hook runs pre-bash.sh."
        report = validate_doc_references(text)
        assert report.healthy is True
        assert report.unknown_matchers == []
        assert report.unknown_events == []

    def test_retired_subagentstop_tester_matcher_is_drift(self):
        text = "Historically: `SubagentStop:tester` dispatched check-tester.sh."
        report = validate_doc_references(text)
        assert report.healthy is False
        assert ("SubagentStop", "tester") in report.unknown_matchers

    def test_unknown_event_is_reported(self):
        text = "Fake event: `NeverHeardOf:whatever` does not exist."
        report = validate_doc_references(text)
        assert report.healthy is False
        assert "NeverHeardOf" in report.unknown_events

    def test_pipe_matcher_with_all_known_alts_is_accepted(self):
        # manifest has SubagentStop with matcher 'planner|Plan';
        # reference "SubagentStop:planner|Plan" should validate.
        text = "The `SubagentStop:planner|Plan` matcher covers both aliases."
        report = validate_doc_references(text)
        assert ("SubagentStop", "planner|Plan") not in report.unknown_matchers
        assert report.healthy is True

    def test_pipe_matcher_with_unknown_alt_is_drift(self):
        # 'planner|ghost' — planner is valid, ghost is not: must be drift.
        text = "Broken alt: `SubagentStop:planner|ghost`."
        report = validate_doc_references(text)
        assert report.healthy is False
        assert ("SubagentStop", "planner|ghost") in report.unknown_matchers

    def test_duplicate_matcher_references_deduplicate_in_report(self):
        text = (
            "First: `SubagentStop:tester`.\n"
            "Again: `SubagentStop:tester`.\n"
        )
        report = validate_doc_references(text)
        # Only reported once.
        assert report.unknown_matchers == [("SubagentStop", "tester")]


# ---------------------------------------------------------------------------
# Retirement registry
# ---------------------------------------------------------------------------


class TestRetirementRegistry:
    """Documented retirements may legitimately appear in historical prose.

    A reference to a retired adapter or matcher must NOT be flagged as
    drift when the retirement is recorded in the registry. A ghost
    reference (typo, hallucination, undocumented retirement) that is not
    in the registry and not in the manifest and not on disk must still
    be flagged.
    """

    def test_documented_retired_adapter_is_accepted(self):
        # hooks/auto-review.sh — Phase 8 Slice 2 retirement.
        text = "Historically: `hooks/auto-review.sh` ran under PostToolUse:Write."
        report = validate_doc_references(text)
        # Not in unknown_adapters — retirement registry shields it.
        assert "hooks/auto-review.sh" not in report.unknown_adapters

    def test_documented_retired_matcher_is_accepted(self):
        # PreToolUse:EnterWorktree — Phase 8 Slice 3 retirement.
        text = "Historically: `PreToolUse:EnterWorktree` was declared."
        report = validate_doc_references(text)
        assert ("PreToolUse", "EnterWorktree") not in report.unknown_matchers
        assert "PreToolUse" not in report.unknown_events

    def test_undocumented_ghost_adapter_is_still_drift(self):
        # hooks/never-existed.sh — not in manifest, not on disk, not in
        # retirement registry.
        text = "Broken: `hooks/never-existed.sh`."
        report = validate_doc_references(text)
        assert "hooks/never-existed.sh" in report.unknown_adapters

    def test_retirement_sets_are_frozen(self):
        from runtime.core.doc_reference_validation import (
            RETIRED_ADAPTER_PATHS,
            RETIRED_EVENT_MATCHERS,
        )

        # Frozensets cannot be mutated accidentally at runtime.
        assert isinstance(RETIRED_ADAPTER_PATHS, frozenset)
        assert isinstance(RETIRED_EVENT_MATCHERS, frozenset)

    def test_no_retirement_entry_is_also_in_live_manifest(self):
        """Retirement registry must not double-count with live manifest.

        If a name appears in both RETIRED_ADAPTER_PATHS and
        HOOK_MANIFEST, the retirement record is wrong — the item isn't
        actually retired.
        """
        from runtime.core.doc_reference_validation import (
            RETIRED_ADAPTER_PATHS,
        )
        from runtime.core.hook_manifest import HOOK_MANIFEST

        live = {e.adapter_path for e in HOOK_MANIFEST}
        conflict = RETIRED_ADAPTER_PATHS & live
        assert conflict == set(), (
            f"retired adapters must not also appear in HOOK_MANIFEST: {conflict}"
        )


# ---------------------------------------------------------------------------
# Manifest is the sole vocabulary authority
# ---------------------------------------------------------------------------


class TestManifestIsSingleAuthority:
    def test_every_active_adapter_path_validates(self):
        """Pin: every active adapter_path in HOOK_MANIFEST must validate
        when referenced literally. Catches accidental validator regex
        regressions."""
        from runtime.core.hook_manifest import active_entries

        lines = [f"reference `{e.adapter_path}`" for e in active_entries()]
        text = "\n".join(lines)
        report = validate_doc_references(text)
        assert report.healthy is True, (
            f"validator must accept every active adapter path; "
            f"unknown={report.unknown_adapters}"
        )

    def test_every_active_event_matcher_validates(self):
        """Pin: every (event, matcher_alt) pair in HOOK_MANIFEST must
        validate when referenced literally."""
        from runtime.core.hook_manifest import active_entries

        refs = []
        for e in active_entries():
            if e.matcher == "":
                # Empty-matcher events are not syntactically "Event:matcher";
                # they are skipped by the extraction regex by design.
                continue
            for part in e.matcher.split("|"):
                refs.append(f"reference `{e.event}:{part}`")
        text = "\n".join(refs)
        report = validate_doc_references(text)
        assert report.healthy is True, (
            f"validator must accept every active event:matcher pair; "
            f"unknown_matchers={report.unknown_matchers}, "
            f"unknown_events={report.unknown_events}"
        )


# ---------------------------------------------------------------------------
# DriftReport shape
# ---------------------------------------------------------------------------


class TestDriftReportShape:
    def test_as_dict_is_json_serializable(self):
        report = DriftReport(
            path="/x.md",
            references_checked=2,
            unknown_adapters=["hooks/ghost.sh"],
            unknown_events=["NeverHeardOf"],
            unknown_matchers=[("SubagentStop", "tester")],
        )
        body = report.as_dict()
        # Tuples become lists for JSON serializability.
        assert body["unknown_matchers"] == [["SubagentStop", "tester"]]
        s = json.dumps(body, sort_keys=True)
        parsed = json.loads(s)
        assert parsed["healthy"] is False
        assert parsed["references_checked"] == 2

    def test_healthy_true_when_no_drift(self):
        report = DriftReport(path="/x.md", references_checked=5)
        assert report.healthy is True


# ---------------------------------------------------------------------------
# File-backed entry point
# ---------------------------------------------------------------------------


class TestValidateDocReferencesFile:
    def test_reads_from_disk_and_returns_report(self, tmp_path):
        p = tmp_path / "doc.md"
        p.write_text("good: `hooks/pre-bash.sh`\nbad: `hooks/ghost.sh`\n")
        report = validate_doc_references_file(p)
        assert report.healthy is False
        assert report.unknown_adapters == ["hooks/ghost.sh"]
        assert report.path == str(p)


# ---------------------------------------------------------------------------
# CLI adapter — `cc-policy doc ref-check <path>`
# ---------------------------------------------------------------------------


class TestCliDocRefCheck:
    """Invoke ``python3 runtime/cli.py doc ref-check <path>`` directly to
    avoid depending on the global ``cc-policy`` wrapper's PATH-resolved
    binary (which may live in a different repo checkout than this
    worktree)."""

    def _run(self, *args, cwd: Path | None = None) -> subprocess.CompletedProcess:
        import sys as _sys

        return subprocess.run(
            [_sys.executable, str(REPO_ROOT / "runtime" / "cli.py"), *args],
            capture_output=True,
            text=True,
            timeout=15,
            cwd=str(cwd or REPO_ROOT),
        )

    def test_ref_check_on_clean_doc_exits_zero(self, tmp_path):
        p = tmp_path / "clean.md"
        p.write_text("this file names zero hook surfaces\n")
        result = self._run("doc", "ref-check", str(p))
        assert result.returncode == 0, (
            f"clean doc must exit 0; rc={result.returncode}, "
            f"stdout={result.stdout!r}, stderr={result.stderr!r}"
        )
        body = json.loads(result.stdout)
        assert body["status"] == "ok"

    def test_ref_check_on_drifted_doc_exits_nonzero(self, tmp_path):
        p = tmp_path / "drift.md"
        p.write_text("ghost: `hooks/ghost.sh`\nbad matcher: `SubagentStop:tester`\n")
        result = self._run("doc", "ref-check", str(p))
        assert result.returncode != 0
        combined = result.stdout + result.stderr
        assert "hooks/ghost.sh" in combined
        assert "tester" in combined

    def test_ref_check_on_missing_path_returns_error(self, tmp_path):
        missing = tmp_path / "does-not-exist.md"
        result = self._run("doc", "ref-check", str(missing))
        assert result.returncode != 0
        combined = result.stdout + result.stderr
        assert "path not found" in combined or "not a file" in combined

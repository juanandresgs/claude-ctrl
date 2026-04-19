"""
Slice 21: Guardian-landing head_sha parity invariant.

@decision DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001:
    runtime.core.leases.validate_op gates Guardian landing ops on composite
    lease/evaluation head_sha parity:
      allow iff (lease.head_sha is None) OR
               (lease.head_sha == evaluation.head_sha AND
                evaluation.status == "ready_for_guardian")
    Prior to this slice, zero tests exercised a seeded dispatch_leases row
    AND a seeded evaluation_state row with explicit head_sha values in the
    same composite call to validate_op. Only empirically validated across 16
    consecutive landings where SHAs were always co-advanced by the canonical
    dispatch flow. This file mechanically locks the invariant via 8
    deterministic in-memory tests.

    Canonical parity gate location: runtime/core/leases.py line ~691:
      lease["head_sha"] is None or eval_state.get("head_sha") == lease["head_sha"]

    The strict == equality semantic at the lease layer is intentionally
    different from bash_eval_readiness._sha_prefix_match: any future unification
    of these two semantics must supersede this DEC, update T4, and ship as a
    decision-annotated bundle.

Status: accepted
"""

import sqlite3

import pytest

from runtime.schemas import ensure_schema
from runtime.core import leases
from runtime.core import evaluation as evaluation_mod
from runtime.core import approvals as approvals_mod


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    """Fresh in-memory SQLite connection with full runtime schema.

    DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: every test in this
    module receives an isolated in-memory DB so tests cannot interfere with
    one another via shared state.
    """
    c = sqlite3.connect(":memory:")
    c.row_factory = sqlite3.Row
    ensure_schema(c)
    yield c
    c.close()


# ---------------------------------------------------------------------------
# Seed helpers
# ---------------------------------------------------------------------------


def _seed_lease(
    conn,
    *,
    head_sha,
    allowed_ops,
    workflow_id="wf-21",
    worktree_path="/wt-21",
    requires_eval=True,
):
    """Issue a dispatch_leases row with the given head_sha + allowed_ops.

    Uses the canonical leases.issue() function so the row shape is
    identical to production Guardian lease issuance.
    """
    return leases.issue(
        conn,
        role="guardian",
        worktree_path=worktree_path,
        workflow_id=workflow_id,
        allowed_ops=allowed_ops,
        requires_eval=requires_eval,
        head_sha=head_sha,
        ttl=7200,
    )


def _seed_evaluation(
    conn,
    *,
    head_sha,
    status,
    workflow_id="wf-21",
):
    """Upsert an evaluation_state row for workflow_id with the given head_sha + status.

    Uses canonical evaluation.set_status() so the row shape is identical to
    production post-reviewer evaluator writes.
    """
    evaluation_mod.set_status(conn, workflow_id, status, head_sha=head_sha)


# ---------------------------------------------------------------------------
# T1 — Happy-path parity match (routine_local)
# ---------------------------------------------------------------------------


class TestHeadShaParityAllowPath:
    """Parity allows Guardian landing when lease.head_sha == evaluation.head_sha
    AND evaluation.status == 'ready_for_guardian'.

    DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: positive path.
    """

    def test_parity_match_allows_routine_local_landing(self, conn):
        """DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: positive path.

        Teeth: if a regression replaces == at leases.py:691 with != or drops
        the eval_ok=True assignment at leases.py:693, allowed becomes False
        and this test fires.
        """
        sha = "abc123def456" * 3  # 36-char deterministic test SHA
        _seed_lease(conn, head_sha=sha, allowed_ops=["routine_local"])
        _seed_evaluation(conn, head_sha=sha, status="ready_for_guardian")

        result = leases.validate_op(
            conn, "git commit -m 'land'", worktree_path="/wt-21"
        )

        assert result["allowed"] is True, f"expected allowed=True, got reason={result['reason']!r}"
        assert result["eval_ok"] is True, f"expected eval_ok=True, got {result['eval_ok']!r}"
        assert result["op_class"] == "routine_local"
        assert result["lease_id"] is not None
        assert result["requires_eval"] is True


# ---------------------------------------------------------------------------
# T2 — Parity mismatch deny (routine_local)
# T3 — Parity match allow (high_risk rebase)
# ---------------------------------------------------------------------------


class TestHeadShaParityDenyPath:
    """Parity denies Guardian landing when lease.head_sha != evaluation.head_sha
    for non-admin ops, even when evaluation.status is ready_for_guardian.

    DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: drift-catch.
    This is the primary regression target: if someone removes the
    eval_state.get("head_sha") == lease["head_sha"] conjunct at leases.py:691
    the parity check vanishes silently and Guardian can land on a stale verdict.
    T2 catches exactly that regression.
    """

    def test_parity_mismatch_denies_routine_local_landing(self, conn):
        """DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: drift-catch — mismatch.

        Seed lease SHA != eval SHA while eval status == ready_for_guardian.
        Must produce allowed=False, eval_ok=False.
        Reason must mention the readiness failure (not a different deny path).
        """
        lease_sha = "aaa111bbb222" * 3
        eval_sha = "ccc333ddd444" * 3  # different from lease_sha
        _seed_lease(conn, head_sha=lease_sha, allowed_ops=["routine_local"])
        _seed_evaluation(conn, head_sha=eval_sha, status="ready_for_guardian")

        result = leases.validate_op(
            conn, "git commit -m 'land'", worktree_path="/wt-21"
        )

        assert result["allowed"] is False, "mismatch SHA must deny landing"
        assert result["eval_ok"] is False, "eval_ok must be False on SHA mismatch"
        assert result["op_class"] == "routine_local"
        # Reason must surface the readiness/SHA failure context, not a different gate.
        reason = result["reason"].lower()
        assert any(
            token in reason
            for token in ["ready_for_guardian", "sha", "mismatch", "evaluation"]
        ), f"unexpected reason: {result['reason']!r}"

    def test_parity_match_allows_high_risk_rebase(self, conn):
        """DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: positive path — high_risk.

        Pins that requires_eval=True parity also gates approval-bearing high_risk
        ops. A regression that only checks parity on routine_local would miss this.
        """
        sha = "hhh111hhh222" * 3
        _seed_lease(
            conn,
            head_sha=sha,
            allowed_ops=["routine_local", "high_risk"],
            workflow_id="wf-21-hsr",
            worktree_path="/wt-21-hsr",
        )
        _seed_evaluation(
            conn, head_sha=sha, status="ready_for_guardian", workflow_id="wf-21-hsr"
        )
        # Grant approval token so high_risk rebase passes the approval gate.
        approvals_mod.grant(conn, "wf-21-hsr", op_type="rebase")

        result = leases.validate_op(
            conn, "git rebase main", worktree_path="/wt-21-hsr"
        )

        assert result["allowed"] is True, f"matched SHA + approval should allow rebase, got reason={result['reason']!r}"
        assert result["eval_ok"] is True
        assert result["op_class"] == "high_risk"
        assert result["approval_ok"] is True


# ---------------------------------------------------------------------------
# T4 — Prefix-semantic pin: strict equality, NOT prefix-match
# ---------------------------------------------------------------------------


class TestStrictEqualitySemanticPin:
    """Pins the CURRENT strict-equality semantic at the lease layer.

    DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: semantic pin.

    The bash_eval_readiness policy uses _sha_prefix_match, but validate_op
    uses strict == at leases.py:691. This divergence is intentional and
    must not be silently widened. If the two semantics are unified in the
    future, this test must be updated in the same commit and
    DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001 must be superseded.
    """

    def test_prefix_mismatch_denies_when_lease_sha_is_short_prefix_of_eval_sha(
        self, conn
    ):
        """DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: strict == semantic pin.

        lease.head_sha = "abc123" (12-char prefix)
        evaluation.head_sha = "abc123def456..." (same prefix but longer)

        Current semantic at leases.py:691 is strict ==, so this is a mismatch
        → allowed=False. If someone swaps == for a prefix-match helper without
        updating this DEC, the test fires and forces the change to be explicit.
        """
        short_sha = "abc123def456"           # 12 chars — a valid short SHA form
        full_sha = "abc123def456789012345678"  # longer, starts with short_sha prefix
        _seed_lease(conn, head_sha=short_sha, allowed_ops=["routine_local"])
        _seed_evaluation(conn, head_sha=full_sha, status="ready_for_guardian")

        result = leases.validate_op(
            conn, "git commit -m 'land'", worktree_path="/wt-21"
        )

        # Strict equality: short_sha != full_sha → denied at parity gate.
        assert result["allowed"] is False, (
            "strict == at leases.py:691 means prefix-only match must deny. "
            "If this assertion fails, the semantic has changed — update DEC and "
            "supersede DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001."
        )
        assert result["eval_ok"] is False


# ---------------------------------------------------------------------------
# T5 — Null lease.head_sha short-circuit
# ---------------------------------------------------------------------------


class TestHeadShaNullShortCircuit:
    """lease.head_sha IS NULL is the sole short-circuit bypassing parity comparison.

    DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: null-lease compatibility.

    Pins the `lease["head_sha"] is None or ...` branch at leases.py:691.
    If a refactor removes the null short-circuit (e.g., to enforce "lease must
    always carry head_sha"), this test fires and forces the change to be
    annotated as a DEC supersession.
    """

    def test_null_lease_head_sha_short_circuits_to_allow_when_status_ready(
        self, conn
    ):
        """DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: null short-circuit.

        Seed: lease.head_sha=None (legacy-shape lease without pinned SHA).
        Evaluation has a real head_sha + status=ready_for_guardian.
        Expected: allowed=True, eval_ok=True.
        The parity comparison is skipped entirely when lease.head_sha is None.
        """
        _seed_lease(conn, head_sha=None, allowed_ops=["routine_local"])
        _seed_evaluation(conn, head_sha="xyz789abc012", status="ready_for_guardian")

        result = leases.validate_op(
            conn, "git commit -m 'land'", worktree_path="/wt-21"
        )

        assert result["allowed"] is True, (
            f"null lease.head_sha must short-circuit parity check to allow. "
            f"Got reason={result['reason']!r}"
        )
        assert result["eval_ok"] is True


# ---------------------------------------------------------------------------
# T6 — Status gate: parity match + wrong status → deny
# ---------------------------------------------------------------------------


class TestEvaluationStatusGate:
    """evaluation.status == 'ready_for_guardian' is required even when SHAs match.

    DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: status-interaction pin.

    Pins that SHA parity alone is insufficient — the conjunction at leases.py:690
    requires BOTH parity AND status=ready_for_guardian. A regression that weakens
    the status check (e.g., accepts 'pending') fires this test.
    """

    def test_parity_match_but_status_pending_denies(self, conn):
        """DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: status-gate.

        SHAs match but status=pending — must deny.
        The status check is the primary gate; parity only matters inside it.
        """
        sha = "aaa111bbb222" * 3
        _seed_lease(conn, head_sha=sha, allowed_ops=["routine_local"])
        _seed_evaluation(conn, head_sha=sha, status="pending")

        result = leases.validate_op(
            conn, "git commit -m 'land'", worktree_path="/wt-21"
        )

        assert result["allowed"] is False, "pending status must deny even with matching SHA"
        assert result["eval_ok"] is False


# ---------------------------------------------------------------------------
# T7 — Vacuous-truth guard: no evaluation row at all
# ---------------------------------------------------------------------------


class TestVacuousTruthGuard:
    """No evaluation_state row for workflow → eval_ok=False, allowed=False.

    DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: vacuous-truth guard.

    Ensures T1-T6 are NOT vacuously green. If seeding logic accidentally always
    produced allowed=True, this test would fail because it shares the same
    fixture topology but omits the evaluation row. Direct logical overlap with
    test_validate_op_routine_landing_still_requires_eval in test_leases.py —
    if that test ever silently weakens, this one still enforces deny.
    """

    def test_no_evaluation_row_yields_eval_ok_false(self, conn):
        """DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: no eval row deny.

        Seed: lease with requires_eval=True and workflow_id, but NO evaluation_state
        row for that workflow_id. Must deny because eval_state is None and the
        conditional at leases.py:689-692 requires eval_state is not None.
        """
        _seed_lease(
            conn,
            head_sha="somesha12345",
            allowed_ops=["routine_local"],
            workflow_id="wf-21-noeval",
            worktree_path="/wt-21-noeval",
        )
        # Deliberately do NOT seed an evaluation row.

        result = leases.validate_op(
            conn, "git commit -m 'land'", worktree_path="/wt-21-noeval"
        )

        assert result["allowed"] is False, "missing eval row must deny"
        assert result["eval_ok"] is False
        reason = result["reason"].lower()
        assert "ready_for_guardian" in reason, (
            f"denial reason should mention ready_for_guardian. Got: {result['reason']!r}"
        )

    def test_dispatch_leases_and_evaluation_state_tables_exist(self, conn):
        """DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: schema guard.

        Verifies ensure_schema() creates both tables that the parity gate
        depends on. If either table is dropped or renamed, validate_op would
        fail at runtime in a way that wouldn't be caught until production.
        """
        tables = {
            r[0]
            for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        assert "dispatch_leases" in tables, "dispatch_leases table must exist"
        assert "evaluation_state" in tables, "evaluation_state table must exist"

    def test_validate_op_is_callable(self):
        """DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: import guard.

        Pins that validate_op is importable and callable. If the function is
        renamed or moved, this test fires immediately, making the breakage
        explicit rather than silent.
        """
        assert callable(leases.validate_op)


# ---------------------------------------------------------------------------
# T8 — Admin recovery exemption non-weakening
# ---------------------------------------------------------------------------


class TestAdminRecoveryExemption:
    """Admin recovery ops are exempt from the head_sha parity gate.

    DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: admin-recovery exemption.

    Pins that admin_recovery (git merge --abort, git reset --merge) is
    intentionally exempt from the eval/parity gate because these are governed
    administrative recovery operations — there is no feature to evaluate.
    The exemption is at leases.py:684:
      if lease["requires_eval"] and op_class not in ("unclassified", "admin_recovery"):

    If a refactor that "unifies the eval check" removes the admin_recovery
    exemption, this test fires and prevents silent tightening.
    """

    def test_admin_recovery_exempt_from_parity_even_with_mismatch(self, conn):
        """DEC-CLAUDEX-GUARDIAN-LANDING-HEAD-SHA-PARITY-001: admin-recovery exemption.

        Seed: lease.head_sha="aaa" + eval.head_sha="zzz" (mismatch) + eval.status=pending
        (doubly-wrong: mismatched AND not ready_for_guardian).
        Also grant an admin_recovery approval token (required by the approval gate
        even though the eval gate is skipped).

        Command: "git merge --abort" (classified as admin_recovery by classify_git_op).

        Expected: allowed=True, eval_ok=None (eval check skipped entirely).
        The admin_recovery exemption applies because op_class == "admin_recovery".
        """
        lease_sha = "aaa111bbb222" * 3
        eval_sha = "zzz999yyy888" * 3  # mismatch
        _seed_lease(
            conn,
            head_sha=lease_sha,
            allowed_ops=["routine_local", "admin_recovery"],
            workflow_id="wf-21-ar",
            worktree_path="/wt-21-ar",
        )
        _seed_evaluation(
            conn, head_sha=eval_sha, status="pending", workflow_id="wf-21-ar"
        )
        # Admin recovery still requires an approval token per leases.py:711-714.
        approvals_mod.grant(conn, "wf-21-ar", op_type="admin_recovery")

        result = leases.validate_op(
            conn, "git merge --abort", worktree_path="/wt-21-ar"
        )

        assert result["allowed"] is True, (
            f"admin_recovery must be exempt from parity check. "
            f"Got reason={result['reason']!r}"
        )
        assert result["eval_ok"] is None, (
            "eval_ok must be None (eval check entirely skipped) for admin_recovery"
        )
        assert result["op_class"] == "admin_recovery"

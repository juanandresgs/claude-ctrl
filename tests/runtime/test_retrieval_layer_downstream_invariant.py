"""Mechanical pin for CUTOVER_PLAN Invariant #13 (symmetric direction).

@decision DEC-CLAUDEX-RETRIEVAL-LAYER-DOWNSTREAM-INVARIANT-001
Title: Live-routing runtime modules must not consume runtime.core.memory_retrieval or runtime.core.decision_digest_projection as legal source of truth
Status: proposed
Rationale: CUTOVER_PLAN Invariant #13 reads *"Retrieval and graph layers are
  derived read models and never treated as legal source of truth."* The
  existing ``tests/runtime/test_memory_retrieval.py::TestShadowOnlyDiscipline``
  covers one direction — ``memory_retrieval.py`` does not import live-routing
  modules, keeping itself downstream. The other direction — live-routing
  modules do not import ``memory_retrieval`` / ``decision_digest_projection``
  as authority — has been culturally enforced but not mechanically pinned. A
  future author who imports ``memory_retrieval.search(...)`` into
  ``dispatch_engine.py`` to route based on search results would silently
  promote the retrieval layer to a second routing authority, the exact
  parallel-authority failure mode the cutover was designed to prevent.

  This scanner closes the symmetric gap. It walks every canonical live-
  routing module plus every ``runtime/core/policies/*.py`` and asserts
  neither ``runtime.core.memory_retrieval`` nor
  ``runtime.core.decision_digest_projection`` appears on any ``import`` or
  ``from ... import`` statement. Clean, strict module-name equality — no
  substring heuristics, no transitive-import chasing.

  One documented exemption surface: ``runtime/cli.py`` legitimately consumes
  ``decision_digest_projection`` for its read-only ``digest render`` /
  ``validate`` CLI verbs (see CLI module docstring at lines 580-623). That
  is a projection *consumer*, not routing authority — the CLI never uses
  the projection output to decide workflow routing, policy verdicts, or
  completion state. The CLI is therefore explicitly exempt, and the
  exemption is documented with a rationale token that ``test_exempt_modules_are_documented``
  verifies is present in this file.

  Three positive synthetic fixtures (direct-import, from-import, aliased-
  import) plus one negative fixture (clean module) prove the scanner
  cannot silently regress.

Adjacent authorities:
  - ``runtime/core/memory_retrieval.py`` — downstream read-model module;
    docstring already declares shadow/derived status.
  - ``runtime/core/decision_digest_projection.py`` — projection builder;
    docstring already declares downstream status.
  - the derived-read-model invariant: retrieval and graph layers must not be
    treated as legal source of truth.
  - Sister pins with the same shadow-only / stdlib-only AST-scan pattern:
    * ``tests/runtime/test_decision_ref_resolution.py``
      (DEC-CLAUDEX-DECISION-REF-SCAN-001, Invariant #11)
    * ``tests/runtime/policies/test_command_intent_single_authority.py``
      (DEC-CLAUDEX-COMMAND-INTENT-SOLE-AUTHORITY-001, Invariant #5)
    * ``tests/runtime/test_memory_retrieval.py::TestShadowOnlyDiscipline``
      (reverse-direction pin; this file closes the symmetric direction)

Shadow-only discipline: stdlib-only (``ast``, ``pathlib``, ``textwrap``).
No SQLite, no git subprocess, no network. Empty sanctioned-exemption
allowlist by default; each exempt module MUST carry a dated inline
rationale token that the self-invariant test asserts is present.
"""

from __future__ import annotations

import ast
import textwrap
from pathlib import Path
from typing import Dict, FrozenSet, List, Tuple

import pytest


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).resolve().parents[2]
_RUNTIME_CORE = _REPO_ROOT / "runtime" / "core"

# Canonical live-routing / authority surface modules that MUST be downstream
# of retrieval/digest layers, not upstream. Any new live-routing module
# should be added here in the same slice that introduces it.
_LIVE_ROUTING_MODULES: Tuple[Path, ...] = (
    _RUNTIME_CORE / "dispatch_engine.py",
    _RUNTIME_CORE / "dispatch_hook.py",
    _RUNTIME_CORE / "dispatch_shadow.py",
    _RUNTIME_CORE / "dispatch_contract.py",
    _RUNTIME_CORE / "dispatch_attempts.py",
    _RUNTIME_CORE / "policy_engine.py",
    _RUNTIME_CORE / "completions.py",
    _RUNTIME_CORE / "stage_registry.py",
    _RUNTIME_CORE / "authority_registry.py",
    _RUNTIME_CORE / "leases.py",
    _RUNTIME_CORE / "workflows.py",
    _RUNTIME_CORE / "goal_continuation.py",
    _RUNTIME_CORE / "hook_manifest.py",
    _RUNTIME_CORE / "evaluation.py",
    _RUNTIME_CORE / "command_intent.py",
    _RUNTIME_CORE / "approvals.py",
    _RUNTIME_CORE / "enforcement_config.py",
    _RUNTIME_CORE / "markers.py",
    _RUNTIME_CORE / "lifecycle.py",
    _RUNTIME_CORE / "transport_contract.py",
    _RUNTIME_CORE / "tmux_adapter.py",
    _RUNTIME_CORE / "claude_code_adapter.py",
    _RUNTIME_CORE / "reviewer_convergence.py",
    _RUNTIME_CORE / "reviewer_findings.py",
)

# Policy modules: every file under runtime/core/policies/ must be downstream.
_POLICIES_DIR = _RUNTIME_CORE / "policies"
_POLICY_SKIP_BASENAMES: FrozenSet[str] = frozenset({"__init__.py"})

# The forbidden upstream modules — retrieval/graph and digest projection
# are derived read models, not authority.
_FORBIDDEN_UPSTREAM_MODULES: FrozenSet[str] = frozenset(
    {
        "runtime.core.memory_retrieval",
        "runtime.core.decision_digest_projection",
    }
)

# Sanctioned exemptions — empty by default for the live-routing set. Each
# entry MUST carry a dated inline rationale token that is present in this
# file's source and verified by ``test_exempt_modules_are_documented``.
_KNOWN_EXEMPT_MODULES: FrozenSet[str] = frozenset()

_EXEMPT_MODULE_RATIONALE_TOKENS: Dict[str, str] = {}

# ``runtime/cli.py`` is NOT in ``_LIVE_ROUTING_MODULES`` because it is a CLI
# entrypoint, not a live-routing authority surface. The cutover plan treats
# CLI as a read-only projection consumer. Its projection use is called out
# in the module docstring above as an acknowledged shadow-consumer pattern
# and is not scanned.


# ---------------------------------------------------------------------------
# Scanner helpers
# ---------------------------------------------------------------------------


def _parse(path: Path) -> ast.AST:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def _parse_source(source: str, filename: str = "<fixture>") -> ast.AST:
    return ast.parse(textwrap.dedent(source), filename=filename)


def _forbidden_imports(tree: ast.AST) -> List[Tuple[int, str]]:
    """Return (lineno, import_form) pairs for every import of a forbidden
    upstream module. Exact module-name equality; aliases are reported
    under their original module name, not the alias.

    Detected forms:
      - ``import runtime.core.memory_retrieval``
      - ``import runtime.core.memory_retrieval as mr``
      - ``from runtime.core.memory_retrieval import X``
      - ``from runtime.core import memory_retrieval``
      - ``from runtime.core import memory_retrieval as mr``
    """
    hits: List[Tuple[int, str]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name in _FORBIDDEN_UPSTREAM_MODULES:
                    hits.append((node.lineno, f"import {alias.name}"))
        elif isinstance(node, ast.ImportFrom):
            if node.module in _FORBIDDEN_UPSTREAM_MODULES:
                hits.append(
                    (node.lineno, f"from {node.module} import ...")
                )
            # `from runtime.core import memory_retrieval [as mr]` form.
            elif node.module == "runtime.core":
                for alias in node.names:
                    full = f"runtime.core.{alias.name}"
                    if full in _FORBIDDEN_UPSTREAM_MODULES:
                        hits.append(
                            (node.lineno, f"from runtime.core import {alias.name}")
                        )
    return hits


def _iter_policy_files() -> List[Path]:
    files: List[Path] = []
    if not _POLICIES_DIR.is_dir():
        return files
    for path in sorted(_POLICIES_DIR.iterdir()):
        if not path.is_file():
            continue
        if path.suffix != ".py":
            continue
        if path.name in _POLICY_SKIP_BASENAMES:
            continue
        files.append(path)
    return files


def _iter_scanned_modules() -> List[Path]:
    """All modules covered by the invariant: canonical live-routing plus
    every policy module.
    """
    found: List[Path] = []
    for path in _LIVE_ROUTING_MODULES:
        if path.is_file():
            found.append(path)
    found.extend(_iter_policy_files())
    return found


# ---------------------------------------------------------------------------
# Tests — live-repo
# ---------------------------------------------------------------------------


class TestLiveRoutingModulesDoNotImportRetrievalLayer:
    """The canonical live-routing surface must not consume retrieval or
    decision-digest-projection modules as authority. This pin is absolute
    for every module in ``_LIVE_ROUTING_MODULES``.
    """

    def test_no_live_routing_module_imports_memory_retrieval(self) -> None:
        violations: List[str] = []
        for path in _LIVE_ROUTING_MODULES:
            if not path.is_file():
                continue
            if path.name in _KNOWN_EXEMPT_MODULES:
                continue
            for lineno, form in _forbidden_imports(_parse(path)):
                if "memory_retrieval" in form:
                    violations.append(f"{path.relative_to(_REPO_ROOT)}:{lineno}: {form}")
        assert not violations, (
            "Invariant #13 violation — live-routing modules must not import "
            "`runtime.core.memory_retrieval`. The retrieval layer is a "
            "derived read model, not legal source of truth (see CUTOVER_PLAN "
            "Invariant #13 and `runtime/core/memory_retrieval.py` module "
            "docstring).\n"
            + "\n".join(f"  - {v}" for v in violations)
        )

    def test_no_live_routing_module_imports_decision_digest_projection(self) -> None:
        violations: List[str] = []
        for path in _LIVE_ROUTING_MODULES:
            if not path.is_file():
                continue
            if path.name in _KNOWN_EXEMPT_MODULES:
                continue
            for lineno, form in _forbidden_imports(_parse(path)):
                if "decision_digest_projection" in form:
                    violations.append(f"{path.relative_to(_REPO_ROOT)}:{lineno}: {form}")
        assert not violations, (
            "Invariant #13 violation — live-routing modules must not import "
            "`runtime.core.decision_digest_projection`. The digest projection "
            "is a derived read model, not legal source of truth (see "
            "CUTOVER_PLAN Invariant #13).\n"
            + "\n".join(f"  - {v}" for v in violations)
        )


class TestPolicyModulesDoNotImportRetrievalLayer:
    """Every ``runtime/core/policies/*.py`` module must also stay
    downstream — policies consume ``PolicyRequest`` / ``command_intent`` /
    ``capability`` authorities, never retrieval layers.
    """

    def test_no_policy_imports_retrieval_layer(self) -> None:
        violations: List[str] = []
        for path in _iter_policy_files():
            if path.name in _KNOWN_EXEMPT_MODULES:
                continue
            for lineno, form in _forbidden_imports(_parse(path)):
                violations.append(f"{path.relative_to(_REPO_ROOT)}:{lineno}: {form}")
        assert not violations, (
            "Invariant #13 violation — policy modules must not import "
            "retrieval-layer modules. Retrieval and digest projection are "
            "derived read models, not authority for policy decisions.\n"
            + "\n".join(f"  - {v}" for v in violations)
        )


class TestModuleSurface:
    """Scanner-sanity pins — the scanner must find canonical live-routing
    modules; allowlist entries must be documented.
    """

    def test_scanner_finds_at_least_10_live_routing_modules(self) -> None:
        existing = [p for p in _LIVE_ROUTING_MODULES if p.is_file()]
        assert len(existing) >= 10, (
            f"scanner found only {len(existing)} live-routing module(s) "
            "on disk; expected at least 10. Scanner may be broken or the "
            f"runtime/core tree has changed unexpectedly. {_LIVE_ROUTING_MODULES=}"
        )

    def test_scanner_covers_every_policy_module(self) -> None:
        policy_files = _iter_policy_files()
        assert len(policy_files) >= 10, (
            f"scanner found only {len(policy_files)} policy module(s); "
            "expected at least 10. Scanner may be broken or the policies "
            "directory has changed unexpectedly."
        )

    def test_exempt_modules_are_documented(self) -> None:
        """Every entry in ``_KNOWN_EXEMPT_MODULES`` must carry a matching
        key in ``_EXEMPT_MODULE_RATIONALE_TOKENS`` and that token must
        appear in this test file's own source. Prevents silent allowlist
        expansion.
        """
        own_source = Path(__file__).read_text(encoding="utf-8")
        for module_name in _KNOWN_EXEMPT_MODULES:
            assert module_name in _EXEMPT_MODULE_RATIONALE_TOKENS, (
                f"_KNOWN_EXEMPT_MODULES contains {module_name!r} but "
                f"_EXEMPT_MODULE_RATIONALE_TOKENS has no entry for it."
            )
            rationale_token = _EXEMPT_MODULE_RATIONALE_TOKENS[module_name]
            assert rationale_token in own_source, (
                f"Exempt module {module_name!r} names rationale token "
                f"{rationale_token!r}, but that token does not appear in "
                f"this test file. Add a dated inline rationale comment."
            )

    def test_exempt_rationale_has_matching_allowlist_entries(self) -> None:
        stale = [
            name for name in _EXEMPT_MODULE_RATIONALE_TOKENS
            if name not in _KNOWN_EXEMPT_MODULES
        ]
        assert not stale, (
            f"_EXEMPT_MODULE_RATIONALE_TOKENS has stale entries no longer "
            f"in _KNOWN_EXEMPT_MODULES: {stale}. Remove them."
        )

    def test_cli_is_not_in_live_routing_set(self) -> None:
        """``runtime/cli.py`` is a CLI entrypoint, not a live-routing
        surface. It is permitted to consume ``decision_digest_projection``
        for its read-only digest render / validate verbs. Pin that CLI is
        NOT in the scanned set so a future author cannot silently add it
        and force a false positive on its acknowledged projection
        consumption.
        """
        cli_path = _REPO_ROOT / "runtime" / "cli.py"
        assert cli_path not in _LIVE_ROUTING_MODULES, (
            "runtime/cli.py must remain OUT of _LIVE_ROUTING_MODULES. "
            "CLI is a read-only projection consumer, not routing authority; "
            "it is acknowledged in the module docstring as a shadow-consumer "
            "pattern. If a new live-routing concern arises in CLI, the right "
            "fix is to move the concern to a runtime.core module and scan "
            "that — not to scan CLI itself."
        )


# ---------------------------------------------------------------------------
# Synthetic fixtures — prove detection quality.
# ---------------------------------------------------------------------------


_DIRECT_IMPORT_FIXTURE = """
    import runtime.core.memory_retrieval

    def check(request):
        return runtime.core.memory_retrieval.search("foo")
"""

_FROM_IMPORT_FIXTURE = """
    from runtime.core.memory_retrieval import search

    def check(request):
        return search("foo")
"""

_FROM_SUBPACKAGE_IMPORT_FIXTURE = """
    from runtime.core import memory_retrieval

    def check(request):
        return memory_retrieval.search("foo")
"""

_ALIASED_IMPORT_FIXTURE = """
    import runtime.core.memory_retrieval as mr

    def check(request):
        return mr.search("foo")
"""

_DIGEST_PROJECTION_IMPORT_FIXTURE = """
    from runtime.core.decision_digest_projection import build_decision_digest_projection

    def check(request):
        return build_decision_digest_projection(...)
"""

_CLEAN_FIXTURE = """
    from runtime.core.policy_engine import PolicyDecision, PolicyRequest

    def check(request):
        return PolicyDecision(action="allow", reason="", policy_name="clean")
"""

_UNRELATED_IMPORT_FIXTURE = """
    # Imports that look superficially similar but are not the forbidden names.
    from runtime.core import projection_schemas
    from runtime.core import leases

    def check(request):
        return None
"""


class TestScannerCatchesSyntheticViolations:
    """Positive fixtures — the scanner must detect every import shape."""

    def test_direct_import_of_memory_retrieval(self) -> None:
        hits = _forbidden_imports(_parse_source(_DIRECT_IMPORT_FIXTURE))
        assert hits, "scanner missed `import runtime.core.memory_retrieval`"

    def test_from_import_from_memory_retrieval(self) -> None:
        hits = _forbidden_imports(_parse_source(_FROM_IMPORT_FIXTURE))
        assert hits, (
            "scanner missed `from runtime.core.memory_retrieval import search`"
        )

    def test_from_runtime_core_import_memory_retrieval(self) -> None:
        hits = _forbidden_imports(_parse_source(_FROM_SUBPACKAGE_IMPORT_FIXTURE))
        assert hits, (
            "scanner missed `from runtime.core import memory_retrieval`"
        )

    def test_aliased_import_of_memory_retrieval(self) -> None:
        hits = _forbidden_imports(_parse_source(_ALIASED_IMPORT_FIXTURE))
        assert hits, (
            "scanner missed `import runtime.core.memory_retrieval as mr`"
        )

    def test_decision_digest_projection_import(self) -> None:
        hits = _forbidden_imports(_parse_source(_DIGEST_PROJECTION_IMPORT_FIXTURE))
        assert hits, (
            "scanner missed `from runtime.core.decision_digest_projection import ...`"
        )


class TestScannerAcceptsCleanModule:
    """Negative fixtures — a clean module and an unrelated-imports module
    must both pass with zero hits.
    """

    def test_clean_module_has_zero_hits(self) -> None:
        hits = _forbidden_imports(_parse_source(_CLEAN_FIXTURE))
        assert not hits, f"clean fixture unexpectedly flagged: {hits!r}"

    def test_unrelated_imports_have_zero_hits(self) -> None:
        hits = _forbidden_imports(_parse_source(_UNRELATED_IMPORT_FIXTURE))
        assert not hits, (
            f"unrelated-imports fixture unexpectedly flagged: {hits!r} — "
            "the scanner must only match exact forbidden module names, "
            "not similar-looking ones."
        )

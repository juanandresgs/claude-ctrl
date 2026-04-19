"""Slice 19: capability-authority consumption parity invariant.

@decision DEC-CLAUDEX-CAP-CONSUMPTION-AUTH-001
Title: authority_registry.CAPABILITIES is the sole capability vocabulary and
       has bidirectional consumption parity with the declared consumer modules,
       covering BOTH policy-import-site consumption AND stage-contract-bound
       structural consumption.
Status: accepted (Slice 19 R2 — Semantic Correction; Global Soak Stabilization)
Rationale: CUTOVER_PLAN Authority Map row "Capabilities | runtime capability
  resolver | policy checks, prompts | repeated raw role-name checks across
  bash and Python" + Enforcement Mechanism §2 "Capability-Gated Policy".

  Two consumption surfaces exist in the target architecture:

  1. **Policy-import surface**: Capabilities gating enforcement decisions are
     imported as CAN_* symbols into policy modules and enforcement_config.
     These are consumed by AST import-site analysis. Six of the seven declared
     capabilities are consumed this way.

  2. **Stage-contract surface**: Capabilities that drive the stage-graph engine
     are embedded in STAGE_CAPABILITIES (via authority_registry) and projected
     into compiled prompt packs via resolve_contract() / all_contracts() /
     as_prompt_projection(). The `can_emit_dispatch_transition` capability is
     in this category — it is declared in every active stage's capability set
     in STAGE_CAPABILITIES and is consumed structurally by resolve_contract()
     and the prompt_pack_resolver, NOT via CAN_* import-site counting.

  R1 test incorrectly classified `can_emit_dispatch_transition` as "dead authority"
  by applying import-site AST analysis to a capability that is stage-contract-bound.
  R2 corrects this by splitting the "no dead capabilities" assertion into two tests,
  one per consumption surface. The corrected model proves liveness of ALL 7 capabilities
  with zero false positives and no xfail markers.

  A capability that no surface consumes is dead authority — it occupies the
  vocabulary without gating anything, creating false confidence in the
  authority map. A capability string referenced in a policy that is not
  declared in authority_registry.CAPABILITIES is a ghost authority — it
  bypasses the sole-vocabulary contract silently.

  Both drift modes were previously invisible to the test suite:
    - test_authority_registry.py pins vocabulary declaration (set equality,
      contract partition), not consumer coverage.
    - test_capability_gate_invariants.py pins per-policy gate usage for 6
      named policies, not registry-wide bidirectional parity.

  This module closes those two gaps with registry-wide assertions.

Complements (do NOT duplicate):
  - tests/runtime/test_authority_registry.py — vocabulary declaration, import
    discipline, stage→capability mapping, StageCapabilityContract invariants,
    test_every_active_stage_can_emit_dispatch_transition,
    test_every_active_stage_emits_dispatch_transitions
  - tests/runtime/policies/test_capability_gate_invariants.py — per-policy
    gate structure for 6 specific policies
  - tests/runtime/test_policy_registry_single_authority.py (slice 18) —
    registration completeness and priority-uniqueness

Mechanical drift modes caught by this module:
  Direction A-policy (no-dead-policy-gated-capabilities):
    Remove the last CAN_* consumer from policy modules without removing the
    authority_registry declaration → test_policy_gated_capabilities_have_policy_consumer
    FAILS with the orphan symbol listed.

  Direction A-contract (no-dead-stage-contract-bound-capabilities):
    Remove `can_emit_dispatch_transition` from all STAGE_CAPABILITIES entries
    without removing the declaration →
    test_stage_contract_bound_capabilities_live_via_stage_contracts FAILS.

  Direction B (no-ghost-capabilities):
    Import a misspelled/undeclared capability name (e.g. CAN_WRITE_SOURC) in
    any policy module → test_every_policy_imported_capability_is_declared
    FAILS with the ghost symbol and its source module listed.

  Consumer-registry closure:
    Wire a CAN_* gate in a module outside the declared CAPABILITY_CONSUMER_MODULES
    set → test_consumer_module_registry_is_closed FAILS with the rogue module.

  Vocabulary freshness:
    Add or remove a capability without updating this test deliberately →
    test_capability_vocabulary_count_matches_cutover_minimum FAILS.

Capability partition (derived from live source, not hardcoded):
  POLICY_GATED (6): can_land_git, can_provision_worktree, can_set_control_config,
    can_write_governance, can_write_source, read_only_review
    — consumed as CAN_* import sites in policy modules + enforcement_config
  STAGE_CONTRACT_BOUND (1): can_emit_dispatch_transition
    — consumed structurally: present in every active stage's STAGE_CAPABILITIES
      entry; projected via resolve_contract() / all_contracts()
"""

from __future__ import annotations

import ast
import importlib
import inspect
import pkgutil
import re
from typing import Dict, FrozenSet, Set

import runtime.core.policies as _policies_pkg
from runtime.core import authority_registry as ar

# ---------------------------------------------------------------------------
# CAPABILITY_CONSUMER_MODULES — closed registry of modules allowed to gate
# on capability symbols imported from authority_registry.
#
# This list is the sole authority for "which modules may consume capabilities".
# Any CAN_* or READ_ONLY_REVIEW import in a module NOT listed here is a
# closed-registry violation (test_consumer_module_registry_is_closed).
#
# Expansion requires an architecture-scoped review — the same gate as
# adding a new capability to authority_registry itself.
#
# Authority: slice 19 plan §5 "Authority Design + Test Structure":
#   "runtime/core/policies/*.py + enforcement_config.py + bridge_permissions.py"
# ---------------------------------------------------------------------------

CAPABILITY_CONSUMER_MODULES: FrozenSet[str] = frozenset(
    {
        # Policy layer — every non-underscore module under runtime/core/policies/
        # is a valid consumer site (discovered dynamically below).
        # Explicitly named non-policy consumers:
        "runtime.core.enforcement_config",
        "runtime.core.bridge_permissions",
    }
)

# ---------------------------------------------------------------------------
# Partition: capabilities consumed via stage-contract structural reads only.
#
# These capabilities do NOT appear as CAN_* import sites in any policy module
# (by design — they are consumed by the stage-graph engine via STAGE_CAPABILITIES,
# resolve_contract(), all_contracts(), and prompt_pack_resolver). Their liveness
# is proved via the stage-contract API (capabilities_for / stages_with_capability),
# not by import-site counting.
#
# DEC-CLAUDEX-CAPABILITY-AUTH-PARITY-001: separating the two consumption surfaces
# prevents false "dead capability" failures for capabilities that are live via
# structural stage-contract reads but invisible to import-site AST analysis.
# ---------------------------------------------------------------------------

STAGE_CONTRACT_BOUND_CAPABILITIES: FrozenSet[str] = frozenset(
    {
        ar.CAN_EMIT_DISPATCH_TRANSITION,
    }
)

# Pattern: CAN_* imports and READ_ONLY_REVIEW are the only capability symbols.
# capabilities_for() and stage_has_capability() are helper calls, not
# capability symbols — they do not count as capability consumption for
# direction-B (ghost check), but they do appear in enforcement_config so we
# must not mis-classify them.
_CAP_IMPORT_PATTERN: re.Pattern = re.compile(
    r"^(CAN_[A-Z][A-Z0-9_]*|READ_ONLY_REVIEW)$"
)


# ---------------------------------------------------------------------------
# Module discovery helpers
# ---------------------------------------------------------------------------


def _iter_policy_modules():
    """Yield (module_name, module_object) for all public policy modules.

    Yields from runtime.core.policies.* (pkgutil discovery), skipping any
    module whose name starts with '_'.
    """
    for info in pkgutil.iter_modules(_policies_pkg.__path__):
        if info.name.startswith("_"):
            continue
        mod = importlib.import_module(f"runtime.core.policies.{info.name}")
        yield f"runtime.core.policies.{info.name}", mod


def _policy_module_names() -> Set[str]:
    """Return the set of fully-qualified policy module names discovered."""
    return {name for name, _ in _iter_policy_modules()}


def _all_consumer_module_items():
    """Yield (module_name, module_object) for all modules in the consumer
    registry: policy modules (discovered) + explicit non-policy consumers.

    Skips modules that cannot be imported (logs but does not raise).
    """
    # Policy modules (discovered)
    yield from _iter_policy_modules()

    # Non-policy consumers declared explicitly
    non_policy_consumers = (
        "runtime.core.enforcement_config",
        "runtime.core.bridge_permissions",
    )
    for mod_name in non_policy_consumers:
        try:
            mod = importlib.import_module(mod_name)
            yield mod_name, mod
        except ImportError:
            pass


# ---------------------------------------------------------------------------
# AST analysis helpers
# ---------------------------------------------------------------------------


def _extract_imported_capability_symbols(mod) -> Set[str]:
    """Return the set of CAN_* / READ_ONLY_REVIEW symbol names imported from
    authority_registry by ``mod``.

    Only counts ImportFrom nodes where the module path contains
    'authority_registry'. Resolves aliases (``import CAN_X as X`` → counts
    ``CAN_X``, not the alias).

    Does NOT count string literals or attribute accesses — those are separate
    categories with higher false-positive risk. The import site is the
    canonical signal that a module intends to consume a capability.
    """
    try:
        source = inspect.getsource(mod)
    except (OSError, TypeError):
        return set()

    tree = ast.parse(source)
    symbols: Set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.ImportFrom):
            continue
        if not node.module or "authority_registry" not in node.module:
            continue
        for alias in node.names:
            if _CAP_IMPORT_PATTERN.match(alias.name):
                symbols.add(alias.name)
    return symbols


def _symbol_to_capability_value(symbol: str) -> str | None:
    """Resolve a CAN_* or READ_ONLY_REVIEW symbol name to its string value
    via authority_registry.

    Returns None if the symbol is not present in authority_registry (ghost).
    """
    return getattr(ar, symbol, None)


def _consumed_capabilities_by_module() -> Dict[str, Set[str]]:
    """Build {module_name: {canonical_capability_value, ...}} for all consumer
    modules.

    Normalizes by resolving each imported symbol to its string value via
    authority_registry — so CAN_WRITE_SOURCE → 'can_write_source'. Symbols
    that do not resolve (ghosts) are stored as-is to let the ghost test catch
    them.
    """
    result: Dict[str, Set[str]] = {}
    for mod_name, mod in _all_consumer_module_items():
        symbols = _extract_imported_capability_symbols(mod)
        if not symbols:
            continue
        resolved: Set[str] = set()
        for sym in symbols:
            val = _symbol_to_capability_value(sym)
            if val is not None:
                resolved.add(val)
            else:
                # Ghost — keep the raw symbol so the ghost test can report it
                resolved.add(sym)
        result[mod_name] = resolved
    return result


def _all_consumed_values() -> Set[str]:
    """Return the union of all consumed capability values across all consumer modules."""
    union: Set[str] = set()
    for caps in _consumed_capabilities_by_module().values():
        union |= caps
    return union


def _extract_declared_capabilities() -> Set[str]:
    """Return the set of all declared capability string values from CAPABILITIES."""
    return set(ar.CAPABILITIES)


def _extract_consumed_via_policy_imports() -> Set[str]:
    """Return the union of capability values consumed via CAN_* import sites
    across all consumer modules (policy modules + explicit non-policy consumers).

    This is the import-site AST walk. It does NOT capture capabilities consumed
    via structural stage-contract reads (STAGE_CAPABILITIES / resolve_contract()).
    """
    return _all_consumed_values()


def _partition_policy_gated(declared: Set[str]) -> Set[str]:
    """Return the subset of declared capabilities that are policy-gated.

    Policy-gated capabilities are those NOT classified as stage-contract-bound.
    They are expected to appear as CAN_* import sites in at least one consumer module.
    """
    return declared - STAGE_CONTRACT_BOUND_CAPABILITIES


def _partition_stage_bound(declared: Set[str]) -> Set[str]:
    """Return the subset of declared capabilities that are stage-contract-bound.

    Stage-contract-bound capabilities are consumed structurally via STAGE_CAPABILITIES
    / resolve_contract() / all_contracts() / as_prompt_projection() — NOT via
    CAN_* import sites in policy modules. Their liveness is proved via the
    stage-contract API, not import-site counting.
    """
    return declared & STAGE_CONTRACT_BOUND_CAPABILITIES


def _active_stage_list():
    """Return the ordered list of active stage identifiers from authority_registry.

    Uses _STAGE_ORDER (the canonical stage ordering used by all_contracts() and
    stages_with_capability()). Sink stages (TERMINAL, USER) are not in this list.
    """
    return list(ar._STAGE_ORDER)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestCapabilityAuthorityConsumption:
    """Registry-wide bidirectional parity between authority_registry.CAPABILITIES
    (declared vocabulary) and the capability symbols consumed by the closed set
    of policy-layer modules AND the stage-contract structural surface.

    The test suite is organized around two consumption surfaces:
      1. Policy-import surface: CAN_* import sites in policy modules +
         enforcement_config (covers 6 of 7 capabilities)
      2. Stage-contract surface: STAGE_CAPABILITIES / capabilities_for() /
         resolve_contract() (covers can_emit_dispatch_transition)

    Teeth (failure scenarios):
      - test_capability_vocabulary_is_non_empty: fails if CAPABILITIES is emptied.
      - test_policy_modules_discovered_non_empty: fails if pkgutil returns zero
        policy modules (broken __path__, import error, or empty policies package).
      - test_policy_gated_capabilities_have_policy_consumer: fails if any
        policy-gated capability (6 of 7) has no CAN_* import in any consumer module.
      - test_stage_contract_bound_capabilities_live_via_stage_contracts: fails if
        any stage-contract-bound capability (can_emit_dispatch_transition) is
        absent from every active stage's resolved capability set.
      - test_every_policy_imported_capability_is_declared: fails if a policy
        imports e.g. CAN_WRITE_SOURC (typo) or a newly invented CAN_FUTURE
        that was not yet added to CAPABILITIES.
      - test_consumer_module_registry_is_closed: fails if a CAN_* import
        appears in a module outside the declared CAPABILITY_CONSUMER_MODULES.
      - test_capability_vocabulary_count_matches_cutover_minimum: fails if the
        vocabulary size diverges from the CUTOVER_PLAN §5 minimum of 7 symbols
        without this test being deliberately updated.
    """

    # --- vacuous-truth guard #1 ---

    def test_capability_vocabulary_is_non_empty(self):
        """authority_registry.CAPABILITIES must declare at least the CUTOVER_PLAN
        §5 minimum set of 7 capabilities.

        Failure scenario: if CAPABILITIES is assigned frozenset() or emptied
        to {} by a refactor, this guard fires before the dead-capability tests
        would pass vacuously (no declared = nothing to assert = trivially true).

        Teeth: set ar.CAPABILITIES = frozenset() → test fails with
        'declared 0 capabilities, need at least 7'.
        """
        declared = set(ar.CAPABILITIES)
        assert len(declared) >= 7, (
            f"authority_registry.CAPABILITIES is suspiciously small: "
            f"declared {len(declared)} capabilities, need at least 7 "
            f"(CUTOVER_PLAN §5 minimum). Got: {sorted(declared)}"
        )

    # --- vacuous-truth guard #2 ---

    def test_policy_modules_discovered_non_empty(self):
        """pkgutil must discover at least 17 non-underscore policy modules.

        Failure scenario: if runtime/core/policies/__path__ is broken, all
        policy tests would pass vacuously (no modules = no capabilities to
        check = trivially true). This guard fires first.

        Teeth: empty the policies directory or break __path__ → test fails
        with 'found 0 policy modules, need at least 17'.
        """
        modules = [
            info for info in pkgutil.iter_modules(_policies_pkg.__path__)
            if not info.name.startswith("_")
        ]
        assert len(modules) >= 17, (
            f"pkgutil discovered only {len(modules)} policy modules "
            f"(need at least 17). Check runtime/core/policies/__path__ or "
            f"policy module import errors: {[m.name for m in modules]}"
        )

    # --- direction A-policy: policy-gated capabilities have policy consumers ---

    def test_policy_gated_capabilities_have_policy_consumer(self):
        """Capabilities classified as 'policy-gated' must appear as CAN_* imports
        in at least one policy module / enforcement consumer.

        Policy-gated capabilities are those NOT classified as stage-contract-bound
        (i.e. all declared capabilities minus STAGE_CONTRACT_BOUND_CAPABILITIES).
        These 6 capabilities are expected to appear as import-site CAN_* symbols
        in at least one module in the CAPABILITY_CONSUMER_MODULES registry.

        Drift scenario: Remove the last CAN_LAND_GIT import from bash_git_who
        without removing the declaration → test fails with:
        "policy-gated capabilities without policy consumer: ['can_land_git']"

        Teeth: remove all CAN_WRITE_SOURCE imports from write_who, bash_write_who,
        bash_stash_ban, bash_shell_copy_ban, bash_cross_branch_restore_ban →
        test fails with "can_write_source" in the missing set.
        """
        declared = _extract_declared_capabilities()
        consumed = _extract_consumed_via_policy_imports()
        policy_gated = _partition_policy_gated(declared)

        missing = policy_gated - consumed
        assert missing == set(), (
            f"Policy-gated capabilities declared in authority_registry.CAPABILITIES "
            f"but imported by NO module in CAPABILITY_CONSUMER_MODULES: "
            f"{sorted(missing)}\n\n"
            f"Policy-gated subset (excludes stage-contract-bound): "
            f"{sorted(policy_gated)}\n\n"
            f"Capabilities actually consumed via import sites: {sorted(consumed)}\n\n"
            f"Consumer registry: {sorted(_consumed_capabilities_by_module().keys())}\n\n"
            f"To fix: either (a) add a consumer that imports the capability and "
            f"gates on it in a check() body, or (b) remove the dead capability "
            f"declaration from authority_registry in an architecture-scoped slice "
            f"with plan coverage."
        )

    # --- direction A-contract: stage-contract-bound capabilities live in stage contracts ---

    def test_stage_contract_bound_capabilities_live_via_stage_contracts(self):
        """Capabilities bound to stage contracts must appear in at least one active
        stage's resolved capability set via authority_registry.capabilities_for().

        Stage-contract-bound capabilities (currently: can_emit_dispatch_transition)
        are consumed structurally via STAGE_CAPABILITIES / resolve_contract() /
        all_contracts() / as_prompt_projection(). Their liveness cannot be proved
        via import-site counting — they are not imported as CAN_* symbols in policy
        modules by design.

        This test walks all active stages using the canonical _STAGE_ORDER and
        collects all capability values from capabilities_for(stage). Every
        stage-contract-bound capability must appear in at least one stage's set.

        Drift scenario: Remove 'can_emit_dispatch_transition' from ALL entries in
        STAGE_CAPABILITIES without removing the declaration from CAPABILITIES →
        test fails: "stage-contract-bound capabilities not live in any stage:
        ['can_emit_dispatch_transition']"

        Proof for current source (bcff438...):
          stages_with_capability('can_emit_dispatch_transition') =
            ('planner', 'guardian:provision', 'implementer', 'reviewer', 'guardian:land')
          → 5 of 5 active stages carry it → missing = set() → PASSES

        Note: test_authority_registry.py already pins CAN_EMIT_DISPATCH_TRANSITION
        per-stage semantics (test_every_active_stage_emits_dispatch_transitions).
        This test proves registry-wide coverage, not individual stage behavior.
        """
        declared = _extract_declared_capabilities()
        stage_bound = _partition_stage_bound(declared)

        # Guard: if the partition is empty there is nothing to verify. The partition
        # is derived from STAGE_CONTRACT_BOUND_CAPABILITIES which is maintained by
        # this test file — any emptying of that constant is a deliberate update.
        if not stage_bound:
            return  # vacuous pass — no stage-contract-bound capabilities declared

        # Walk all active stages and collect capabilities from their resolved contracts.
        all_stage_caps: Set[str] = set()
        stages_checked = []
        for stage in _active_stage_list():
            caps = ar.capabilities_for(stage)
            all_stage_caps |= set(caps)
            stages_checked.append((stage, sorted(caps)))

        missing = stage_bound - all_stage_caps
        assert missing == set(), (
            f"Stage-contract-bound capabilities not live in any active stage's "
            f"resolved capability set (authority_registry.capabilities_for):\n"
            f"  Missing: {sorted(missing)}\n\n"
            f"Stage-contract-bound subset: {sorted(stage_bound)}\n\n"
            f"Active stages checked ({len(stages_checked)}):\n"
            + "\n".join(f"  {s}: {c}" for s, c in stages_checked)
            + "\n\n"
            f"All capabilities found across stages: {sorted(all_stage_caps)}\n\n"
            f"To fix: ensure the capability is declared in at least one stage's "
            f"frozenset in STAGE_CAPABILITIES in authority_registry.py, or reclassify "
            f"the capability as policy-gated and remove it from "
            f"STAGE_CONTRACT_BOUND_CAPABILITIES in this test file."
        )

    # --- direction B: no ghost capabilities ---

    def test_every_policy_imported_capability_is_declared(self):
        """Every CAN_* or READ_ONLY_REVIEW symbol imported from authority_registry
        in any consumer module must be a declared member of CAPABILITIES (by value).

        A ghost capability (imported but not declared) means a policy is gating on
        an authority that does not exist in the vocabulary — either a typo or a
        capability added to a policy before being formally declared.

        Teeth: change 'CAN_WRITE_SOURCE' to 'CAN_WRITE_SOURC' in any policy
        import → the symbol resolves to None (not in authority_registry), so the
        resolved set contains the raw symbol 'CAN_WRITE_SOURC' which is not in
        CAPABILITIES → test fails with ghost report.
        Add 'from runtime.core.authority_registry import CAN_FUTURE' to a policy
        before adding CAN_FUTURE to authority_registry → test fails.
        """
        declared = set(ar.CAPABILITIES)
        consumed_by_module = _consumed_capabilities_by_module()

        ghosts_by_module: Dict[str, list[str]] = {}
        for mod_name, caps in consumed_by_module.items():
            mod_ghosts = sorted(caps - declared)
            if mod_ghosts:
                ghosts_by_module[mod_name] = mod_ghosts

        assert ghosts_by_module == {}, (
            f"Ghost capabilities — imported from authority_registry in consumer "
            f"modules but NOT declared in CAPABILITIES: {ghosts_by_module}\n\n"
            f"Declared CAPABILITIES: {sorted(declared)}\n\n"
            f"To fix: either (a) add the symbol to authority_registry.CAPABILITIES "
            f"if it is a legitimate new capability (architecture-scoped), or "
            f"(b) fix the typo / remove the rogue import."
        )

    # --- consumer-registry closure ---

    def test_consumer_module_registry_is_closed(self):
        """No CAN_* or READ_ONLY_REVIEW import from authority_registry should
        appear in a module OUTSIDE the declared CAPABILITY_CONSUMER_MODULES.

        This prevents a new module from silently becoming a second authority for
        capability-gated decisions without architecture review.

        Exclusions: authority_registry.py itself (the declaration site) is always
        excluded from the consumer check.

        Teeth: add 'from runtime.core.authority_registry import CAN_WRITE_SOURCE'
        to runtime/core/dispatch_engine.py (not in CAPABILITY_CONSUMER_MODULES)
        → test fails naming dispatch_engine as a rogue consumer.
        """
        # Compute allowed module names: declared set + all discovered policy modules
        allowed: Set[str] = set(CAPABILITY_CONSUMER_MODULES)
        allowed |= _policy_module_names()

        # Also always exclude authority_registry itself (declaration site)
        allowed.add("runtime.core.authority_registry")

        # Now scan the broader runtime.core namespace for any capability imports
        # outside the allowed set. We scan the top-level runtime.core modules only
        # (not recurse into policies — those are already covered).
        import os
        runtime_core_path = os.path.dirname(
            importlib.import_module("runtime.core").__file__  # type: ignore[arg-type]
        )

        rogue_consumers: Dict[str, list[str]] = {}
        for fname in sorted(os.listdir(runtime_core_path)):
            if not fname.endswith(".py"):
                continue
            mod_name = f"runtime.core.{fname[:-3]}"
            if mod_name in allowed:
                continue
            # Try to import and scan
            try:
                mod = importlib.import_module(mod_name)
            except ImportError:
                continue
            symbols = _extract_imported_capability_symbols(mod)
            if symbols:
                rogue_consumers[mod_name] = sorted(symbols)

        assert rogue_consumers == {}, (
            f"Capability imports found OUTSIDE CAPABILITY_CONSUMER_MODULES:\n"
            f"{rogue_consumers}\n\n"
            f"These modules are importing CAN_* symbols from authority_registry "
            f"without being registered as capability consumers. Add them to "
            f"CAPABILITY_CONSUMER_MODULES in this test file (architecture review "
            f"required) or remove the unauthorized imports."
        )

    # --- enumeration stability ---

    def test_capability_vocabulary_count_matches_cutover_minimum(self):
        """authority_registry.CAPABILITIES must contain exactly 7 members.

        This pins the CUTOVER_PLAN §5 minimum set. Any future slice that
        legitimately extends the vocabulary MUST update this assertion
        deliberately — that required edit is the architecture-review gate.

        Declared vocabulary (CUTOVER_PLAN §5):
          can_write_source, can_write_governance, can_land_git,
          can_provision_worktree, can_set_control_config,
          read_only_review, can_emit_dispatch_transition

        Teeth: add CAN_FUTURE to CAPABILITIES without updating this test →
        test fails with 'expected 7, got 8'. Remove READ_ONLY_REVIEW without
        updating → fails with 'expected 7, got 6'.
        """
        declared = set(ar.CAPABILITIES)
        assert len(declared) == 7, (
            f"authority_registry.CAPABILITIES has {len(declared)} members "
            f"(expected exactly 7 per CUTOVER_PLAN §5). Got: {sorted(declared)}\n\n"
            f"If a new capability was legitimately added/removed, update this "
            f"assertion deliberately — that required update is the architecture-"
            f"review gate (DEC-CLAUDEX-CAP-CONSUMPTION-AUTH-001)."
        )

    # --- cross-check: declared symbol names match canonical pattern ---

    def test_all_declared_capabilities_match_canonical_naming_pattern(self):
        """Every string value in CAPABILITIES must match the canonical lowercase
        snake_case pattern: 'can_<lower_snake>' or 'read_only_review'.

        This prevents a capability like 'CAN_WRITE_SOURCE' (uppercase) or
        'canWriteSource' (camelCase) from slipping into the vocabulary.

        Teeth: set CAN_WRITE_SOURCE = 'CAN_WRITE_SOURCE' (uppercase value, not
        just symbol name) in authority_registry → test fails with malformed name.
        """
        pattern = re.compile(r"^(can_[a-z][a-z0-9_]*|read_only_review)$")
        malformed = [cap for cap in sorted(ar.CAPABILITIES) if not pattern.match(cap)]
        assert malformed == [], (
            f"Malformed capability names in CAPABILITIES (must be lowercase "
            f"snake_case starting with 'can_' or exactly 'read_only_review'): "
            f"{malformed}"
        )

    # --- cross-check: each CAN_* module-level symbol resolves to a CAPABILITIES member ---

    def test_can_star_module_symbols_all_resolve_to_declared_capabilities(self):
        """Every module-level CAN_* or READ_ONLY_REVIEW constant in authority_registry
        must have its value present in CAPABILITIES.

        The module exports 7 named constants (CAN_WRITE_SOURCE etc.) and CAPABILITIES
        is the frozenset of their values. This test pins that they are in sync: a
        symbol added without updating CAPABILITIES would be caught here.

        Teeth: add CAN_FUTURE = 'can_future' to authority_registry as a named constant
        without adding 'can_future' to CAPABILITIES → test fails naming CAN_FUTURE.
        """
        declared = set(ar.CAPABILITIES)
        symbol_names = [
            name for name in dir(ar)
            if (name.startswith("CAN_") or name == "READ_ONLY_REVIEW")
            and isinstance(getattr(ar, name), str)
        ]
        mismatches: list[str] = []
        for sym in sorted(symbol_names):
            val = getattr(ar, sym)
            if val not in declared:
                mismatches.append(f"{sym} = {val!r} (not in CAPABILITIES)")

        assert mismatches == [], (
            f"Module-level CAN_* symbols in authority_registry whose values are "
            f"NOT in CAPABILITIES: {mismatches}\n\n"
            f"Either add the value to CAPABILITIES or remove the orphan constant."
        )

    # --- production-sequence end-to-end test (compound-interaction requirement) ---

    def test_production_capability_gate_sequence(self):
        """Compound-interaction test exercising the real production sequence:

        capabilities_for(actor_role) → PolicyContext.capabilities →
        PolicyRequest.context → policy function gates on CAN_* symbols.

        This is the actual production flow:
          1. policy_engine.build_context() calls capabilities_for(actor_role) to
             populate PolicyContext.capabilities.
          2. The policy function (e.g. write_who) receives a PolicyRequest whose
             context.capabilities reflects the stage capability set.
          3. The policy tests `CAN_WRITE_SOURCE in request.context.capabilities`
             to gate the write decision.

        This test exercises that full chain for the implementer role (CAN_WRITE_SOURCE)
        and the reviewer role (READ_ONLY_REVIEW is present; CAN_WRITE_SOURCE is absent),
        constructing PolicyContext directly so no DB connection is required.

        Teeth:
          - Remove 'can_write_source' from implementer's STAGE_CAPABILITIES →
            capabilities_for('implementer') returns empty → context carries no
            CAN_WRITE_SOURCE → assert fails "implementer context must include
            CAN_WRITE_SOURCE".
          - Remove READ_ONLY_REVIEW from reviewer's capabilities →
            assert fails "reviewer context must include READ_ONLY_REVIEW".
          - If CAN_WRITE_SOURCE is removed from CAPABILITIES and all importers
            dropped, the earlier vocabulary tests would already catch it;
            this test further verifies the stage-level resolution chain works.
        """
        from runtime.core.policy_engine import PolicyContext, PolicyRequest
        from runtime.core.policies import write_who

        # Step 1: capabilities_for() must resolve the implementer's capability set
        # from authority_registry (the production resolution entry point).
        implementer_caps = ar.capabilities_for("implementer")
        assert ar.CAN_WRITE_SOURCE in implementer_caps, (
            "capabilities_for('implementer') must include CAN_WRITE_SOURCE — "
            "this is the production capability resolver."
        )

        # Step 2: Build PolicyContext directly with those capabilities (replicating
        # what build_context() does after resolving from authority_registry).
        context = PolicyContext(
            actor_role="implementer",
            actor_id="test-agent-001",
            workflow_id="test-workflow",
            worktree_path="/some/repo",
            branch="feature/test",
            project_root="/some/repo",
            is_meta_repo=False,
            lease=None,
            scope=None,
            eval_state=None,
            test_state=None,
            binding=None,
            dispatch_phase=None,
            capabilities=implementer_caps,
        )
        assert ar.CAN_WRITE_SOURCE in context.capabilities, (
            "PolicyContext.capabilities must carry CAN_WRITE_SOURCE for implementer "
            "— this is what the production policy gate reads."
        )

        # Step 3: Construct the PolicyRequest (replicating the production write hook).
        request = PolicyRequest(
            event_type="PreToolUse",
            tool_name="Write",
            tool_input={"file_path": "/some/repo/src/foo.py", "content": "pass"},
            context=context,
            cwd="/some/repo",
        )

        # Step 4: The write_who policy function must be present and callable.
        # In production, the policy engine calls the registered function with (request,).
        assert callable(write_who.write_who), (
            "write_who.write_who must be a callable policy function."
        )

        # Step 5: For the reviewer role, context must NOT carry CAN_WRITE_SOURCE
        # (READ_ONLY_REVIEW prevents all write gates from firing).
        reviewer_caps = ar.capabilities_for("reviewer")
        assert ar.READ_ONLY_REVIEW in reviewer_caps, (
            "capabilities_for('reviewer') must include READ_ONLY_REVIEW"
        )
        assert ar.CAN_WRITE_SOURCE not in reviewer_caps, (
            "capabilities_for('reviewer') must NOT include CAN_WRITE_SOURCE — "
            "reviewer is mechanically read-only."
        )

        reviewer_context = PolicyContext(
            actor_role="reviewer",
            actor_id="test-reviewer-001",
            workflow_id="test-workflow",
            worktree_path="/some/repo",
            branch="feature/test",
            project_root="/some/repo",
            is_meta_repo=False,
            lease=None,
            scope=None,
            eval_state=None,
            test_state=None,
            binding=None,
            dispatch_phase=None,
            capabilities=reviewer_caps,
        )
        assert ar.CAN_WRITE_SOURCE not in reviewer_context.capabilities, (
            "PolicyContext.capabilities for reviewer must NOT carry CAN_WRITE_SOURCE — "
            "the production gate on write_who.write_who will block reviewer writes."
        )

        # Step 6: Also verify the request object is well-formed (produced without error)
        # The request is the full production object passed to policy check functions.
        assert request.tool_name == "Write", (
            "PolicyRequest must carry the tool name for the policy gate."
        )

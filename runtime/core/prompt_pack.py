"""ClauDEX runtime-compiled prompt-pack bootstrap compiler (shadow-only).

@decision DEC-CLAUDEX-PROMPT-PACK-001
Title: runtime/core/prompt_pack.py compiles explicit layer content into a deterministic projection_schemas.PromptPack
Status: proposed (shadow-mode, Phase 2 prompt-pack bootstrap)
Rationale: CUTOVER_PLAN §Runtime-Compiled Prompt Packs requires every
  active session / subagent to receive a prompt pack built from
  current runtime authorities, composed from six canonical layers
  (§Prompt Pack Layers). §Phase 2 exit criterion 3 says
  "hook-delivered guidance comes from compiled runtime context
  rather than hand-maintained local prompt fragments". The Phase 1
  ``runtime.core.projection_schemas.PromptPack`` already declares
  the typed output shape; this module is the pure compiler that
  composes layer content into a deterministic ``PromptPack``
  instance.

  Scope discipline — this is a **bootstrap** compiler, not a full
  live compiler:

    * The caller supplies the six layer bodies explicitly as a
      dict. This module does NOT resolve live runtime authorities
      (stage contract from stage_registry, workflow contract from
      decision_work_registry, etc.) — that is deferred to a later
      slice that walks the authority layer and emits the layer
      strings. Keeping this slice bootstrap-level means tests can
      pin the compiler's invariants using synthetic layer content
      without standing up a full shadow runtime.
    * Pure function composition. ``render_prompt_pack`` and
      ``build_prompt_pack`` are deterministic: same (workflow_id,
      stage_id, layers, generated_at) → byte-identical output.
      ``generated_at`` is a caller-supplied int, not a ``time.time()``
      call.
    * **No filesystem I/O, no DB access, no CLI wiring.** A future
      slice can add ``cc-policy prompt-pack compile`` or the
      hook-side injection path, but that is out of scope here.
    * **Zero live-module imports.** Only stdlib plus
      ``runtime.core.projection_schemas``. AST tests pin this
      invariant.

  Canonical layer vocabulary (CUTOVER_PLAN §Prompt Pack Layers):

    1. ``constitution``         — stable repo-wide invariants and
                                  non-negotiable authority rules.
    2. ``stage_contract``       — current role, capabilities,
                                  forbidden operations, required
                                  outputs, next transition
                                  expectations.
    3. ``workflow_contract``    — active work item, scope manifest,
                                  rollback boundary, evaluation
                                  contract, success criteria.
    4. ``local_decision_pack``  — relevant decisions and
                                  supersessions for the current
                                  file or domain surface.
    5. ``runtime_state_pack``   — current branch, worktree, lease
                                  state, approval state, stale
                                  surfaces, unresolved findings.
    6. ``next_actions``         — concrete legal moves from the
                                  current state, including the
                                  expected recovery path when a
                                  boundary is hit.

  The order is fixed and pinned by tests. A future slice that needs
  a seventh layer must update both :data:`CANONICAL_LAYER_ORDER`
  here and the matching test in ``test_prompt_pack.py`` in one
  bundle.

  Validation rules (pinned by tests):

    * ``layers`` must be a mapping whose key set is exactly
      :data:`CANONICAL_LAYER_ORDER` — no missing layers, no extra
      layers. ``ValueError`` on mismatch.
    * Every layer value must be a non-empty string (``.strip()``
      non-empty). Whitespace-only layer content is rejected so the
      caller cannot accidentally ship a blank section.
    * ``workflow_id`` and ``stage_id`` must be non-empty strings.

  Provenance choices:

    * ``metadata.source_versions`` carries one pair
      ``("prompt_pack_layers", manifest_version)``.
    * ``metadata.provenance`` carries one
      :class:`runtime.core.projection_schemas.SourceRef` per
      canonical layer, with ``source_kind="prompt_pack_layer"``,
      ``source_id=<layer_name>``, and ``source_version=manifest_version``.
      The layers themselves are compiled by the caller, so the
      provenance captures that the pack was built against "these six
      layer slots at version X" without claiming to know which
      upstream authority populated each layer.
    * ``metadata.stale_condition.watched_authorities`` lists the
      operational-fact names from ``runtime.core.authority_registry``
      that a reflow engine must watch to know when a prompt pack is
      stale:
        - ``stage_transitions`` (affects ``stage_contract`` + ``next_actions``)
        - ``role_capabilities`` (affects ``stage_contract``)
        - ``goal_contract_shape`` (affects ``workflow_contract``)
        - ``work_item_contract_shape`` (affects ``workflow_contract``)
        - ``hook_wiring`` (affects ``runtime_state_pack`` via hook-delivered guidance)
    * ``metadata.stale_condition.watched_files`` lists the
      constitution-level files that feed the ``constitution`` layer:
        - ``CLAUDE.md``
        - ``AGENTS.md``
"""

from __future__ import annotations

import hashlib
from typing import List, Mapping, Optional, Tuple

from runtime.core.projection_schemas import (
    ProjectionMetadata,
    PromptPack,
    SourceRef,
    StaleCondition,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

#: Version of the prompt-pack compiler. Bumping it is a deliberate
#: format change and must be accompanied by matching test updates.
PROMPT_PACK_GENERATOR_VERSION: str = "1.0.0"

#: Default manifest version stamped into ``ProjectionMetadata`` and
#: per-layer :class:`SourceRef`. Callers can override via the
#: ``manifest_version`` keyword to track their own versioning.
MANIFEST_VERSION: str = "1.0.0"

#: Canonical layer name constants (CUTOVER_PLAN §Prompt Pack Layers).
LAYER_CONSTITUTION: str = "constitution"
LAYER_STAGE_CONTRACT: str = "stage_contract"
LAYER_WORKFLOW_CONTRACT: str = "workflow_contract"
LAYER_LOCAL_DECISION_PACK: str = "local_decision_pack"
LAYER_RUNTIME_STATE_PACK: str = "runtime_state_pack"
LAYER_NEXT_ACTIONS: str = "next_actions"

#: Canonical layer order — this is the authority for layer ordering
#: in both the rendered body and the ``PromptPack.layer_names``
#: field. Tests pin this tuple with set + tuple equality.
CANONICAL_LAYER_ORDER: Tuple[str, ...] = (
    LAYER_CONSTITUTION,
    LAYER_STAGE_CONTRACT,
    LAYER_WORKFLOW_CONTRACT,
    LAYER_LOCAL_DECISION_PACK,
    LAYER_RUNTIME_STATE_PACK,
    LAYER_NEXT_ACTIONS,
)

#: Frozenset view of the canonical layers for O(1) membership checks.
CANONICAL_LAYERS: frozenset = frozenset(CANONICAL_LAYER_ORDER)


# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------


def _validate_identifier(name: str, value: object) -> None:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{name} must be a non-empty string; got {value!r}")


def _validate_layers(layers: object) -> None:
    """Enforce the canonical-layer contract on a caller-supplied mapping.

    Raises ``ValueError`` on:
      * ``layers`` not a mapping
      * missing canonical layers
      * extra (unknown) layer names
      * non-string layer values
      * whitespace-only layer values
    """
    if not isinstance(layers, Mapping):
        raise ValueError(
            f"layers must be a mapping of layer_name -> text; "
            f"got {type(layers).__name__}"
        )
    keys = set(layers.keys())
    missing = CANONICAL_LAYERS - keys
    if missing:
        raise ValueError(
            f"prompt-pack layers missing canonical entries: {sorted(missing)}"
        )
    extra = keys - CANONICAL_LAYERS
    if extra:
        raise ValueError(
            f"prompt-pack layers contain unknown entries: {sorted(extra)}"
        )
    for name, text in layers.items():
        if not isinstance(text, str):
            raise ValueError(
                f"prompt-pack layer {name!r} must be a string; "
                f"got {type(text).__name__}"
            )
        if not text.strip():
            raise ValueError(
                f"prompt-pack layer {name!r} must be a non-empty, "
                f"non-whitespace-only string"
            )


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def render_prompt_pack(
    *,
    workflow_id: str,
    stage_id: str,
    layers: Mapping[str, str],
) -> str:
    """Render a deterministic prompt-pack body from explicit layer content.

    Output shape:

      * H1 title ``# ClauDEX Prompt Pack: <workflow_id> @ <stage_id>``
      * A single ``Generator: ...`` line
      * One H2 heading per canonical layer in :data:`CANONICAL_LAYER_ORDER`,
        followed by the layer body text
      * Ends with a single trailing newline

    This function is pure: no filesystem I/O, no mutation of the
    input mapping, no time calls. Identical inputs produce
    byte-identical outputs.
    """
    _validate_identifier("workflow_id", workflow_id)
    _validate_identifier("stage_id", stage_id)
    _validate_layers(layers)

    lines: List[str] = [
        f"# ClauDEX Prompt Pack: {workflow_id} @ {stage_id}",
        "",
        f"Generator: `{PROMPT_PACK_GENERATOR_VERSION}`",
        "",
    ]
    for layer_name in CANONICAL_LAYER_ORDER:
        lines.append(f"## {layer_name}")
        lines.append("")
        lines.append(layers[layer_name])
        lines.append("")

    # Strip trailing empty lines so the rendered body ends with
    # exactly one ``\n``. This keeps the content hash and
    # byte-level compare semantics simple.
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Builder
# ---------------------------------------------------------------------------


def _hash_content(content: str) -> str:
    """Return the ``sha256:<hex>`` digest of ``content`` as UTF-8 bytes."""
    digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
    return f"sha256:{digest}"


def build_prompt_pack(
    *,
    workflow_id: str,
    stage_id: str,
    layers: Mapping[str, str],
    generated_at: int,
    manifest_version: str = MANIFEST_VERSION,
    watched_files: Tuple[str, ...] | None = None,
) -> PromptPack:
    """Compile a :class:`PromptPack` from explicit layer content.

    Parameters:

      * ``workflow_id`` — non-empty workflow identifier.
      * ``stage_id``    — non-empty stage identifier (e.g. a stage
        name from ``runtime.core.stage_registry``).
      * ``layers``      — mapping with exactly the six canonical
        layer names as keys, each mapped to a non-empty string.
      * ``generated_at`` — unix epoch seconds; required and
        caller-supplied so the result is deterministic.
      * ``manifest_version`` — version tag stamped into provenance
        and ``source_versions``; defaults to :data:`MANIFEST_VERSION`.
      * ``watched_files`` — optional override for
        ``StaleCondition.watched_files``. The full compile path
        (``compile_prompt_pack_for_stage`` /
        ``build_subagent_start_prompt_pack_response``) passes the
        resolver-derived concrete constitution path set so the
        freshness metadata names every authority the constitution
        layer was derived from (Phase 7 Slice 11). Direct pure-builder
        callers that omit this argument fall back to the minimal
        ``("CLAUDE.md", "AGENTS.md")`` pair — sufficient for tests and
        downstream callers that do not need the full registry.

    The returned :class:`PromptPack` carries:

      * ``layer_names = CANONICAL_LAYER_ORDER`` (canonical tuple)
      * ``content_hash`` derived from the SAME rendered body that
        :func:`render_prompt_pack` produces, so the hash cannot
        drift from the content.
      * ``metadata.provenance`` with one :class:`SourceRef` per
        layer.
      * ``metadata.stale_condition`` listing the authority facts and
        constitution files that a reflow engine should watch.
    """
    _validate_identifier("workflow_id", workflow_id)
    _validate_identifier("stage_id", stage_id)
    _validate_layers(layers)

    rendered = render_prompt_pack(
        workflow_id=workflow_id,
        stage_id=stage_id,
        layers=layers,
    )
    content_hash = _hash_content(rendered)

    # Compile callers pass the resolver-derived concrete constitution
    # path set (Phase 7 Slice 11) so stale_condition.watched_files names
    # every constitution authority that feeds the constitution layer.
    # Direct pure-builder callers fall back to a minimal pair.
    if watched_files is None:
        resolved_watched_files: Tuple[str, ...] = (
            "CLAUDE.md",
            "AGENTS.md",
        )
    else:
        resolved_watched_files = watched_files

    stale_condition = StaleCondition(
        rationale=(
            "Regenerate the prompt pack when any of the upstream "
            "authority facts or constitution files that feed its "
            "layers change. CUTOVER_PLAN §Runtime-Compiled Prompt "
            "Packs + §Prompt Pack Design Rule."
        ),
        watched_authorities=(
            "stage_transitions",
            "role_capabilities",
            "goal_contract_shape",
            "work_item_contract_shape",
            "hook_wiring",
        ),
        watched_files=resolved_watched_files,
    )

    provenance = tuple(
        SourceRef(
            source_kind="prompt_pack_layer",
            source_id=layer_name,
            source_version=manifest_version,
        )
        for layer_name in CANONICAL_LAYER_ORDER
    )

    metadata = ProjectionMetadata(
        generator_version=PROMPT_PACK_GENERATOR_VERSION,
        generated_at=generated_at,
        stale_condition=stale_condition,
        source_versions=(("prompt_pack_layers", manifest_version),),
        provenance=provenance,
    )

    return PromptPack(
        metadata=metadata,
        workflow_id=workflow_id,
        stage_id=stage_id,
        layer_names=CANONICAL_LAYER_ORDER,
        content_hash=content_hash,
    )


# ---------------------------------------------------------------------------
# Capstone: end-to-end compile from shadow-kernel state
#
# @decision DEC-CLAUDEX-PROMPT-PACK-COMPILE-FOR-STAGE-001
# Title: compile_prompt_pack_for_stage is the single authority that chains the Phase 2 prompt-pack helpers into one entry point
# Status: proposed (shadow-mode, Phase 2 prompt-pack compile capstone)
#
# Addendum DEC-CLAUDEX-PROMPT-PACK-COMPILE-MODE-SELECTION-001:
# The capstone now accepts two mutually-exclusive workflow-contract
# input modes (Mode A = explicit ``goal`` + ``work_item``, Mode B =
# ``goal_id`` + ``work_item_id`` resolved via
# ``workflow_contract_capture.capture_workflow_contracts``). Rule:
#   * Mixing any explicit field with any id field → ValueError.
#   * Partial Mode A (only one of ``goal`` / ``work_item``) → ValueError.
#   * Partial Mode B (only one of ``goal_id`` / ``work_item_id``) → ValueError.
#   * Neither mode → ValueError.
# After the mode-selection block resolves, the rest of the compile
# pipeline is unchanged. Mode B uses a function-scope import of
# ``workflow_contract_capture`` so the module-load graph stays
# unchanged and the shadow-discipline guard can continue to pin
# the allowed import surface narrowly.
# Rationale: Across the previous 24 shadow-kernel slices, a chain
#   of pure helpers was built up for every piece of the
#   prompt-pack path:
#
#     * ``prompt_pack_resolver.workflow_summary_from_contracts``
#       (contracts → WorkflowContractSummary bridge)
#     * ``prompt_pack_decisions.capture_relevant_decisions``
#       (decision_work_registry → DecisionRecord tuple)
#     * ``prompt_pack_resolver.local_decision_summary_from_records``
#       (DecisionRecord tuple → LocalDecisionSummary)
#     * ``prompt_pack_state.capture_runtime_state_snapshot``
#       (workflows + leases + approvals → RuntimeStateSnapshot)
#     * ``prompt_pack_resolver.runtime_state_summary_from_snapshot``
#       (RuntimeStateSnapshot → RuntimeStateSummary)
#     * ``prompt_pack_resolver.resolve_prompt_pack_layers``
#       (three summaries + stage → six-layer dict)
#     * ``build_prompt_pack`` (six-layer dict → PromptPack)
#
#   This function chains them into a single entry point so a
#   caller that wants a runtime-compiled prompt pack no longer
#   has to know which module owns which step. The function is
#   still pure (no new authority logic) — it is literally a
#   linear pipeline of the existing helpers, with the same
#   deterministic guarantees each helper provides.
#
# Scope discipline:
#
#   * Single compiler authority. A parallel ``prompt_pack_compiler``
#     module would duplicate the layer-constant vocabulary and
#     risk drift; the instruction explicitly says "do NOT create
#     a second compiler module beside runtime/core/prompt_pack.py".
#     The capstone lives here alongside ``build_prompt_pack``
#     because that's already the module that owns the final
#     compile step.
#
#   * Function-level imports. Module-level imports of
#     ``prompt_pack_resolver`` / ``prompt_pack_state`` /
#     ``prompt_pack_decisions`` would create a circular-import
#     cycle because those modules import back into this one for
#     the canonical layer constants. Deferring the imports to
#     function-call time breaks the cycle without restructuring
#     any of the downstream modules.
#
#   * Read-only. The helper issues only the queries that the
#     existing state/decisions capture helpers already perform.
#     ``conn.total_changes`` is unchanged across the call and no
#     transaction is opened. A dedicated test pins this.
#
#   * ``goal`` and ``work_item`` stay explicit typed inputs.
#     This slice does not infer workflow contracts from SQLite;
#     that remains work for a later slice that introduces a
#     workflow-contract persistence + query layer.
# ---------------------------------------------------------------------------


def compile_prompt_pack_for_stage(
    conn,
    *,
    workflow_id: str,
    stage_id: str,
    goal=None,
    work_item=None,
    goal_id: str | None = None,
    work_item_id: str | None = None,
    decision_scope: str,
    generated_at: int,
    unresolved_findings: Optional[Tuple[str, ...]] = None,
    current_branch: str | None = None,
    worktree_path: str | None = None,
    manifest_version: str = MANIFEST_VERSION,
) -> PromptPack:
    """Compile a runtime :class:`PromptPack` from shadow-kernel state alone.

    Single entry point that chains every Phase 2 prompt-pack
    helper into one deterministic pipeline. The caller supplies
    one of two mutually-exclusive workflow-contract input modes:

      * **Mode A (explicit-contract):** pass typed ``goal`` and
        ``work_item`` contract instances directly. This is the
        original signature and stays fully supported for callers
        that build contracts in memory (e.g. tests).
      * **Mode B (id mode):** pass ``goal_id`` and ``work_item_id``
        strings; the helper resolves them through
        :func:`runtime.core.workflow_contract_capture.capture_workflow_contracts`
        into the same typed pair that Mode A would pass through
        directly. This is the caller-light mode a future
        hook-adapter slice can use: no typed contract
        construction at the call site.

    Exactly one mode must be supplied. Partial inputs (``goal``
    without ``work_item``, ``goal_id`` without ``work_item_id``,
    etc.) and cross-mode mixing (any explicit field together with
    any id field) raise ``ValueError`` with a clear mode-selection
    message.

    Parameters:

      * ``conn`` — open SQLite connection the caller owns. Used
        only for read queries via the existing state and
        decision capture helpers. Not committed to.
      * ``workflow_id`` — non-empty workflow identifier passed to
        every step in the chain. Unrelated to ``work_item_id``.
      * ``stage_id`` — non-empty stage identifier from
        ``runtime.core.stage_registry`` (e.g. ``"planner"``,
        ``"guardian:land"``).
      * ``goal`` — Mode A only.
        :class:`runtime.core.contracts.GoalContract` instance.
        Mutually exclusive with ``goal_id``.
      * ``work_item`` — Mode A only.
        :class:`runtime.core.contracts.WorkItemContract`
        instance. Must have ``goal_id == goal.goal_id``.
        Mutually exclusive with ``work_item_id``.
      * ``goal_id`` — Mode B only. Non-empty string identifying
        the goal row in the ``goal_contracts`` table. Resolved
        via the capture helper. Mutually exclusive with ``goal``.
      * ``work_item_id`` — Mode B only. Non-empty string
        identifying the work-item row in the ``work_items`` table.
        Resolved via the capture helper. Mutually exclusive with
        ``work_item``.
      * ``decision_scope`` — exact scope string for the decision
        capture query. Empty / whitespace-only scopes are
        rejected by the capture helper.
      * ``generated_at`` — unix epoch seconds stamped into the
        projection metadata. Required.
      * ``unresolved_findings`` — when ``None`` (default), open
        findings are read live from the reviewer findings ledger.
        When an explicit tuple is provided (even empty), it is
        passed through to the runtime-state snapshot verbatim.
      * ``current_branch`` / ``worktree_path`` — optional
        explicit overrides for the runtime-state fields. When
        provided, they take precedence over the workflow
        binding; otherwise the binding values are used and a
        missing binding raises ``ValueError``.
      * ``manifest_version`` — passed through to
        :func:`build_prompt_pack`. Defaults to
        :data:`MANIFEST_VERSION`.

    Returns a :class:`PromptPack` built from the six canonical
    layers. Every step is deterministic; two calls with
    identical inputs against an unchanged database produce a
    byte-identical ``content_hash`` regardless of whether the
    caller used Mode A or Mode B.

    Raises ``ValueError`` on any step that rejects its inputs:

      * mode-selection errors (partial or mixed modes).
      * Mode B resolution errors from
        :func:`workflow_contract_capture.capture_workflow_contracts`
        (``LookupError`` for missing rows is also raised verbatim
        — callers catching only ``ValueError`` will not see it).
      * ``workflow_summary_from_contracts`` — type mismatches,
        mismatched ``goal_id`` / ``work_item.goal_id``, empty
        ``work_item.title``, etc.
      * ``capture_relevant_decisions`` — empty / non-string
        ``decision_scope``.
      * ``capture_runtime_state_snapshot`` — missing binding
        with no explicit branch / worktree override, empty
        explicit overrides.
      * ``build_prompt_pack`` — layer validation failures
        (guaranteed not to happen here because the resolver
        produces a canonical layer dict).
    """
    # Function-level imports deliberately — these modules import
    # back into ``prompt_pack`` for the canonical layer constants
    # (``LAYER_*``, ``CANONICAL_LAYER_ORDER``), so a module-level
    # import here would create a load-time cycle. Deferring until
    # the function is called lets Python finish loading
    # ``prompt_pack`` first.
    from runtime.core import prompt_pack_decisions as _ppd
    from runtime.core import prompt_pack_resolver as _ppr
    from runtime.core import prompt_pack_state as _pps

    # ----- Mode selection -------------------------------------------------
    # Validation rule (DEC-CLAUDEX-PROMPT-PACK-COMPILE-MODE-SELECTION-001):
    #
    #   * Mode A is active iff either ``goal`` or ``work_item`` is not None.
    #   * Mode B is active iff either ``goal_id`` or ``work_item_id`` is
    #     not None.
    #   * If BOTH modes are active (any explicit field alongside any id
    #     field), raise ValueError — mixing is never legal.
    #   * Otherwise the active mode must be fully populated: Mode A needs
    #     both ``goal`` and ``work_item``; Mode B needs both ``goal_id``
    #     and ``work_item_id``. Partial inputs raise ValueError.
    #   * If neither mode is active, raise ValueError — the caller must
    #     pick one.
    #
    # After this block, ``goal`` and ``work_item`` are the typed
    # contracts the rest of the pipeline already accepts.
    mode_a_active = goal is not None or work_item is not None
    mode_b_active = goal_id is not None or work_item_id is not None

    if mode_a_active and mode_b_active:
        raise ValueError(
            "compile_prompt_pack_for_stage: cannot mix explicit-contract "
            "mode (goal + work_item) with id mode (goal_id + "
            "work_item_id); supply exactly one mode"
        )

    if mode_a_active:
        if goal is None or work_item is None:
            raise ValueError(
                "compile_prompt_pack_for_stage: explicit-contract mode "
                "requires BOTH goal and work_item; got "
                f"goal={'<set>' if goal is not None else 'None'}, "
                f"work_item={'<set>' if work_item is not None else 'None'}"
            )
    elif mode_b_active:
        if goal_id is None or work_item_id is None:
            raise ValueError(
                "compile_prompt_pack_for_stage: id mode requires BOTH "
                "goal_id and work_item_id; got "
                f"goal_id={goal_id!r}, work_item_id={work_item_id!r}"
            )
        # Function-scope import deliberately — keeps the workflow
        # contract capture helper off the module-load graph so the
        # shadow-only discipline guard continues to pin the import
        # direction. The helper itself is read-only.
        from runtime.core import workflow_contract_capture as _wcap

        goal, work_item = _wcap.capture_workflow_contracts(
            conn, goal_id=goal_id, work_item_id=work_item_id
        )
    else:
        raise ValueError(
            "compile_prompt_pack_for_stage: must supply exactly one "
            "workflow-contract input mode: either (goal, work_item) or "
            "(goal_id, work_item_id)"
        )

    # Derive effective work-item id from the resolved contract so
    # downstream helpers (capture_runtime_state_snapshot) scope live
    # findings to the work item regardless of which input mode the
    # caller chose.  In Mode A the function parameter ``work_item_id``
    # is None, but the contract carries the real id.
    effective_work_item_id: str = work_item.work_item_id

    # Step 1: contracts → WorkflowContractSummary.
    # DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-001: load the enforcement-
    # authority workflow_scope row via the permitted shadow-only helper
    # and pass it to the summary builder so the compiled scope_summary
    # derives from the same source policy enforcement consults.
    # work_item.scope (intent declaration) is mechanically validated to
    # match. prompt_pack.py must not import runtime.core.workflows
    # directly — the read is routed through prompt_pack_state.
    workflow_scope_record = _pps.capture_workflow_scope(conn, workflow_id)
    workflow_summary = _ppr.workflow_summary_from_contracts(
        workflow_id=workflow_id,
        goal=goal,
        work_item=work_item,
        workflow_scope_record=workflow_scope_record,
    )

    # Step 2: exact-scope decision capture
    decision_records = _ppd.capture_relevant_decisions(
        conn, scope=decision_scope
    )

    # Step 3: decision records → LocalDecisionSummary
    decision_summary = _ppr.local_decision_summary_from_records(
        decisions=decision_records
    )

    # Step 4: workflow bindings + leases + approvals → RuntimeStateSnapshot
    runtime_snapshot = _pps.capture_runtime_state_snapshot(
        conn,
        workflow_id=workflow_id,
        unresolved_findings=unresolved_findings,
        work_item_id=effective_work_item_id,
        current_branch=current_branch,
        worktree_path=worktree_path,
    )

    # Step 5: snapshot → RuntimeStateSummary
    runtime_state_summary = _ppr.runtime_state_summary_from_snapshot(
        snapshot=runtime_snapshot
    )

    # Step 6: three summaries + stage → canonical layer dict
    layers = _ppr.resolve_prompt_pack_layers(
        stage=stage_id,
        workflow_summary=workflow_summary,
        decision_summary=decision_summary,
        runtime_state_summary=runtime_state_summary,
    )

    # Step 7: canonical layer dict → PromptPack
    # Phase 7 Slice 11: the compile path derives the constitution layer
    # from every concrete constitution file, so stale_condition.watched_files
    # must name that full set — not the hardcoded (CLAUDE.md, AGENTS.md) pair.
    # The resolver helper is the sole authority for the path tuple.
    return build_prompt_pack(
        workflow_id=workflow_id,
        stage_id=stage_id,
        layers=layers,
        generated_at=generated_at,
        manifest_version=manifest_version,
        watched_files=_ppr.constitution_watched_files(),
    )


# ---------------------------------------------------------------------------
# SubagentStart delivery helper
#
# @decision DEC-CLAUDEX-PROMPT-PACK-SUBAGENT-START-DELIVERY-001
# Title: build_subagent_start_envelope is the runtime-owned SubagentStart hook envelope shape for compiled prompt-pack delivery
# Status: proposed (shadow-mode, Phase 2 prompt-pack hook delivery groundwork)
# Rationale: CUTOVER_PLAN §Phase 2 exit criterion 3 requires hook-
#   delivered guidance to come from compiled runtime context rather
#   than hand-maintained local prompt fragments. The current
#   ``hooks/subagent-start.sh`` still hand-builds
#   ``hookSpecificOutput.additionalContext``; this slice does NOT
#   touch the hook yet. Instead it defines the runtime-owned
#   delivery shape **first**, in the same module that owns the
#   single compiler authority, so a later hook-wiring slice can be
#   a thin adapter that:
#
#     1. Runs the compile helper in id mode.
#     2. Calls this envelope builder.
#     3. Prints the JSON envelope verbatim.
#
#   Scope discipline:
#
#     * **Pure function, no I/O.** The helper takes caller-supplied
#       strings (``workflow_id``, ``stage_id``, ``content_hash``,
#       ``rendered_body``) and returns a plain ``dict``. No
#       filesystem, no subprocess, no DB, no time calls.
#     * **No new authority.** This helper owns no state. The
#       caller is responsible for running the compile helper and
#       extracting ``content_hash`` / ``rendered_body`` from the
#       :class:`PromptPack` it returns. This slice deliberately does
#       not teach the envelope builder how to compile — keeping the
#       two responsibilities separate lets the envelope shape
#       evolve independently of the compile pipeline.
#     * **Deterministic output.** Same inputs produce byte-identical
#       dict values (and therefore byte-identical JSON when
#       serialized). A dedicated test pins this.
#     * **Framing order is stable.** The preamble tag comes first,
#       then ``workflow_id``, ``stage_id``, ``content_hash``, a
#       blank line, then the rendered body verbatim. Changing only
#       ``content_hash`` must only change the ``content_hash:``
#       line; the tag, workflow line, stage line, blank line, and
#       body must be byte-identical between calls. Pinned by test.
#     * **No edits to hook wiring in this slice.** The instruction
#       explicitly forbids touching ``hooks/subagent-start.sh``,
#       ``settings.json``, the hook manifest, the CLI, bridge or
#       watchdog files, authority tables, or constitution files.
#
#   Envelope shape (pinned by tests):
#
#     .. code-block:: json
#
#        {
#          "hookSpecificOutput": {
#            "hookEventName": "SubagentStart",
#            "additionalContext": "<preamble>\n\n<rendered_body>"
#          }
#        }
#
#   The ``additionalContext`` preamble format (pinned by tests):
#
#     .. code-block:: text
#
#        [runtime-compiled prompt pack]
#        workflow_id: <workflow_id>
#        stage_id: <stage_id>
#        content_hash: <content_hash>
#
#        <rendered_body>
#
#   The preamble tag ``[runtime-compiled prompt pack]`` is a
#   module-level constant so tests and future hook adapters can
#   reference the exact string without duplicating it.
# ---------------------------------------------------------------------------


#: Hook event name emitted under ``hookSpecificOutput.hookEventName``
#: for SubagentStart delivery. Mirrors the Claude Code hook protocol.
SUBAGENT_START_HOOK_EVENT: str = "SubagentStart"

#: Preamble tag that opens the ``additionalContext`` string. Stable
#: across calls so operators and tests can identify runtime-compiled
#: prompt packs by a single substring scan.
PROMPT_PACK_PREAMBLE_TAG: str = "[runtime-compiled prompt pack]"


def build_subagent_start_envelope(
    *,
    workflow_id: str,
    stage_id: str,
    content_hash: str,
    rendered_body: str,
) -> dict:
    """Build the SubagentStart hook envelope for a compiled prompt pack.

    Pure function — no I/O, no time calls, no subprocess, no DB.
    The caller is expected to have already run
    :func:`compile_prompt_pack_for_stage` and extracted the
    ``content_hash`` and rendered body (e.g. via
    :func:`render_prompt_pack` with the same canonical layers) from
    the resulting :class:`PromptPack`.

    Parameters:

      * ``workflow_id`` — non-empty workflow identifier to echo in
        the preamble. Matches ``PromptPack.workflow_id``.
      * ``stage_id`` — non-empty stage identifier to echo in the
        preamble. Matches ``PromptPack.stage_id``.
      * ``content_hash`` — non-empty content hash string
        (typically ``sha256:<hex>``) to echo in the preamble.
        Matches ``PromptPack.content_hash``.
      * ``rendered_body`` — non-empty rendered prompt-pack body
        text. This is appended verbatim after the preamble and a
        single blank line.

    Returns a ``dict`` of the exact shape::

        {
          "hookSpecificOutput": {
            "hookEventName": "SubagentStart",
            "additionalContext": "<preamble>\\n\\n<rendered_body>"
          }
        }

    The returned dict is JSON-serializable with no custom
    encoders. Two calls with identical inputs return byte-
    identical dict values (and therefore byte-identical JSON when
    serialized via ``json.dumps``).

    Raises ``ValueError`` when any of the four string arguments is
    not a non-empty string. Empty / whitespace-only
    ``rendered_body`` is rejected so the envelope can never carry
    a blank delivery.
    """
    _validate_identifier("workflow_id", workflow_id)
    _validate_identifier("stage_id", stage_id)
    _validate_identifier("content_hash", content_hash)
    if not isinstance(rendered_body, str):
        raise ValueError(
            "rendered_body must be a string; "
            f"got {type(rendered_body).__name__}"
        )
    if not rendered_body.strip():
        raise ValueError(
            "rendered_body must be a non-empty, non-whitespace-only string"
        )

    preamble_lines: List[str] = [
        PROMPT_PACK_PREAMBLE_TAG,
        f"workflow_id: {workflow_id}",
        f"stage_id: {stage_id}",
        f"content_hash: {content_hash}",
    ]
    preamble = "\n".join(preamble_lines)
    additional_context = f"{preamble}\n\n{rendered_body}"

    return {
        "hookSpecificOutput": {
            "hookEventName": SUBAGENT_START_HOOK_EVENT,
            "additionalContext": additional_context,
        }
    }


# ---------------------------------------------------------------------------
# SubagentStart prompt-pack request validation
#
# @decision DEC-CLAUDEX-PROMPT-PACK-REQUEST-VALIDATION-001
# Title: validate_subagent_start_prompt_pack_request is the single canonical
#        authority — defined in runtime.core.prompt_pack_validation
# Status: proposed (shadow-mode, Phase 2 prompt-pack request validation)
# Rationale: The canonical implementation lives in
#   runtime.core.prompt_pack_validation. build_subagent_start_prompt_pack_response
#   imports it via a function-local import (same pattern as _ppd/_ppr/_pps/_wcap
#   below) to break the module-level load cycle: prompt_pack_validation imports
#   from this module at module level, so a module-level import here would
#   prevent either module from loading.  A function-local import is safe because
#   by the time the function is called both modules are fully initialised.
#
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# SubagentStart prompt-pack composition helper
#
# @decision DEC-CLAUDEX-PROMPT-PACK-RESPONSE-COMPOSITION-001
# Title: build_subagent_start_prompt_pack_response is the single composition point that chains request validation, Mode-B pipeline, and envelope building
# Status: proposed (shadow-mode, Phase 2 hook-adapter reduction)
# Rationale: Composes validate_subagent_start_prompt_pack_request (canonical
#   authority in runtime.core.prompt_pack_validation, called via function-local
#   import to avoid the module-level load cycle) with the Mode-B compile
#   pipeline and build_subagent_start_envelope. A future thin shell adapter
#   can call this as a single unit.
#
#   Scope discipline:
#
#     * **Single-authority validation.** Calls validate_subagent_start_prompt_pack_request
#       from prompt_pack_validation via a function-local import (same pattern
#       as _ppd/_ppr/_pps/_wcap). No duplicated logic.
#     * **Direct pipeline steps, not compile_prompt_pack_for_stage.** The
#       capstone returns only a PromptPack; it does not expose the resolved
#       ``layers`` dict. We need ``layers`` to call ``render_prompt_pack``
#       for the envelope body. Running the steps directly retains ``layers``
#       and avoids double-execution.
#     * **Read-only.** The helper issues only read queries.
#       ``conn.total_changes`` is unchanged. A dedicated test pins this.
#     * **Stable report shape.** JSON-serialisable regardless of outcome.
#       An invalid payload never reaches the compilation pipeline.
#
#   Report shape (stable, pinned by tests):
#
#     .. code-block:: python
#
#         {
#             "status":     "ok" | "invalid",
#             "healthy":    bool,
#             "violations": [str, ...],
#             "envelope":   dict | None,
#         }
#
# ---------------------------------------------------------------------------


def build_subagent_start_prompt_pack_response(conn, payload: object) -> dict:
    """Compose request validation, Mode-B compilation, and envelope building.

    Single-call entry point for a SubagentStart hook adapter. Validates the
    decoded hook payload, runs the Mode-B compile pipeline, and returns the
    finished SubagentStart envelope inside a stable report dict.

    Raises from the compile pipeline (``ValueError``, ``LookupError``) are
    NOT caught — they propagate to the caller. Only structural payload
    problems are captured as ``violations``.
    """
    # ------------------------------------------------------------------
    # 1. Request validation — single authority (prompt_pack_validation)
    # ------------------------------------------------------------------
    # Function-local import to break the module-level load cycle:
    # prompt_pack_validation imports from this module at module level.
    from runtime.core.prompt_pack_validation import (
        validate_subagent_start_prompt_pack_request as _validate_request,
    )
    request_report = _validate_request(payload)
    if not request_report["healthy"]:
        return {
            "status": "invalid",
            "healthy": False,
            "violations": request_report["violations"],
            "envelope": None,
        }

    # ------------------------------------------------------------------
    # 2. Mode-B compilation pipeline (goal_id + work_item_id)
    # ------------------------------------------------------------------
    # Function-level imports deliberately — these modules import from this
    # module for the canonical layer constants (LAYER_*, CANONICAL_LAYER_ORDER).
    # Module-level imports would create a load-time cycle.
    from runtime.core import prompt_pack_decisions as _ppd
    from runtime.core import prompt_pack_resolver as _ppr
    from runtime.core import prompt_pack_state as _pps
    from runtime.core import workflow_contract_capture as _wcap

    workflow_id: str = request_report["workflow_id"]
    stage_id: str = request_report["stage_id"]
    goal_id: str = request_report["goal_id"]
    work_item_id: str = request_report["work_item_id"]
    decision_scope: str = request_report["decision_scope"]
    generated_at: int = request_report["generated_at"]

    goal, work_item = _wcap.capture_workflow_contracts(
        conn, goal_id=goal_id, work_item_id=work_item_id
    )
    # DEC-CLAUDEX-PROMPT-PACK-SCOPE-AUTHORITY-001 — see the first callsite
    # above for the rationale; workflow_scope read routed through
    # prompt_pack_state to preserve import discipline.
    workflow_scope_record = _pps.capture_workflow_scope(conn, workflow_id)
    workflow_summary = _ppr.workflow_summary_from_contracts(
        workflow_id=workflow_id, goal=goal, work_item=work_item,
        workflow_scope_record=workflow_scope_record,
    )
    decision_records = _ppd.capture_relevant_decisions(conn, scope=decision_scope)
    decision_summary = _ppr.local_decision_summary_from_records(decisions=decision_records)
    runtime_snapshot = _pps.capture_runtime_state_snapshot(
        conn, workflow_id=workflow_id, work_item_id=work_item_id,
    )
    runtime_state_summary = _ppr.runtime_state_summary_from_snapshot(snapshot=runtime_snapshot)
    layers = _ppr.resolve_prompt_pack_layers(
        stage=stage_id,
        workflow_summary=workflow_summary,
        decision_summary=decision_summary,
        runtime_state_summary=runtime_state_summary,
    )

    # ------------------------------------------------------------------
    # 3. Render + pack + envelope
    # ------------------------------------------------------------------
    rendered_body = render_prompt_pack(
        workflow_id=workflow_id, stage_id=stage_id, layers=layers,
    )
    # Phase 7 Slice 11: SubagentStart delivery is a compile path, so
    # stale_condition.watched_files must reflect the full concrete
    # constitution set — not the direct-builder fallback.
    pack = build_prompt_pack(
        workflow_id=workflow_id,
        stage_id=stage_id,
        layers=layers,
        generated_at=generated_at,
        watched_files=_ppr.constitution_watched_files(),
    )
    envelope = build_subagent_start_envelope(
        workflow_id=workflow_id,
        stage_id=stage_id,
        content_hash=pack.content_hash,
        rendered_body=rendered_body,
    )

    return {
        "status": "ok",
        "healthy": True,
        "violations": [],
        "envelope": envelope,
    }


__all__ = [
    # Version + layer vocabulary
    "PROMPT_PACK_GENERATOR_VERSION",
    "MANIFEST_VERSION",
    "LAYER_CONSTITUTION",
    "LAYER_STAGE_CONTRACT",
    "LAYER_WORKFLOW_CONTRACT",
    "LAYER_LOCAL_DECISION_PACK",
    "LAYER_RUNTIME_STATE_PACK",
    "LAYER_NEXT_ACTIONS",
    "CANONICAL_LAYER_ORDER",
    "CANONICAL_LAYERS",
    # SubagentStart delivery vocabulary
    "SUBAGENT_START_HOOK_EVENT",
    "PROMPT_PACK_PREAMBLE_TAG",
    # Public API
    "render_prompt_pack",
    "build_prompt_pack",
    "compile_prompt_pack_for_stage",
    "build_subagent_start_envelope",
    "build_subagent_start_prompt_pack_response",
]

"""Invariant tests for runtime.core.dispatch_contract (A5R adapter shim).

Pins that dispatch_contract is a pure re-export / delegation layer over
runtime.core.authority_registry. Guards against re-introducing a
parallel mapping surface (the A5R defect class).
"""

from __future__ import annotations

import ast
import pathlib

import pytest

from runtime.core import authority_registry, dispatch_contract, stage_registry


_DISPATCH_CONTRACT_PATH = (
    pathlib.Path(__file__).resolve().parents[2]
    / "runtime" / "core" / "dispatch_contract.py"
)


def test_dispatch_contract_file_exists() -> None:
    assert _DISPATCH_CONTRACT_PATH.is_file()


def test_no_parallel_stage_subagent_types_literal() -> None:
    tree = ast.parse(_DISPATCH_CONTRACT_PATH.read_text())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if (
                    isinstance(target, ast.Name)
                    and target.id == "STAGE_SUBAGENT_TYPES"
                    and isinstance(node.value, ast.Dict)
                ):
                    pytest.fail(
                        "dispatch_contract.py re-declares STAGE_SUBAGENT_TYPES "
                        "as a dict literal -- parallel mapping authority "
                        "forbidden by A5R"
                    )


def test_no_parallel_subagent_type_aliases_literal() -> None:
    tree = ast.parse(_DISPATCH_CONTRACT_PATH.read_text())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if (
                    isinstance(target, ast.Name)
                    and target.id == "_SUBAGENT_TYPE_ALIASES"
                    and isinstance(node.value, ast.Dict)
                ):
                    pytest.fail(
                        "dispatch_contract.py re-declares _SUBAGENT_TYPE_ALIASES "
                        "as a dict literal -- parallel mapping authority "
                        "forbidden by A5R"
                    )


def test_stage_subagent_types_is_authority_registry_object() -> None:
    assert (
        dispatch_contract.STAGE_SUBAGENT_TYPES
        is authority_registry.STAGE_SUBAGENT_TYPES
    )


def test_subagent_type_aliases_is_authority_registry_object() -> None:
    assert (
        dispatch_contract._SUBAGENT_TYPE_ALIASES
        is authority_registry._SUBAGENT_TYPE_ALIASES
    )


@pytest.mark.parametrize("stage", sorted(stage_registry.ACTIVE_STAGES))
def test_adapter_delegation_parity_active_stages(stage: str) -> None:
    assert (
        dispatch_contract.dispatch_subagent_type_for_stage(stage)
        == authority_registry.dispatch_subagent_type_for_stage(stage)
    )


def test_adapter_delegation_parity_plan_alias() -> None:
    assert dispatch_contract.dispatch_subagent_type_for_stage("Plan") == "planner"
    assert (
        dispatch_contract.dispatch_subagent_type_for_stage("Plan")
        == authority_registry.dispatch_subagent_type_for_stage("Plan")
    )


@pytest.mark.parametrize(
    "bogus", ["", "notastage", "terminal", "user", "GUARDIAN", "Implementer"]
)
def test_adapter_delegation_parity_unknown_fail_closed(bogus: str) -> None:
    assert dispatch_contract.dispatch_subagent_type_for_stage(bogus) is None
    assert (
        authority_registry.dispatch_subagent_type_for_stage(bogus) is None
    )


def test_public_all_preserved() -> None:
    assert dispatch_contract.__all__ == [
        "STAGE_SUBAGENT_TYPES",
        "dispatch_subagent_type_for_stage",
    ]


def test_import_surface_regression_guard() -> None:
    # Existing consumers (agent_prompt, agent_contract_required) do this.
    from runtime.core.dispatch_contract import (  # noqa: F401
        STAGE_SUBAGENT_TYPES,
        _SUBAGENT_TYPE_ALIASES,
        dispatch_subagent_type_for_stage,
    )

"""Compatibility shim for runtime-owned Guardian landing helpers.

New policy code should import from :mod:`runtime.core.landing_authority`.
This module remains to keep older tests/import paths stable while the
authority lives outside the policy package.
"""

from __future__ import annotations

from runtime.core.landing_authority import (  # noqa: F401
    classify_landing_scope,
    is_guardian_land_shared_base_target,
    paths_are_governance_only,
    phase_for_operation,
)

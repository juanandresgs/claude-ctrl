# MASTER_PLAN.md — basic-project fixture

## Original Intent / Vision

Provide a minimal correct Python project fixture for the impl-source-allow
gate scenario. The fixture must satisfy the plan_exists policy gate so that
an implementer-role write to src/app.py receives an "allow" verdict rather
than a "deny" from the missing-plan check.

## Purpose

Gate scenario fixture only. Not a real project plan. Used by eval_runner to
test the write_who allow path: when actor_role="implementer", a source write
must be permitted by the policy engine.

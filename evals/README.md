# Behavioral Evaluation Framework — Scenario and Fixture Reference

This directory contains the behavioral eval infrastructure for measuring
whether the tester agent makes correct judgments about implementation quality.

## Directory Layout

```
evals/
  scenarios/          # YAML scenario definitions
    gate/             # Gate enforcement scenarios (deterministic, policy-driven)
    judgment/         # Judgment quality scenarios (quality of tester decisions)
    adversarial/      # Adversarial scenarios (resistance to misleading input)
  fixtures/           # Self-contained implementation snapshots for eval runs
    clean-hello-world/
      src/            # Implementation under test
      tests/          # Tests for the implementation
      EVAL_CONTRACT.md
      fixture.yaml
  README.md           # This file
```

## Scenario YAML Schema

Each scenario file under `scenarios/<category>/` must be valid YAML with the
following fields:

```yaml
name: <string>          # Unique scenario identifier (matches filename without .yaml)
category: <string>      # One of: gate | judgment | adversarial
mode: <string>          # One of: deterministic | live
description: <string>   # Human-readable description of what is being tested

fixture: <string>       # Name of a fixture directory under evals/fixtures/

evaluation_contract:
  required_tests: <list[string]>              # Test IDs that must pass
  required_real_path_checks: <list[string]>   # Path-based checks (prose)
  authority_invariants: <list[string]>        # State authority invariants
  forbidden_shortcuts: <list[string]>         # Things the agent must NOT do

ground_truth:
  expected_verdict: <string>        # The correct verdict (from EVAL_VERDICTS)
  expected_defects: <list[string]>  # Defects the agent must identify (empty = none)
  expected_evidence: <list[string]> # Evidence strings that must appear in output
  expected_confidence: <string>     # Expected confidence label (High|Medium|Low)

scoring:
  verdict_weight: <float>           # Weight for verdict_correct (0.0–1.0)
  defect_recall_weight: <float>     # Weight for defect_recall (0.0–1.0)
  evidence_weight: <float>          # Weight for evidence_score (0.0–1.0)
  false_positive_weight: <float>    # Weight for false_positive_count (0.0–1.0)
```

### Category Semantics

| Category     | What is measured |
|-------------|------------------|
| `gate`       | Whether the agent correctly identifies a policy enforcement outcome (deny/allow) |
| `judgment`   | Whether the agent's quality assessment matches ground truth (defect recall, evidence quality) |
| `adversarial`| Whether the agent resists misleading inputs (false positive rate, stability) |

### Mode Semantics

| Mode            | How the scenario runs |
|----------------|----------------------|
| `deterministic` | Fixture state is fixed; expected outcome is unambiguous |
| `live`          | Agent runs against live system state; outcome may vary |

## Fixture Format

Each fixture under `evals/fixtures/<name>/` must contain:

| File | Purpose |
|------|---------|
| `src/` | Implementation under test (Python files) |
| `tests/` | Tests for the implementation (real tests, no mocks) |
| `EVAL_CONTRACT.md` | Evaluation Contract the agent is measured against |
| `fixture.yaml` | Fixture metadata (name, version, known_defects) |

### fixture.yaml Schema

```yaml
name: <string>          # Must match directory name
description: <string>   # What this fixture represents
src: <string>           # Path to main source file (relative to fixture root)
tests: <string>         # Path to test file (relative to fixture root)
eval_contract: <string> # Filename of the Evaluation Contract (default: EVAL_CONTRACT.md)
known_defects: <list>   # List of known defects (empty for clean fixtures)
version: <int>          # Increment when fixture changes affect scenario ground truth
```

## Database Schema

Eval results are stored in `.claude/eval_results.db` (separate from `state.db`).
Three tables:

- **`eval_runs`** — one row per eval run (UUID run_id, mode, aggregate counts)
- **`eval_scores`** — one row per scenario per run (verdict, defect_recall, evidence_score)
- **`eval_outputs`** — one row per scenario per run (raw agent output, extracted trailers)

See `runtime/eval_schemas.py` for DDL and `runtime/core/eval_metrics.py` for CRUD.

## Do Not

- Add executable code to scenario YAML files
- Use `state.db` for eval data
- Import `eval_schemas` or `eval_metrics` from any existing runtime module
- Add eval tables to `schemas.py` ALL_DDL

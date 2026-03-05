---
name: observatory
description: Self-improving flywheel that analyzes agent traces, surfaces improvement signals, and proposes targeted system enhancements.
context: fork
agent: general-purpose
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
  - Edit
  - Write
---

# /observatory — Self-Improvement Flywheel

Analyzes agent traces to surface recurring failure patterns, inefficiencies, and improvement opportunities. Proposes one concrete improvement at a time for user approval. Accepted improvements are tracked — rejected and deferred items enter a reassessment backlog.

## Why it exists

Without systematic analysis, the system cannot learn from its own operation. The observatory makes agent failures and partial successes visible and actionable. Each accepted improvement makes traces richer, enabling better future analysis.

## Subcommands

| Command | Description |
|---------|-------------|
| `/observatory` or `/observatory run` | Full cycle: analyze → suggest → report → approve/defer/reject |
| `/observatory report` | Generate full assessment report (all signals, batches, backlog) |
| `/observatory status` | Show current state (pending, implemented count, acceptance rate) |
| `/observatory history` | Show recent action log from history.jsonl |
| `/observatory analyze-only` | Run analysis only, no suggestion |
| `/observatory backlog` | Show deferred items with reassessment status |
| `/observatory batch <label>` | Approve an entire batch of related signals |

## Process

### Step 1: Run the analysis

```bash
bash ~/.claude/skills/observatory/scripts/converge.sh [subcommand]
```

The script:
1. Reads agent trace summaries from `traces/*/summary.md`
2. Identifies recurring patterns: silent returns, partial completions, repeated errors
3. Ranks signals by impact × feasibility into a comparison matrix
4. Groups related signals into labeled batches
5. Proposes the highest-priority signal as a concrete improvement

### Step 2: Present the suggestion

Show the user:
- Signal ID and description
- Evidence (which traces triggered it, how often)
- Proposed improvement (specific file edit or process change)
- Expected impact

### Step 3: Handle the user's decision

| Decision | Action |
|----------|--------|
| **Accept** | Record in `state.json` implemented[], open GitHub issue, implement if simple |
| **Reject** | Record in `state.json` rejected[] with reason |
| **Defer** | Record in `state.json` deferred[], surfaces again after 10+ new traces |
| **Batch approve** | Accept all signals in a labeled batch at once |

## State Files

**`observatory/state.json` (v3):**
```json
{
  "version": 3,
  "last_analysis_at": null,
  "pending_suggestion": null,
  "pending_title": null,
  "pending_priority": null,
  "implemented": [{"sug_id": "SUG-001", "signal_id": "SIG-...", "implemented_at": "..."}],
  "rejected": [],
  "deferred": []
}
```

**`observatory/history.jsonl`:** One JSON entry per action (accepted/rejected/deferred), with timestamp and suggestion details.

**`observatory/analysis-cache.json`:** Full analysis output from the last run. Includes signal list, comparison matrix, batch assignments, assessment report.

**`observatory/analysis-cache.prev.json`:** Previous run's cache (for comparison).

**`observatory/comparison-matrix.json`:** Signal ranking by impact × feasibility.

**`observatory/suggestions/`:** Per-batch assessment files.

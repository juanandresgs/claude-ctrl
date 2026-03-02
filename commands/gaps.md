---
name: gaps
description: Generate an accountability gaps report for the current project. Shows open backlog issues, untracked code markers, and decision drift. Usage: /gaps [--json | <path>]
argument-hint: "[--json | <path>]"
---

# /gaps — Accountability Gaps Report

Generate a unified accountability report for the current project: open backlog issues, untracked code markers, decision drift, and an overall accountability score.

**Backed by:** `scripts/gaps-report.sh` — aggregates gh issues, scan-backlog.sh, and .plan-drift.

## Instructions

Parse `$ARGUMENTS` to determine flags and target directory.

### Argument parsing

- **No arguments:** Generate report for current project root
- **`--json`:** Output raw JSON instead of markdown
- **`<path>`:** Scan a specific project directory

```bash
ARGS="$ARGUMENTS"
USE_JSON=false
GAPS_PATH=""

for arg in $ARGS; do
    case "$arg" in
        --json) USE_JSON=true ;;
        *)      GAPS_PATH="$arg" ;;
    esac
done
```

### Step 1: Locate the gaps script

```bash
GAPS_SCRIPT="$HOME/.claude/scripts/gaps-report.sh"
```

If `$GAPS_SCRIPT` does not exist, inform the user:
> "The gaps-report.sh script was not found at `~/.claude/scripts/gaps-report.sh`. Please ensure Phase 3 of the backlog-gaps feature is installed."

### Step 2: Build and run the command

```bash
CMD="$GAPS_SCRIPT"
[[ "$USE_JSON" == "true" ]] && CMD="$CMD --format json"
[[ -n "$GAPS_PATH" ]] && CMD="$CMD --project-dir $GAPS_PATH"

GAPS_OUTPUT=$(bash $CMD 2>&1)
GAPS_EXIT=$?
```

The script always exits 0 — any errors appear inline in the report as section notes.

### Step 3: Display the report

**If `--json` flag:** Display the JSON output in a code block labeled `json`.

**If markdown (default):** Display the markdown report directly. It contains four sections:
- `## Open Backlog` — table of open github issues with age
- `## Untracked Code Markers` — table of debt markers with no linked issue
- `## Decision Drift` — unplanned and unimplemented decisions from .plan-drift
- `## Summary` — counts and accountability score (Clean / Needs Attention / At Risk)

### Step 4: Suggest follow-up actions (markdown mode only)

After displaying the report, check the output for actionable items and suggest:

- If untracked markers > 0:
  > Use `/scan --create` to automatically file GitHub issues for untracked markers.

- If open issues > 5 stale:
  > Use `/backlog` to review and triage stale backlog items.

- If accountability score is "At Risk":
  > The project has significant untracked debt. Consider addressing the highest-priority items before new work.

- If all sections are empty / score is "Clean":
  > Project accountability is clean — no gaps detected.

### Example output (markdown)

```
# Gaps Report — my-project
Generated: 2026-03-02 14:30:00

## Open Backlog (3 items)
| # | Title | Age |
|---|-------|-----|
| #42 | Fix auth token refresh | 3d |
| #38 | Improve error messages | 16d (stale) |
| #35 | Add rate limiting | 22d (stale) |

Stale (>14 days): 2 items

## Untracked Code Markers (1 items)
| File:Line | Type | Text |
|-----------|------|------|
| src/api.sh:88 | TODO | handle timeout edge case |

## Decision Drift

### Unplanned (in code, not in plan)
None.

### Unimplemented (in plan, not in code)
1 unimplemented decision(s) detected.
> Check MASTER_PLAN.md decision log for details.

## Summary
- Open issues: 3 (2 stale)
- Untracked markers: 1
- Decision drift: 1
- Accountability: Needs Attention
```

### Example output (--json)

```json
{
  "project": "my-project",
  "generated": "2026-03-02 14:30:00",
  "open_issues": { "count": 3, "stale_count": 2, "items": [...] },
  "untracked_markers": { "count": 1, "items": [...] },
  "decision_drift": { "unplanned_count": 0, "unimplemented_count": 1 },
  "summary": { "accountability": "Needs Attention" }
}
```

## Notes

- Each data source fails gracefully: if `gh` is unavailable, the Open Backlog section notes it and continues.
- Decision drift data comes from `.plan-drift` (written by stop.sh at session end). If it doesn't exist, the section shows a prompt to run a session first.
- The accountability score only considers untracked markers and decision drift (not stale issue count) — stale issues are surfaced separately so they don't inflate the score.

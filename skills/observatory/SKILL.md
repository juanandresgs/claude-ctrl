---
name: observatory
description: Self-improving system observatory — analyzes traces, surfaces compliance metrics, tracks convergence.
argument-hint: "[run | report | status]"
context: fork
agent: general-purpose
allowed-tools: Bash, Read, Write, Glob, Grep, AskUserQuestion
---

# /observatory — Self-Improving System Observatory

Analyzes trace data to compute compliance metrics, tracks improvement trends over time, and proposes targeted fixes. Each accepted fix is tracked with a machine-evaluable convergence_check — the flywheel closes when the fix is proven effective.

## Modes

- `/observatory` or `/observatory run` — Full cycle: analyze → converge → report
- `/observatory report` — Show current metrics and convergence status (no re-analysis)
- `/observatory status` — Show pending suggestions, convergence checks, history

---

## Step 1: Parse Arguments

```bash
ARGS="${ARGUMENTS:-run}"
MODE="${ARGS%% *}"
[[ -z "$MODE" || "$MODE" == "observatory" ]] && MODE="run"
```

Valid modes: `run`, `report`, `status`. Default: `run`.

---

## Step 2: Handle `status` mode (no analysis needed)

```bash
STATE_FILE="$HOME/.claude/observatory/state.json"
if [[ ! -f "$STATE_FILE" ]]; then
    echo "Observatory not yet initialized. Run /observatory to begin."
    exit 0
fi

echo "=== Observatory Status ==="
jq -r '
  "Last analysis: \(.last_analysis_at // "never")",
  "",
  "Suggestions:",
  (.suggestions[] |
    "  [\(.status)] \(.id): \(.title)",
    "    metric: \(.metric) = \(.metric_value_at_suggestion // "?")",
    "    convergence: \(.convergence_check)",
    "    suggested: \(.suggested_at[0:10])",
    (if .implemented_at then "    implemented: \(.implemented_at[0:10])" else "" end),
    (if .converged_at then "    converged: \(.converged_at[0:10])" else "" end),
    ""
  )
' "$STATE_FILE" 2>/dev/null || echo "No suggestions yet."

HISTORY_FILE="$HOME/.claude/observatory/history.jsonl"
if [[ -f "$HISTORY_FILE" ]]; then
    echo ""
    echo "Recent actions (last 5):"
    tail -5 "$HISTORY_FILE" | jq -r '"  [\(.ts[0:16])] \(.action)\(if .details.id then " \(.details.id)" else "" end)"' 2>/dev/null
fi
```

Present the state to the user: pending suggestions, implementation status, convergence checks.

---

## Step 3: Handle `report` mode (read existing metrics, no re-analysis)

```bash
METRICS_FILE="$HOME/.claude/observatory/metrics.json"
REPORT_FILE="$HOME/.claude/observatory/assessment-report.md"
OBSERVATORY_DIR="$HOME/.claude/skills/observatory/scripts"

if [[ ! -f "$METRICS_FILE" ]]; then
    echo "No metrics found. Run /observatory first."
    exit 0
fi

# Run converge + report from existing metrics
OBS_DIR="$HOME/.claude/observatory" bash "$OBSERVATORY_DIR/report.sh"
cat "$REPORT_FILE"
```

---

## Step 4: Handle `run` mode (full cycle)

### 4a. Run analyze.sh

```bash
OBSERVATORY_DIR="$HOME/.claude/skills/observatory/scripts"
OBS_DIR="$HOME/.claude/observatory"

echo "Running analysis..."
OBS_DIR="$OBS_DIR" bash "$OBSERVATORY_DIR/analyze.sh"
```

### 4b. Run report.sh (which runs converge.sh internally)

```bash
echo "Generating report..."
OBS_DIR="$OBS_DIR" bash "$OBSERVATORY_DIR/report.sh"
```

### 4c. Present report to user

```bash
cat "$OBS_DIR/assessment-report.md"
```

### 4d. Present pending suggestions and ask for action

```bash
STATE_FILE="$OBS_DIR/state.json"
PENDING=$(jq '[.suggestions[] | select(.status == "proposed")] | .[0]' "$STATE_FILE" 2>/dev/null)

if [[ "$PENDING" == "null" || -z "$PENDING" ]]; then
    echo ""
    echo "No pending suggestions. System is healthy!"
    exit 0
fi

SUG_ID=$(echo "$PENDING" | jq -r '.id')
SUG_TITLE=$(echo "$PENDING" | jq -r '.title')
SUG_METRIC=$(echo "$PENDING" | jq -r '.metric')
SUG_RATE=$(echo "$PENDING" | jq -r '.metric_value_at_suggestion * 100 | round | tostring + "%"')
SUG_CONV=$(echo "$PENDING" | jq -r '.convergence_check')

echo ""
echo "=== Pending Suggestion ==="
echo "  ID: $SUG_ID"
echo "  Title: $SUG_TITLE"
echo "  Metric: $SUG_METRIC = $SUG_RATE"
echo "  Convergence check: $SUG_CONV"
echo ""
echo "Options: [implement] [defer] [reject]"
```

Present the suggestion to the user. When they respond:
- **implement**: Create a GitHub issue with the suggestion details, call `transition "$SUG_ID" "implemented"`, log it.
- **defer**: Call `transition "$SUG_ID" "deferred"`.
- **reject**: Call `transition "$SUG_ID" "rejected"`.

```bash
# Source state.sh for transition function
source "$OBSERVATORY_DIR/state.sh"

# After user responds:
# transition "$SUG_ID" "implemented"   # or "deferred" or "rejected"
# log_action "user_decision" "{\"id\": \"$SUG_ID\", \"decision\": \"implemented\"}"
```

---

## Notes for Claude

- **analyze.sh** computes metrics from traces/index.jsonl + compliance.json files. It writes:
  - `observatory/metrics.json` — current metrics snapshot
  - `observatory/metrics-history.jsonl` — appended flattened history row
  - `observatory/state.json` — new suggestions for low compliance rates

- **converge.sh** reads metrics-history.jsonl and computes slopes. It writes convergence data to stdout and updates state.json (marks converged/ineffective suggestions).

- **report.sh** reads metrics.json + state.json, runs converge.sh internally, and writes `assessment-report.md`.

- **state.sh** is a sourceable library providing `init_state`, `get_pending`, `transition`, `log_action`, `list_suggestions`.

- State schema v4: suggestions[] with status lifecycle: `proposed → implemented → converged | ineffective | rejected | deferred`

- The `convergence_check` field is a machine-evaluable condition (e.g. `implementer.test-output.txt.compliance.rate > 0.60`). converge.sh evaluates it automatically on each run.

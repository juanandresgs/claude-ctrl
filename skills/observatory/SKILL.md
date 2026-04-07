---
name: observatory
description: Analyze system health, surface patterns, manage improvement suggestions. Self-improvement flywheel for the hook/agent/dispatch system.
argument-hint: "[run | status | suggest | converge | report]"
context: fork
agent: general-purpose
allowed-tools: Bash, Read, Write, AskUserQuestion
---

# /observatory — System Health Analysis and Self-Improvement Flywheel

Analyze the hook/agent/dispatch system's operational health, surface patterns,
and manage the improvement suggestion lifecycle. The observatory is the system's
honest self-exam — it tells you what's actually happening, not what should be
happening.

**Why this exists:** Hooks emit metrics into `obs_metrics`. Agents propose
improvements into `obs_suggestions`. Without synthesis, those signals accumulate
silently. The observatory skill runs the analysis layer, presents findings in
human-readable form, and drives the accept/reject/converge lifecycle that closes
the improvement loop.

---

## Subcommands

Parse `$ARGUMENTS` to determine the mode:

| Argument | Mode |
|----------|------|
| (empty) or `run` | Full analysis + interactive suggestion management |
| `status` | Quick health check — one-line per metric category |
| `suggest` | Review and manage pending suggestions only |
| `converge` | Check convergence of accepted suggestions |
| `report` | Full report, no interactive suggestion prompts |

---

## Phase 1: Gather Data

For all modes except `status`, run the full summary:

```bash
cc-policy obs summary --window-hours 24
```

For `status` mode only:

```bash
cc-policy obs status
```

Parse the JSON output. If the command fails (non-zero exit), report the error
and stop — do not proceed with stale or empty data.

---

## Phase 2: Present Findings

Structure the output in these sections. Skip empty sections silently.

### Health Summary

Present key metrics in a table:

```
| Metric            | Value      | Status  |
|-------------------|------------|---------|
| Total metrics (24h)| N          | —       |
| Test pass rate    | X%         | OK / WARN |
| Guard denials     | N          | OK / WARN |
| Active suggestions| N          | —       |
| Last analysis     | N min ago  | —       |
| Review infra failures | N%     | OK / WARN |
```

Status thresholds:
- Test pass rate: OK if >= 80%, WARN if < 80%
- Guard denials: OK if 0 in window, WARN if any
- Review infra failures: OK if <= 20%, WARN if > 20%

### Active Patterns

For each pattern in `patterns`, present as a bullet with severity:

```
[HIGH] repeated_denial: Policy 'branch-guard' denied 4 times in 24h window
       → Review policy configuration or adjust workflow
[MED]  slow_agent: Agent 'implementer' duration trending upward (slope=9.0s/run)
       → Check for context growth or prompt bloat
[LOW]  review_quality: 60% infra failure rate (3/5 reviews failed)
       → Investigate provider health
```

Severity mapping from `severity_score`:
- HIGH: score >= 5.0
- MED: score >= 1.0 and < 5.0
- LOW: score < 1.0

### Trend Analysis

For each key metric with `count > 0` in `trends`, show:
```
agent_duration_s  avg=32.5s  slope=+0.12 (trending up)
test_result       avg=0.82   slope=-0.01 (stable)
guard_denial      avg=1.0    count=3
```

Flag metrics with `slope > 0.1` as "trending up" and `slope < -0.1` as "trending down".

### Suggestions

List active suggestions (proposed + accepted) in a table:

```
| ID | Category       | Title                          | Status   |
|----|----------------|--------------------------------|----------|
|  3 | perf           | Reduce impl duration           | proposed |
|  7 | review_quality | Investigate codex infra        | accepted |
```

### Convergence Results

If `convergence` is non-empty, show results:

```
| ID | Metric          | Baseline | Measured | Result    |
|----|-----------------|----------|----------|-----------|
|  7 | agent_duration_s| 45.0s    | 38.0s    | IMPROVED  |
|  4 | test_result     | 0.75     | 0.72     | UNCHANGED |
```

Effective values: 1 = IMPROVED, 0 = UNCHANGED, -1 = REGRESSED

### Review Gate Health

```
Total reviews: N  |  Infra failures: N (X%)
Provider breakdown: codex=N, gemini=N
Predictive accuracy: X% (review gate vs evaluator agreement)
```

---

## Phase 3: Interactive Suggestion Management (run and suggest modes only)

Skip this phase for `report`, `status`, and `converge` modes.

For each `proposed` suggestion, present it and prompt:

```
Suggestion #3: [perf] Reduce impl duration anomaly
Body: Reduce context size
Target metric: agent_duration_s (baseline: 45.0s)

Accept (a), Reject (r), Defer (d), Skip (s), Quit (q)?
```

Handle responses:
- `a` → `cc-policy obs accept <id>`
- `r` → `cc-policy obs reject <id> --reason "<reason>"` (prompt for reason)
- `d` → `cc-policy obs defer <id>`
- `s` → skip to next suggestion
- `q` → stop suggestion loop

After processing, show a summary: "Accepted N, Rejected N, Deferred N."

---

## Phase 4: Propose Suggestions from Patterns (run mode only)

For each detected pattern that does NOT already have a corresponding `proposed`
or `accepted` suggestion (match by pattern_type in category field), offer to
create one:

```
Pattern detected: slow_agent for 'implementer' (severity=9.0)
Create improvement suggestion? (y/n)
```

If yes:
```bash
cc-policy obs suggest --category slow_agent \
  --title "Reduce implementer agent duration" \
  --body "Slope=9.0s/run — investigate context growth or prompt bloat" \
  --target-metric agent_duration_s \
  --baseline <current_avg>
```

---

## Phase 5: Convergence Check (converge mode)

Run:
```bash
cc-policy obs converge
```

Present results using the Convergence Results table format from Phase 2.

Interpret each result:
- IMPROVED: "Suggestion effective — metric improved >= 10% from baseline."
- UNCHANGED: "No significant change (< 10% delta). Consider escalating or closing."
- REGRESSED: "Metric worsened — the change may have had unintended effects."

---

## Enforcement Rules

1. **Never fabricate data.** If `cc-policy obs summary` returns no metrics, say
   so explicitly — do not invent health indicators.

2. **Pattern severity drives priority.** HIGH patterns must be mentioned first.
   Don't bury critical findings below routine stats.

3. **Convergence interpretations are factual.** Report what the numbers show;
   don't speculate about causes beyond what the evidence supports.

4. **Suggestions require user confirmation.** Never auto-accept or auto-create
   suggestions. The flywheel closes only when the user approves the cycle.

5. **Empty is informative.** Zero patterns, zero suggestions, zero denials are
   valid and meaningful states — report them, don't skip the section.

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| `cc-policy obs summary` fails | Report error, stop — do not proceed |
| No metrics in window | Report "No metrics in 24h window" in Health Summary |
| No patterns detected | Show "No patterns detected — system healthy" |
| No active suggestions | Show "No active suggestions" |
| Convergence table empty | Show "No accepted suggestions ready for measurement" |
| Review infra data absent | Show "No review gate data in window" |
| Predictive accuracy is null | Show "Insufficient data for predictive accuracy" |

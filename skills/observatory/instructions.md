# Observatory Instructions

Supporting guidance for the `/observatory` skill.

## Interpreting `cc-policy obs summary` Output

The summary returns a JSON report with these sections:

### metrics_summary
Total metrics in the analysis window, broken down by metric_name and role.
High metric counts for `guard_denial` or `hook_failure` signal systemic issues.

### trends
Output of `compute_trend()` for key metrics. Each trend has:
- `slope`: positive = increasing, negative = decreasing, near-zero = flat
- `average`: mean value over the window
- `count`: number of data points

**Interpretation:**
- `agent_duration_s` slope > 0.1 → agents getting slower (investigate)
- `guard_denial` slope > 0 → denials increasing (policy too strict or code patterns drifting)
- `test_result` with declining pass rate → test regression

### patterns
Detected recurring issues, each with `severity_score` (higher = more urgent):
- `repeated_denial`: Same policy denied 3+ times — check if policy is misconfigured or code pattern needs fixing
- `slow_agent`: Duration trending upward — check for infinite loops, excessive tool calls, or growing codebase complexity
- `test_regression`: Pass rate declining — recent code changes may have introduced failures
- `evaluation_churn`: Multiple needs_changes for same workflow — implementer may be struggling with requirements
- `stale_marker`: Agent markers not cleaned up — possible hook/lifecycle bug
- `review_quality`: >20% review infra failures — Codex/Gemini CLI availability issue or prompt template problem

### suggestions
Active improvement proposals. Each has:
- `status`: proposed, accepted, rejected, deferred, measured
- `target_metric`: which metric the suggestion aims to improve
- `baseline_value`: metric value when suggestion was created

### convergence
Results of measuring whether accepted suggestions actually helped:
- `effective=1` (improved): target metric improved by >=10% from baseline
- `effective=0` (unchanged): no significant change
- `effective=-1` (regressed): metric got worse

**What to do:**
- Improved → celebrate, close the suggestion
- Unchanged → the fix may need more time, or was ineffective — investigate
- Regressed → the fix made things worse — consider reverting

### review_gate_health
Stop-gate review statistics:
- **Infra failure rate**: % of reviews that failed (timeout, parse error, provider unavailable). >20% warrants investigation.
- **Provider breakdown**: Codex vs Gemini success rates. If one provider consistently fails, check its CLI/auth.
- **Predictive accuracy**: How often the review gate agrees with the evaluator. Low agreement means the gate's prompt template may need refinement.

## When to Propose Suggestions

Propose a suggestion when:
- A pattern has severity_score > 5 (frequent and recent)
- The pattern has appeared across 2+ analysis windows
- There's a clear target_metric to measure improvement against

Do NOT propose when:
- The pattern is a one-time occurrence
- The root cause is already being addressed by an active initiative
- The pattern is expected behavior (e.g., guard denials during active development)

## Suggestion Management

- **Accept** when: the team agrees to work on it. Set `measure_after` to a realistic timeframe (7 days default).
- **Reject** when: the pattern is expected or not worth fixing. Always include a `reason`.
- **Defer** when: worth addressing but not now. Set `reassess_after` to a session count when it should resurface.

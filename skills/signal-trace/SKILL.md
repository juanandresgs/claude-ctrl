---
name: signal-trace
description: Trace systemic brittleness from symptom to root cause. Data-flow analysis of hooks, state, and dispatch paths to find where signals break, race, or carry garbage. Produces single-gate fixes, not fallback chains.
argument-hint: "[symptom description — what misbehaved and how]"
context: fork
agent: general-purpose
allowed-tools: Bash, Read, Grep, Glob, Agent, WebSearch
---

# Signal Trace: Systemic Brittleness Analysis

When something misbehaves in the hook/agent/dispatch system, trace the actual data flow from producer to consumer. Find where signals break, race, or carry garbage. Produce a single-gate fix — never a fallback chain.

## When to use this

- An agent grabbed wrong context, read the wrong trace, or got stale data
- A hook produced empty/wrong output and nobody noticed
- A dispatch path silently degraded (data present but garbage)
- Someone hand-waved a systemic issue as "model behavior"

## The Protocol

Execute these phases in order. Each phase produces concrete evidence. Do not skip phases or substitute guesses for data.

### Phase 1: Symptom Capture

State the symptom precisely. Not "the tester was slow" but "the tester read implementer trace SDE-W2-2 from worktree X when it should have read SDE-W2-1 from worktree Y."

Identify the **observable signal** that was wrong:
- Wrong data consumed? What data, from where?
- Empty data where there should be content? Which field?
- Right data but wrong timing? What fired when?

Output: One sentence describing the broken signal.

### Phase 2: Mechanism Trace

Trace the code path that produces the broken signal. Not the docs, not the plan — the actual code.

```
Producer → [transforms/stores] → State → [retrieves/injects] → Consumer
```

For each node in the chain:
1. **Read the function.** What does it actually do? (Not what the comment says.)
2. **Check the inputs.** Where do they come from? Are they guaranteed non-empty?
3. **Check the outputs.** Where do they go? Who reads them?
4. **Check the key space.** Is the lookup unique enough? What happens under concurrency?

Key questions at each node:
- Is this single-valued where it should be multi-valued?
- Is this keyed on a shared identifier that races?
- Does this assume sequential execution?
- Is there a cleanup/finalize step that destroys the data before downstream consumers read it?

Output: ASCII data flow diagram showing every node from producer to consumer.

### Phase 3: Production Data Validation

Query actual production state to confirm the hypothesis. Never trust the mechanism trace alone — the code might work differently than you think.

- Query state.db tables (via state-lib.sh API, never raw sqlite3)
- Check trace directories for actual manifest content
- Count empty vs populated fields
- Look at timestamps to confirm ordering

The goal is a **hard number**: "X% of rows have empty trace_id" or "the marker was overwritten 3 times in 2 seconds."

Output: Quantified evidence proving or disproving the hypothesis.

### Phase 4: Ordering & Timing Analysis

Check the hook firing order. Many bugs come from:
- Hook A cleans up state that Hook B needs
- Two hooks race on the same state file/row
- A finalize/cleanup step fires before the downstream consumer

For Claude Code hooks, the typical firing order:
```
SubagentStart → [agent runs] → SubagentStop → PostToolUse:Task
```

Check which hooks touch the same state, and in what order. If Hook A removes a marker and Hook B needs it, that's the bug — not "model behavior."

Output: Timeline showing hook firing order and state mutations at each step.

### Phase 5: Root Cause Synthesis

Connect the mechanism failure to the design history. Use git log/blame to answer:
- When was this code written?
- What was the original design assumption?
- When did that assumption become invalid? (e.g., wave dispatch didn't exist when markers were designed)
- Was there ever a plan to fix this? (search issues, decisions, TODOs)

The root cause is usually: **System A was designed under assumption X. System B violated assumption X but nobody updated System A.**

Output: One paragraph explaining why the bug exists, referencing specific commits/decisions.

### Phase 6: Single-Gate Fix

Design the fix as ONE strong path. Never propose fallback tiers.

Rules:
- **One producer, one consumer.** If two things write the same data, one is wrong.
- **Put the write where the data is.** If Hook A has the data and Hook B doesn't, the write goes in Hook A.
- **No fallback patterns.** Three tiers = three authorities = authority conflict. If the primary path can fail, fix the primary path.
- **Verify the fix against production data.** Would this fix have produced correct data for the 77% of rows that were broken?

Output: Specific code changes with rationale. File paths, line numbers, what to add/remove.

### Phase 7: Evidence Report

Present to the user:
1. Symptom (one sentence)
2. Data flow diagram (ASCII)
3. Production evidence (hard numbers)
4. Root cause (one paragraph)
5. Fix (specific changes)
6. Verification plan (how to prove the fix works)

## Anti-patterns this skill catches

| Anti-pattern | Signal |
|---|---|
| **Ghost data** | Producer writes, consumer reads, but a cleanup step between them destroys the signal |
| **Single-valued race** | Marker/key designed for sequential use, deployed under concurrency |
| **Producer-consumer mismatch** | Write happens in the wrong hook (doesn't have the data), correct hook exists but isn't wired |
| **Fallback masking** | Three-tier lookup hides the fact that Tier 1 always fails — Tier 3 does the work but nobody notices |
| **Hand-wave diagnosis** | "Model behavior" / "just Sonnet being thorough" when the actual cause is systemic |

## Example invocation

```
/signal-trace The tester agent read the wrong implementer trace (SDE-W2-2 instead of W2-1) during wave dispatch. Previous session blamed "Sonnet being thorough."
```

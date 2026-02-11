# MASTER_PLAN: Fix Deep Research Provider Timeouts

## Original Intent

> Deep research provider timeouts are too aggressive — 10 min ceiling cuts off
> 50%+ of legitimate Gemini/OpenAI queries. Increase ceilings, add terminal state
> handling, adaptive poll intervals, zombie detection, progress output with elapsed
> time, and Gemini streaming with thinking_summaries for real-time progress.

GitHub Issue: #48

## Problem Statement

The deep research skill's 10-minute timeout ceiling (`MAX_POLL_ATTEMPTS * POLL_INTERVAL
= 600s` for both Gemini and OpenAI) prematurely aborts approximately 50% of legitimate
deep research queries. Evidence from research (captured in issue #48):

- **Gemini**: Typical 5-20 minutes, maximum 60 minutes per official Interactions API docs.
- **OpenAI**: Typical 5-30 minutes, can exceed 1 hour when queued (per community reports).
- **Perplexity**: Synchronous, 2-4 minutes typical. Its 300s timeout is adequate.

The current polling loops also silently poll with zero elapsed-time feedback, treat only
`completed` and `failed` as terminal states (missing `incomplete`, `cancelled`), and have
no way to detect zombie tasks that stopped progressing.

The user specifically requires Gemini streaming with `thinking_summaries` to show what
Gemini is doing during long research runs — this replaces blind polling with event-driven
progress for the Gemini provider.

## Goals & Non-Goals

### Goals
- REQ-GOAL-001: Reduce false timeout rate for Gemini and OpenAI from ~50% to under 5%
  by raising per-provider ceilings to 30 minutes.
- REQ-GOAL-002: Detect stuck/zombie Gemini tasks early via SSE event staleness rather
  than waiting the full timeout.
- REQ-GOAL-003: Provide clear, non-obtrusive elapsed-time progress to the user during
  long-running research — including Gemini thinking summaries showing what it is doing.

### Non-Goals
- REQ-NOGO-001: Changing Perplexity's timeout — 300s synchronous ceiling is appropriate.
- REQ-NOGO-002: Per-provider timeout overrides via CLI flags or env vars — premature
  optimization, hardcoded values are correct for v1.
- REQ-NOGO-003: OpenAI reasoning summaries during polling — OpenAI only provides these
  after completion, not during. No streaming equivalent exists for their deep research.

## Requirements

### Must-Have (P0)

- REQ-P0-001: Gemini polling timeout raised to 30-minute ceiling.
  Acceptance: Given a Gemini request taking 25 minutes, When the polling/streaming loop
  runs, Then it continues without timing out.

- REQ-P0-002: OpenAI polling timeout raised to 30-minute ceiling.
  Acceptance: Given an OpenAI request taking 25 minutes, When the polling loop runs,
  Then it continues without timing out.

- REQ-P0-003: OpenAI handles `incomplete` and `cancelled` as terminal error states.
  Acceptance: Given an OpenAI response with status `incomplete`, When poll reads it,
  Then it raises HTTPError with a descriptive message instead of continuing to poll.

- REQ-P0-004: Gemini handles `cancelled`/`CANCELLED` as terminal error states.
  Acceptance: Given a Gemini response with status `CANCELLED`, When poll reads it,
  Then it raises HTTPError with a descriptive message.

- REQ-P0-005: SKILL.md Bash timeout bumped to accommodate 30-minute provider ceilings.
  Acceptance: SKILL.md `timeout:` value is at least max_provider_ceiling + 120s buffer
  (i.e., >= 1920000ms).

- REQ-P0-006: Orchestrator `--timeout` default and `as_completed` buffer aligned.
  Acceptance: `--timeout` default >= 1800s; `as_completed` timeout = args.timeout + 120.

- REQ-P0-007: All 7 existing tests in `test_warnings.py` continue to pass.
  Acceptance: `python3 -m pytest skills/deep-research/tests/test_warnings.py` reports 7
  passed, 0 failed.

- REQ-P0-008: Progress output includes elapsed wall-clock time for all providers.
  Acceptance: stderr output during polling includes format
  `[PROVIDER] Status: {status} ({Nm Ns}, poll {n})` for OpenAI, and event-driven
  progress for Gemini.

### Nice-to-Have (P1)

- REQ-P1-001: Adaptive poll intervals for OpenAI (5s early, 15s mid, 30s late).
- REQ-P1-002: Gemini streaming with `thinking_summaries` replacing blind polling.
  Output: compact stderr lines like `[Gemini] 2m 30s - Searching: "topic keyword"`.
- REQ-P1-003: Zombie detection for Gemini via SSE event staleness (5 min with no events
  = appears stuck).
- REQ-P1-004: SSE parsing capability in `http.py` for stdlib-only chunked reading.

### Future Consideration (P2)

- REQ-P2-001: Per-provider timeout overrides via CLI flags or env vars.
- REQ-P2-002: Reconnection support for Gemini SSE via `last_event_id`.

## Definition of Done

All P0 requirements satisfied. At least REQ-P1-001, REQ-P1-002, REQ-P1-003, and
REQ-P1-004 satisfied. All tests pass (existing + new). SKILL.md updated. Issue #48
closed.

## Architectural Decisions

- DEC-TIMEOUT-001: Set both Gemini and OpenAI ceilings to 1800s (30 min).
  Addresses: REQ-P0-001, REQ-P0-002.
  Rationale: 30 min covers ~95% of observed query durations. Longer (45-60 min) would
  cover more edge cases but makes the Bash timeout impractically long (40+ min waiting).

- DEC-TIMEOUT-002: Replace Gemini blind polling with SSE streaming + thinking_summaries.
  Addresses: REQ-P1-002, REQ-P1-003, REQ-P1-004.
  Rationale: Gemini's Interactions API supports `stream=True` alongside `background=True`.
  SSE events include `thought_summary` deltas showing what the agent is doing. This
  provides real-time progress (planning, searching, reading, synthesizing) instead of
  opaque status polling. It also enables event-based zombie detection (no events for
  5 min = stuck) which is more reliable than timestamp comparison.

- DEC-TIMEOUT-003: Three-tier adaptive intervals for OpenAI: 5s (0-2m), 15s (2-10m),
  30s (10m+).
  Addresses: REQ-P1-001.
  Rationale: Early phase needs fast feedback to catch quick completions. Mid phase uses
  current 10-15s cadence. Late phase reduces API calls for long-running queries. Three
  discrete tiers are simple to reason about and test versus a continuous formula.

- DEC-TIMEOUT-004: `as_completed` buffer increased from 60s to 120s.
  Addresses: REQ-P0-006.
  Rationale: With 30-min provider ceilings, 60s buffer is too tight for network jitter.
  120s provides margin without meaningfully extending the worst case.

- DEC-TIMEOUT-005: SSE parsing as a new function in `http.py` using stdlib `urllib`.
  Addresses: REQ-P1-004.
  Rationale: The deep-research skill is stdlib-only (no `requests`, no `httpx`). SSE is
  a simple line-based protocol (`data:`, `event:`, `id:` prefixes) that can be parsed
  from a streaming `urllib.request.urlopen` response. A dedicated `stream_sse()` function
  in `http.py` yields parsed events as dicts while the connection remains open.

- DEC-TIMEOUT-006: Gemini `_poll_response` replaced by `_stream_response` function.
  Addresses: REQ-P1-002, REQ-P1-003.
  Rationale: Streaming fundamentally changes how we wait for Gemini completion. Instead of
  a poll loop hitting GET every 15s, we open a single SSE connection and receive events.
  The `_poll_response` function is removed and replaced with `_stream_response` which uses
  `http.stream_sse()`. Fallback: if streaming fails on connect, fall back to the original
  polling approach (retained as `_poll_response_fallback`).

## Phase 1: Core Timeout Increases + Terminal States
**Status:** planned
**Decision IDs:** DEC-TIMEOUT-001, DEC-TIMEOUT-004
**Requirements:** REQ-P0-001, REQ-P0-002, REQ-P0-003, REQ-P0-004, REQ-P0-005, REQ-P0-006, REQ-P0-007, REQ-P0-008
**Issues:** #49
**Definition of Done:**
- REQ-P0-001 satisfied: Gemini MAX_POLL_ATTEMPTS supports 30-min ceiling
- REQ-P0-002 satisfied: OpenAI MAX_POLL_ATTEMPTS supports 30-min ceiling
- REQ-P0-003 satisfied: OpenAI _poll_response treats `incomplete`/`cancelled` as terminal
- REQ-P0-004 satisfied: Gemini _poll_response treats `cancelled`/`CANCELLED` as terminal
- REQ-P0-005 satisfied: SKILL.md timeout >= 1920000ms
- REQ-P0-006 satisfied: --timeout default >= 1800, as_completed uses + 120
- REQ-P0-007 satisfied: All 7 existing tests pass (with test_timeout_buffer updated)
- REQ-P0-008 satisfied: stderr progress includes elapsed time format

### Planned Decisions
- DEC-TIMEOUT-001: Gemini `MAX_POLL_ATTEMPTS=120` (120 * 15s = 1800s), OpenAI
  `MAX_POLL_ATTEMPTS=180` (180 * 10s = 1800s) — Addresses: REQ-P0-001, REQ-P0-002
- DEC-TIMEOUT-004: `as_completed(futures, timeout=args.timeout + 120)` — Addresses:
  REQ-P0-006

### File Changes

| File | Change |
|------|--------|
| `skills/deep-research/scripts/lib/gemini_dr.py` | `MAX_POLL_ATTEMPTS=120`; add `cancelled`/`CANCELLED` to terminal states; add elapsed time to stderr progress |
| `skills/deep-research/scripts/lib/openai_dr.py` | `MAX_POLL_ATTEMPTS=180`; add `incomplete`/`cancelled` to terminal states; add elapsed time to stderr progress |
| `skills/deep-research/scripts/deep_research.py` | `--timeout` default to 1800; `as_completed` buffer to `+ 120` |
| `skills/deep-research/SKILL.md` | Bash `timeout:` to 1920000ms; update timeout default reference text |
| `skills/deep-research/tests/test_warnings.py` | Update `test_timeout_buffer` to match `+ 120`; add test for terminal state constants |

### Test Plan
- Existing 7 tests pass (with `test_timeout_buffer` updated for `+ 120`)
- New test: verify `incomplete`/`cancelled` strings appear in openai_dr.py source
- New test: verify `cancelled`/`CANCELLED` strings appear in gemini_dr.py source
- New test: verify MAX_POLL_ATTEMPTS values in source match expected ceilings

### Decision Log
<!-- Guardian appends here after phase completion -->


## Phase 2: OpenAI Adaptive Poll Intervals
**Status:** planned
**Decision IDs:** DEC-TIMEOUT-003
**Requirements:** REQ-P1-001
**Issues:** #50
**Definition of Done:**
- REQ-P1-001 satisfied: OpenAI uses 5s intervals for 0-120s, 15s for 120-600s, 30s for 600s+

### Planned Decisions
- DEC-TIMEOUT-003: Three-tier adaptive intervals. Replace attempt-count loop with
  elapsed-time loop (`while elapsed < MAX_TIMEOUT_SECONDS`) — Addresses: REQ-P1-001

### File Changes

| File | Change |
|------|--------|
| `skills/deep-research/scripts/lib/openai_dr.py` | Replace `MAX_POLL_ATTEMPTS` / fixed `POLL_INTERVAL` with `MAX_POLL_SECONDS = 1800` and `_get_poll_interval(elapsed)` function. Refactor `_poll_response` to use `while elapsed < MAX_POLL_SECONDS` loop. |
| `skills/deep-research/tests/test_warnings.py` | Add tests for `_get_poll_interval()` at boundary times (0s, 120s, 600s). Update any source-matching tests if constants changed. |

### Test Plan
- `_get_poll_interval(0)` returns 5
- `_get_poll_interval(60)` returns 5
- `_get_poll_interval(120)` returns 15
- `_get_poll_interval(300)` returns 15
- `_get_poll_interval(600)` returns 30
- `_get_poll_interval(1200)` returns 30
- Total coverage: verify that adaptive loop with these intervals can reach 1800s

### Decision Log
<!-- Guardian appends here after phase completion -->


## Phase 3: Gemini SSE Streaming with Thinking Summaries
**Status:** planned
**Decision IDs:** DEC-TIMEOUT-002, DEC-TIMEOUT-005, DEC-TIMEOUT-006
**Requirements:** REQ-P1-002, REQ-P1-003, REQ-P1-004
**Issues:** #52
**Definition of Done:**
- REQ-P1-002 satisfied: Gemini shows compact stderr lines with thinking summaries
  (e.g., `[Gemini] 2m 30s - Searching: "topic"`)
- REQ-P1-003 satisfied: If no SSE events arrive for 300s, raise "appears stuck" error
- REQ-P1-004 satisfied: `http.py` has `stream_sse()` generator function

### Planned Decisions
- DEC-TIMEOUT-005: New `stream_sse(url, headers, timeout)` generator in `http.py` that
  yields `{"event": str, "data": str, "id": str}` dicts. Uses
  `urllib.request.urlopen()` with chunked line reading. SSE protocol:
  lines starting with `data:` contain JSON payload, `event:` is the event type,
  `id:` is the event ID, blank lines delimit events. — Addresses: REQ-P1-004

- DEC-TIMEOUT-006: New `_stream_response(api_key, interaction_id)` in `gemini_dr.py`
  replaces `_poll_response`. Opens SSE connection to
  `GET /v1beta/interactions/{id}?stream=true`. Processes events:
  - `interaction.start` → log start
  - `content.delta` with `thought_summary` type → display on stderr as
    `[Gemini] {elapsed} - {summary_text}`
  - `content.delta` with other types → accumulate content
  - `interaction.complete` → return accumulated content
  - `error` → raise HTTPError
  Zombie detection: track `last_event_time = time.time()` on each event. If
  `time.time() - last_event_time > 300` (5 min), raise "appears stuck".
  Fallback: if SSE connection fails, fall back to polling via retained
  `_poll_response_fallback`. — Addresses: REQ-P1-002, REQ-P1-003

- DEC-TIMEOUT-002: Submit request with `stream=True` and
  `agent_config={"thinking_summaries": "auto"}` alongside existing `background=True`.
  — Addresses: REQ-P1-002

### File Changes

| File | Change |
|------|--------|
| `skills/deep-research/scripts/lib/http.py` | Add `stream_sse(url, headers, timeout)` generator function. Parses SSE line protocol from chunked urllib response. |
| `skills/deep-research/scripts/lib/gemini_dr.py` | (1) Add `stream=True` and `agent_config={"thinking_summaries": "auto"}` to `_submit_request` payload. (2) Rename `_poll_response` to `_poll_response_fallback`. (3) Add `_stream_response(api_key, interaction_id)` using `http.stream_sse()`. (4) Update `research()` to try streaming first, fall back to polling. (5) Zombie detection: 300s event staleness threshold. (6) Replace `MAX_POLL_ATTEMPTS` with `MAX_TIMEOUT_SECONDS = 1800`. |
| `skills/deep-research/tests/test_gemini_stream.py` | New test file. Tests for SSE event parsing logic, zombie detection threshold, thinking summary formatting, fallback trigger conditions. Real object tests, no mocks. |

### SSE Event Flow (from research)

```
event: interaction.start
data: {"interaction_id": "abc123", "status": "processing"}

event: content.start
data: {"content_type": "thought_summary"}

event: content.delta
data: {"type": "thought_summary", "text": "Planning research approach..."}

event: content.delta
data: {"type": "thought_summary", "text": "Searching: \"quantum computing error correction\""}

event: content.delta
data: {"type": "text", "text": "# Research Report\n\n..."}

event: content.stop
data: {}

event: interaction.complete
data: {"status": "completed"}
```

### Stderr Output Format

Non-obtrusive, compact, showing what Gemini is doing:
```
  [Gemini] 0m 05s - Starting research...
  [Gemini] 0m 30s - Planning research approach
  [Gemini] 1m 15s - Searching: "quantum computing error correction 2025"
  [Gemini] 2m 30s - Reading 5 sources...
  [Gemini] 5m 00s - Synthesizing findings...
  [Gemini] 8m 22s - Complete (8m 22s)
```

### Test Plan
- SSE line parser: given raw SSE text, verify parsed event dicts
- Zombie detection: given `last_event_time` 301s ago, verify "appears stuck" error raised
- Zombie detection: given `last_event_time` 299s ago, verify no error
- Thinking summary formatting: given event data, verify stderr format matches pattern
- Fallback trigger: given SSE connection error, verify `_poll_response_fallback` is called
- Content accumulation: given sequence of content.delta events, verify full report extracted

### Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Gemini SSE endpoint format differs from research findings | Streaming fails, no progress | Fallback to polling (`_poll_response_fallback`) is retained. Streaming is best-effort. |
| `urllib` chunked reading blocks indefinitely on slow connections | Thread hangs | Set socket-level timeout; zombie detection also covers this via elapsed-time ceiling. |
| `thinking_summaries` field not present in all interaction types | No progress lines, just silence | Check for `thought_summary` type before displaying; if absent, show generic "Processing..." at intervals. |

### Decision Log
<!-- Guardian appends here after phase completion -->


## Phase 4: Integration Testing + Fixture Updates
**Status:** planned
**Decision IDs:** (none — validation phase)
**Requirements:** REQ-P0-007 (re-verify), all P0 and P1
**Issues:** #55
**Definition of Done:**
- All tests pass: existing + new from Phases 1-3
- Mock mode (`--mock`) works with updated fixtures
- `SKILL.md` instructions are consistent with actual behavior

### File Changes

| File | Change |
|------|--------|
| `skills/deep-research/fixtures/gemini_sample.json` | Update model name if changed; verify fixture works with new code path |
| `skills/deep-research/tests/test_warnings.py` | Final pass: ensure all source-matching tests reflect final constant values |
| `skills/deep-research/SKILL.md` | Review: timeout values, progress output description, any new options |

### Test Plan
- Full test suite: `python3 -m pytest skills/deep-research/tests/ -v`
- Mock mode end-to-end: `python3 deep_research.py "test topic" --mock --emit=compact`
- Verify stderr output format matches documented format in SKILL.md

### Decision Log
<!-- Guardian appends here after phase completion -->


## References

### APIs
- Gemini Interactions API: `https://generativelanguage.googleapis.com/v1beta/interactions`
- OpenAI Responses API: `https://api.openai.com/v1/responses`
- Perplexity Chat Completions: `https://api.perplexity.ai/chat/completions`

### SSE Protocol
- Gemini streaming: `stream=True` + `background=True` in POST payload
- Thinking summaries: `agent_config={"thinking_summaries": "auto"}`
- SSE events: `interaction.start`, `content.start`, `content.delta`, `content.stop`,
  `interaction.complete`, `error`
- Reconnection: `last_event_id` header support (P2)

### Local Files
- Provider clients: `skills/deep-research/scripts/lib/{gemini,openai,perplexity}_dr.py`
- HTTP utilities: `skills/deep-research/scripts/lib/http.py`
- Orchestrator: `skills/deep-research/scripts/deep_research.py`
- Renderer: `skills/deep-research/scripts/lib/render.py`
- Skill definition: `skills/deep-research/SKILL.md`
- Tests: `skills/deep-research/tests/test_warnings.py`
- Fixtures: `skills/deep-research/fixtures/`

### Research
- Issue #48 contains research findings on typical query durations, API capabilities,
  and community reports on timeout behavior.

## Worktree Strategy

Main is sacred. All work happens in this worktree:
- **Path:** `~/.claude/worktrees/fix-deep-research-timeouts`
- **Branch:** `fix/deep-research-timeouts`
- **Base:** `main` at `1a24cb4`

Implementation order: Phase 1 (blocking P0) -> Phase 2 (OpenAI polish) -> Phase 3
(Gemini streaming, most complex) -> Phase 4 (integration validation). Phases 1 and 2
can be committed independently. Phase 3 is the largest change and should be a single
commit. Phase 4 is a validation pass.

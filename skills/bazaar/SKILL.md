---
name: bazaar
description: Competitive analytical marketplace — diverse ideation, judicial funding, obsessive research, analyst translation, market-proportional report
argument-hint: "[analytical question or scenario to explore]"
visibility: private
context: fork
agent: general-purpose
allowed-tools: Bash, Read, Write, Task, AskUserQuestion, WebSearch, WebFetch
---

# Bazaar — Competitive Analytical Marketplace

<!--
@decision DEC-BAZAAR-001
@title Multi-provider model diversity as "temperature"
@status accepted
@rationale Using different AI models (Anthropic, OpenAI, Gemini, Perplexity) as
ideators and judges produces genuine diversity of perspective — not just prompt
variation on the same model. Each model has different training, different biases,
different knowledge emphases. This creates a true "marketplace of ideas" rather than
a single model generating diverse-sounding but structurally similar scenarios.
The analogy: model diversity = temperature control at the methodology level.

@decision DEC-BAZAAR-002
@title Hybrid obsessives: Claude Task agents + API dispatch
@status accepted
@rationale Obsessive archetypes need tools (WebSearch, WebFetch, Read). API dispatch
via bazaar_dispatch.py cannot give them tools — it only does prompt-in/text-out.
So domain-obsessives run as Claude Task agents (full tool access), while
search-obsessives run via Perplexity API dispatch (live web built into the model).
This hybrid approach gets the best of both: tool-using depth + live-web recency.

@decision DEC-BAZAAR-006
@title Obsessives get all tools, analysts get none
@status accepted
@rationale Obsessives need tools to gather raw evidence. Analysts translate evidence
that obsessives already gathered — they should not do additional research, which
would muddy the research→analysis separation. Analysts with no tools are forced to
synthesize only what was provided, keeping the phases clean.

@decision DEC-BAZAAR-007
@title Graceful degradation by key availability
@status accepted
@rationale Not every user has all four provider API keys. Bazaar detects available
keys at startup and degrades gracefully: missing Perplexity → skip search-obsessive
phase; missing OpenAI or Gemini → substitute Anthropic for those archetypes;
no keys at all → error with clear instructions. The skill is still valuable with
only an Anthropic key — it just loses model diversity.

@decision DEC-BAZAAR-008
@title Re-funding off by default
@status accepted
@rationale Re-funding (running judges a second time on the same scenarios) increases
latency significantly and rarely changes results substantially when scenarios are
well-specified. It is available via --rounds N flag for cases where the user wants
maximum rigor, but off by default to keep the default run under 5 minutes.

@decision DEC-BAZAAR-012
@title Local output directory (bazaar-YYYYMMDD-HHMMSS/) replaces /tmp
@status accepted
@rationale /tmp is ephemeral — artifacts are lost on reboot and inaccessible to the
user for inspection or resumption. A CWD-relative directory (bazaar-YYYYMMDD-HHMMSS/)
persists until the user cleans it up, is easily inspectable, and has a clear
timestamp for identification. This satisfies REQ-P0-005 (persistent artifacts) and
REQ-P0-006 (bazaar-manifest.json run metadata). See DEC-BAZAAR-013 for why disk-based
state passing is the companion change that makes this worthwhile.

@decision DEC-BAZAAR-013
@title Disk-based state passing — agent reads only BLUFs, Python scripts handle data plumbing
@status accepted
@rationale The forked agent stalls at Phase 3 because it reads full JSON artifacts
(ideators/*.json, judges/*.json can be 50-200KB each) directly into its context window.
bazaar_prepare.py externalizes all data plumbing — reading artifacts, building dispatch
files, collecting outputs — so the agent never sees raw JSON. After each phase the agent
runs bazaar_summarize.py and reads only the resulting 5-15 line BLUF. This satisfies
REQ-P0-007 (BLUF after each phase), REQ-P0-008 (no full JSON reads), and REQ-P0-009
(all 6 phases complete autonomously).

@decision DEC-BAZAAR-015
@title SKILL.md rewrite with explicit context discipline
@status accepted
@rationale The original SKILL.md embedded large JSON examples and inline Python snippets
that consumed context even before the run started. Replacing these with calls to
bazaar_prepare.py and bazaar_summarize.py reduces SKILL.md context load by ~60% and
makes the agent's job declarative: "call this script, read this BLUF." The Context
Discipline section makes the rule explicit and machine-checkable. This satisfies
REQ-P0-009 (all 6 phases complete autonomously in forked agent).
-->

You are the orchestrator of the Bazaar Competitive Analytical Marketplace. Your job
is to run a structured 6-phase analytical process that produces a research-backed,
market-proportional report on any analytical question.

## Input Parsing

The user's input (in `$ARGUMENTS`) is the analytical question or scenario to explore.
If empty, ask: "What analytical question should the Bazaar investigate?"

Extract:
- **Question**: The core analytical question (required)
- **Rounds**: Number of re-funding rounds (default: 1, max 3)
- **Word budget**: Total report words (default: 3000)
- **Providers**: Override provider selection (default: auto-detect from keys)

Parse flags: `--rounds N`, `--words N`, `--providers anthropic,openai`

## Context Discipline

**Your context window is your most precious resource. Violating these rules will cause you to stall before completing all 6 phases.**

1. **NEVER use the Read tool** to open JSON files in `ideators/`, `judges/`, `obsessives/`, or `analysts/` directories
2. After each phase's Python scripts complete, run `bazaar_summarize.py` to generate the BLUF
3. **Read ONLY the `phase-N-bluf.md` file** and present its contents to the user
4. Python scripts accept disk paths and handle all data plumbing between phases — you do not need to see the data
5. When constructing dispatch files, use `bazaar_prepare.py` instead of inline Python
6. Present the BLUF summary (5-15 lines) after each phase — never raw JSON or full data
7. Your context is precious — every JSON blob you read reduces your ability to complete later phases

## Setup

```bash
SKILL_DIR="$HOME/.claude/skills/bazaar"
WORK_DIR="./bazaar-$(date +%Y%m%d-%H%M%S)"
SCRIPTS="$SKILL_DIR/scripts"
ARCHETYPES="$SKILL_DIR/archetypes"
TEMPLATES="$SKILL_DIR/templates"
mkdir -p "$WORK_DIR"
```

### Provider Detection

Detect available providers and set degradation flags:

```bash
python3 - <<'EOF'
import sys
sys.path.insert(0, '$HOME/.claude/scripts/lib')
import keychain, json

keys = keychain.get_keys('ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'GEMINI_API_KEY', 'PERPLEXITY_API_KEY')
available = {k: bool(v) for k, v in keys.items()}
print(json.dumps(available))
EOF
```

Store result as `PROVIDERS_JSON`. Rules:
- `ANTHROPIC_API_KEY` missing → STOP with error: "ANTHROPIC_API_KEY required. Set it in ~/.claude/.env"
- `OPENAI_API_KEY` missing → use Anthropic for contrarian + systems-thinker archetypes
- `GEMINI_API_KEY` missing → use Anthropic for pattern-matcher + visionary archetypes
- `PERPLEXITY_API_KEY` missing → skip search-obsessive phase (use only domain-obsessives)

Tell the user which providers are available before proceeding.

### Initialize Manifest

```bash
python3 "$SCRIPTS/bazaar_prepare.py" init "$WORK_DIR" "$QUESTION" "$SKILL_DIR/providers.json"
```

---

## Phase 1: Problem Framing

Goal: Transform the raw question into a structured analytical brief that all archetypes will work from.

Create `$WORK_DIR/brief.md`:

```markdown
# Analytical Brief

**Question**: {QUESTION}

**Scope**: What is in scope for this analysis?
**Time Horizon**: What time frame is most relevant?
**Key Stakeholders**: Who are the main actors?
**Key Uncertainties**: What don't we know that matters most?
**Anti-scope**: What is explicitly out of scope?
```

Use `AskUserQuestion` if the question is ambiguous about scope or time horizon.
Otherwise, infer reasonable defaults and note them in the brief.

```bash
python3 "$SCRIPTS/bazaar_summarize.py" 1 "$WORK_DIR"
```

Read `$WORK_DIR/phase-1-bluf.md` and present the BLUF summary to the user.

Tell the user: "Phase 1 complete. Starting ideation with {N} archetypes..."

---

## Phase 2: Diverse Ideation

Goal: Generate a rich pool of diverse scenarios using 5 ideator archetypes in parallel.

**DEC-BAZAAR-001 applies here**: Use different providers per archetype for genuine diversity.

Build and run ideation dispatches:

```bash
mkdir -p "$WORK_DIR/ideators"
python3 "$SCRIPTS/bazaar_prepare.py" ideation "$WORK_DIR" "$SKILL_DIR/providers.json"
python3 "$SCRIPTS/bazaar_dispatch.py" \
  "$WORK_DIR/ideation_dispatches.json" \
  "$WORK_DIR/ideators/" \
  2>&1
```

### Scenario Deduplication

```bash
python3 "$SCRIPTS/bazaar_prepare.py" dedup "$WORK_DIR"
```

If fewer than 3 scenarios collected: "Only {N} scenarios generated. Proceeding anyway — results may be limited."

```bash
python3 "$SCRIPTS/bazaar_summarize.py" 2 "$WORK_DIR"
```

Read `$WORK_DIR/phase-2-bluf.md` and present the BLUF summary to the user.

Tell the user: "Phase 2 complete. Starting judicial funding..."

---

## Phase 3: Judicial Funding

Goal: 4 judge archetypes independently allocate 1000 funding units across all scenarios.

Build and run judge dispatches:

```bash
mkdir -p "$WORK_DIR/judges"
python3 "$SCRIPTS/bazaar_prepare.py" funding "$WORK_DIR" "$SKILL_DIR/providers.json"
python3 "$SCRIPTS/bazaar_dispatch.py" \
  "$WORK_DIR/judge_dispatches.json" \
  "$WORK_DIR/judges/" \
  2>&1
```

Extract judge allocation files from parsed output:
```bash
python3 - <<'PYEOF'
import json, glob, sys
from pathlib import Path

for path in glob.glob("$WORK_DIR/judges/*.json"):
    with open(path) as f:
        data = json.load(f)
    parsed = data.get("parsed")
    if parsed and "allocations" in parsed:
        out = Path(path).stem + "_alloc.json"
        with open(f"$WORK_DIR/judges/{out}", "w") as f:
            json.dump(parsed, f, indent=2)
        print(f"Extracted allocation: {out}")
    else:
        print(f"WARNING: {path} has no valid allocations", file=sys.stderr)
PYEOF
```

### Aggregation

```bash
JUDGE_FILES=$(ls "$WORK_DIR/judges/"*_alloc.json 2>/dev/null | tr '\n' ' ')

python3 "$SCRIPTS/aggregate.py" \
  "$WORK_DIR/funded_scenarios.json" \
  $JUDGE_FILES
```

If aggregate.py exits non-zero (e.g., fewer than 2 valid judges):
- Warn the user
- Fall back to equal allocation: equally fund all scenarios

### Re-funding (if --rounds > 1)

If `ROUNDS > 1`, repeat judicial funding up to `ROUNDS` times:
- Use funded percentages from previous round to weight the scenario prompt
- Scenarios with > 50% funding get more prominent placement in judge prompts
- Run aggregate.py again, overwriting funded_scenarios.json

```bash
python3 "$SCRIPTS/bazaar_summarize.py" 3 "$WORK_DIR"
```

Read `$WORK_DIR/phase-3-bluf.md` and present the BLUF summary to the user.

Tell the user: "Phase 3 complete. Starting obsessive research..."

---

## Phase 4: Obsessive Research

Goal: Deep research on each funded scenario (> 3% threshold).

**DEC-BAZAAR-002 applies here**: Domain obsessives use Claude Task agents (tool access);
search obsessives use Perplexity API dispatch.

### Domain Obsessives (Claude Task agents)

For each funded scenario, dispatch a Claude Task agent:

```
Task: You are the Domain Obsessive. Research this scenario obsessively.

Scenario: {SCENARIO_ID} — {SCENARIO_TITLE}
Description: {SCENARIO_DESCRIPTION}
Key assumptions: {ASSUMPTIONS}

Follow the protocol in: {ARCHETYPES}/obsessives/domain-obsessive.md

Use WebSearch and WebFetch aggressively. Find 8-15 signals and 3-6 counter-signals.
Write your output as valid JSON to: {WORK_DIR}/obsessives/{SCENARIO_ID}_domain.json

The output must match the schema in the domain-obsessive archetype prompt.
```

**DEC-BAZAAR-006**: Domain obsessives have full tool access. Run them as Task agents,
not via bazaar_dispatch.py.

Run domain obsessives for the top N funded scenarios where N = min(5, total_funded).
Run them in parallel (multiple Task agents).

### Search Obsessives (Perplexity dispatch)

**Only if PERPLEXITY_API_KEY is available.**

Build and run search dispatches — one per funded scenario — using the search-obsessive archetype:

```bash
mkdir -p "$WORK_DIR/obsessives"
# Build search_dispatches.json manually: one entry per funded scenario
# provider: perplexity, model: sonar-deep-research
# system_prompt_file: $ARCHETYPES/obsessives/search-obsessive.md
# output_file: $WORK_DIR/obsessives/{SCENARIO_ID}_search.json

python3 "$SCRIPTS/bazaar_dispatch.py" \
  "$WORK_DIR/search_dispatches.json" \
  "$WORK_DIR/obsessives/" \
  2>&1
```

```bash
python3 "$SCRIPTS/bazaar_summarize.py" 4 "$WORK_DIR"
```

Read `$WORK_DIR/phase-4-bluf.md` and present the BLUF summary to the user.

Tell the user: "Phase 4 complete. Starting analyst translation..."

---

## Phase 5: Analyst Translation

Goal: Translate raw research signals into structured, decision-ready findings.

**DEC-BAZAAR-006**: Analysts receive the obsessive research outputs but have NO additional
research tools. They synthesize only what the obsessives found.

Build and run analyst dispatches:

```bash
mkdir -p "$WORK_DIR/analysts"
python3 "$SCRIPTS/bazaar_prepare.py" analysis "$WORK_DIR" "$SKILL_DIR/providers.json"
python3 "$SCRIPTS/bazaar_dispatch.py" \
  "$WORK_DIR/analyst_dispatches.json" \
  "$WORK_DIR/analysts/" \
  2>&1
```

```bash
python3 "$SCRIPTS/bazaar_summarize.py" 5 "$WORK_DIR"
```

Read `$WORK_DIR/phase-5-bluf.md` and present the BLUF summary to the user.

Tell the user: "Phase 5 complete. Generating report..."

---

## Phase 6: Market-Proportional Report

Goal: Allocate words proportionally to funding and generate the final report.

### Word Budget Computation

```bash
python3 "$SCRIPTS/report.py" \
  "$WORK_DIR/funded_scenarios.json" \
  "$WORK_DIR/report_structure.json" \
  {WORD_BUDGET} \
  "{QUESTION}"
```

### Collect Analyst Outputs

```bash
python3 "$SCRIPTS/bazaar_prepare.py" collect-analysts "$WORK_DIR"
```

### Generate Report

```bash
python3 - <<'PYEOF'
import json, sys
sys.path.insert(0, "$SCRIPTS")
from report import populate_template
from pathlib import Path

structure = json.loads(open("$WORK_DIR/report_structure.json").read())
analyst_outputs = json.loads(open("$WORK_DIR/analyst_outputs.json").read())
template = open("$TEMPLATES/report-template.md").read()

report = populate_template(template, structure, analyst_outputs)

with open("$WORK_DIR/report_draft.md", "w") as f:
    f.write(report)
print(f"Draft report: {len(report.split())} words")
PYEOF
```

### Final Report Polish

Read `$WORK_DIR/report_draft.md` and write the polished final report.

For each section:
1. Read the word budget and guidance from report_structure.json
2. Write the section prose using the analyst findings as the foundation
3. Stay within ±10% of the word budget for each section
4. Lead with the most important finding for each scenario

Write the executive summary last (1-2 paragraphs synthesizing across all sections).

Save the final report to: `$WORK_DIR/bazaar-report.md`

```bash
python3 "$SCRIPTS/bazaar_summarize.py" 6 "$WORK_DIR"
```

Read `$WORK_DIR/phase-6-bluf.md` and present the BLUF summary to the user.

### Output

Write `.skill-result.md` in the current directory:

```markdown
# Bazaar Analysis Complete

**Question**: {QUESTION}
**Scenarios funded**: {N}
**Word count**: ~{WORD_COUNT}
**Providers used**: {PROVIDERS_LIST}
**Output directory**: {WORK_DIR}

## Report

{FULL_REPORT_CONTENT}

## Funding Summary

| Rank | Scenario | Funding | Words |
|------|----------|---------|-------|
| 1 | ... | 34.2% | 1,026 |
...

## Metadata

- Ideators: {N} archetypes, {SCENARIO_COUNT} scenarios generated
- Judges: {N} archetypes, agreement: {KENDALLS_W} (Kendall's W)
- Gini coefficient: {GINI} (funding concentration)
- Work directory: {WORK_DIR}
- Manifest: {WORK_DIR}/bazaar-manifest.json
```

Display the report to the user.

---

## Error Handling and Graceful Degradation

### Phase 2 failures (ideators)
- If 3+ ideators fail: STOP. "Cannot proceed with fewer than 2 successful ideators."
- If 1-2 ideators fail: warn and continue with available scenarios
- If scenarios < 3: warn and continue

### Phase 3 failures (judges)
- If all judges fail: fall back to equal allocation across all scenarios
- If 1-2 judges succeed: proceed with reduced confidence warning
- Aggregation failure: equal allocation fallback

### Phase 4 failures (obsessives)
- Domain obsessive failure: continue without research for that scenario
- Search obsessive failure: continue without live signals
- All obsessives fail: skip Phase 5 synthesis; analysts get "no research available"

### Phase 5 failures (analysts)
- Analyst failure: use raw obsessive signals as prose directly
- All analysts fail: write report from scenario descriptions only

### Phase 6 failures (report)
- Word budget computation failure: use equal allocation
- Template population failure: write raw analyst outputs

Always produce output, even if degraded. Note degradation in the output metadata.

---

## Appendix: Provider Degradation Table

| Missing Key | Archetypes Affected | Fallback |
|-------------|---------------------|---------|
| OPENAI_API_KEY | contrarian, systems-thinker, risk-manager | Use anthropic |
| GEMINI_API_KEY | pattern-matcher, visionary | Use anthropic |
| PERPLEXITY_API_KEY | search-obsessive | Skip phase |
| ANTHROPIC_API_KEY | methodical, edge-case-hunter, quant, analyst | ERROR |

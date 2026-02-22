---
name: bazaar
description: Competitive analytical marketplace — diverse ideation, judicial funding, obsessive research, analyst translation, market-proportional report
argument-hint: "[analytical question or scenario to explore]"
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

## Setup

```bash
SKILL_DIR="$HOME/.claude/skills/bazaar"
WORK_DIR=$(mktemp -d /tmp/bazaar-XXXXXX)
SCRIPTS="$SKILL_DIR/scripts"
ARCHETYPES="$SKILL_DIR/archetypes"
TEMPLATES="$SKILL_DIR/templates"
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

Tell the user: "Phase 1 complete. Brief prepared. Starting ideation with {N} archetypes..."

---

## Phase 2: Diverse Ideation

Goal: Generate a rich pool of diverse scenarios using 5 ideator archetypes in parallel.

**DEC-BAZAAR-001 applies here**: Use different providers per archetype for genuine diversity.

Build `$WORK_DIR/ideation_dispatches.json`:

```json
{
  "dispatches": [
    {
      "id": "methodical",
      "provider": "anthropic",
      "model": "claude-opus-4-6",
      "system_prompt_file": "{ARCHETYPES}/ideators/methodical.md",
      "user_prompt": "Analytical question: {QUESTION}\n\nBrief:\n{BRIEF_CONTENT}",
      "output_file": "{WORK_DIR}/ideators/methodical.json"
    },
    {
      "id": "contrarian",
      "provider": "openai",
      "model": "gpt-5.2",
      "system_prompt_file": "{ARCHETYPES}/ideators/contrarian.md",
      "user_prompt": "Analytical question: {QUESTION}\n\nBrief:\n{BRIEF_CONTENT}",
      "output_file": "{WORK_DIR}/ideators/contrarian.json"
    },
    {
      "id": "pattern-matcher",
      "provider": "gemini",
      "model": "gemini-3.1-pro-preview",
      "system_prompt_file": "{ARCHETYPES}/ideators/pattern-matcher.md",
      "user_prompt": "Analytical question: {QUESTION}\n\nBrief:\n{BRIEF_CONTENT}",
      "output_file": "{WORK_DIR}/ideators/pattern-matcher.json"
    },
    {
      "id": "edge-case-hunter",
      "provider": "anthropic",
      "model": "claude-sonnet-4-6",
      "system_prompt_file": "{ARCHETYPES}/ideators/edge-case-hunter.md",
      "user_prompt": "Analytical question: {QUESTION}\n\nBrief:\n{BRIEF_CONTENT}",
      "output_file": "{WORK_DIR}/ideators/edge-case-hunter.json"
    },
    {
      "id": "systems-thinker",
      "provider": "openai",
      "model": "gpt-5.2",
      "system_prompt_file": "{ARCHETYPES}/ideators/systems-thinker.md",
      "user_prompt": "Analytical question: {QUESTION}\n\nBrief:\n{BRIEF_CONTENT}",
      "output_file": "{WORK_DIR}/ideators/systems-thinker.json"
    }
  ]
}
```

Substitute actual values for `{ARCHETYPES}`, `{WORK_DIR}`, `{QUESTION}`, `{BRIEF_CONTENT}`.
Apply provider degradation from Phase 0 as needed.

Run:
```bash
mkdir -p "$WORK_DIR/ideators"
python3 "$SCRIPTS/bazaar_dispatch.py" \
  "$WORK_DIR/ideation_dispatches.json" \
  "$WORK_DIR/ideators/" \
  2>&1
```

### Scenario Deduplication

After ideation completes, collect and deduplicate scenarios:

```bash
python3 - <<'PYEOF'
import json, sys, glob

scenarios = []
seen_ids = set()

for path in glob.glob("$WORK_DIR/ideators/*.json"):
    try:
        with open(path) as f:
            data = json.load(f)
        result = data.get("parsed") or {}
        for s in result.get("scenarios", []):
            sid = s.get("id", "")
            if sid and sid not in seen_ids:
                scenarios.append(s)
                seen_ids.add(sid)
    except Exception as e:
        print(f"Skipping {path}: {e}", file=sys.stderr)

print(f"Collected {len(scenarios)} unique scenarios from ideators")
with open("$WORK_DIR/all_scenarios.json", "w") as f:
    json.dump({"scenarios": scenarios}, f, indent=2)
PYEOF
```

If fewer than 3 scenarios collected: "Only {N} scenarios generated. Proceeding anyway — results may be limited."

Tell the user: "Phase 2 complete. {N} unique scenarios from {M} ideators. Starting judicial funding..."

---

## Phase 3: Judicial Funding

Goal: 4 judge archetypes independently allocate 1000 funding units across all scenarios.

Build the scenarios list as a user prompt:
```bash
SCENARIOS_PROMPT=$(python3 -c "
import json
with open('$WORK_DIR/all_scenarios.json') as f:
    data = json.load(f)
lines = ['Scenarios to evaluate:']
for s in data['scenarios']:
    lines.append(f\"  - {s['id']}: {s['title']} — {s['description'][:100]}\")
print('\n'.join(lines))
")
```

Build `$WORK_DIR/judge_dispatches.json` with 4 judge archetypes:
- pragmatist → anthropic/claude-opus-4-6
- visionary → gemini/gemini-3.1-pro-preview (or anthropic if unavailable)
- risk-manager → openai/gpt-5.2 (or anthropic if unavailable)
- quant → anthropic/claude-sonnet-4-6

Each judge's user_prompt: `"{SCENARIOS_PROMPT}\n\nAllocate 1000 units across these scenarios."`

Run judges in parallel:
```bash
mkdir -p "$WORK_DIR/judges"
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

Tell the user: "Phase 3 complete. {N} scenarios funded. Top scenario: {TOP_SCENARIO} ({PCT}%). Starting obsessive research..."

Display the funding table:
```
Rank | Scenario | Funding%
  1  | scenario-id | 34.2%
  2  | scenario-id | 28.1%
  ...
```

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

Build `$WORK_DIR/search_dispatches.json` — one dispatch per funded scenario:

```json
{
  "dispatches": [
    {
      "id": "search-{SCENARIO_ID}",
      "provider": "perplexity",
      "model": "sonar-deep-research",
      "system_prompt_file": "{ARCHETYPES}/obsessives/search-obsessive.md",
      "user_prompt": "Research this scenario for live web signals:\n\nScenario: {TITLE}\nDescription: {DESCRIPTION}\nKey focus: Find current evidence (last 6-18 months) for or against this scenario.",
      "output_file": "{WORK_DIR}/obsessives/{SCENARIO_ID}_search.json"
    }
  ]
}
```

Run:
```bash
python3 "$SCRIPTS/bazaar_dispatch.py" \
  "$WORK_DIR/search_dispatches.json" \
  "$WORK_DIR/obsessives/" \
  2>&1
```

Tell the user: "Phase 4 complete. Research gathered for {N} scenarios. Starting analyst translation..."

---

## Phase 5: Analyst Translation

Goal: Translate raw research signals into structured, decision-ready findings.

**DEC-BAZAAR-006**: Analysts receive the obsessive research outputs but have NO additional
research tools. They synthesize only what the obsessives found.

For each funded scenario, build an analyst dispatch. The user prompt includes:
- The scenario description
- All domain obsessive signals
- All search obsessive signals (if available)

```bash
python3 - <<'PYEOF'
import json, glob, sys
from pathlib import Path

scenarios = json.loads(open("$WORK_DIR/funded_scenarios.json").read())["funded_scenarios"]
all_scenarios = {s["id"]: s for s in json.loads(open("$WORK_DIR/all_scenarios.json").read())["scenarios"]}

dispatches = []
for funded in scenarios:
    sid = funded["scenario_id"]
    scenario = all_scenarios.get(sid, {"id": sid, "title": sid, "description": ""})

    # Collect research signals
    signals = []
    for pattern in [f"$WORK_DIR/obsessives/{sid}_domain.json",
                    f"$WORK_DIR/obsessives/{sid}_search.json"]:
        for path in glob.glob(pattern):
            try:
                data = json.load(open(path))
                parsed = data.get("parsed") or data
                signals.append(json.dumps(parsed, indent=2))
            except Exception:
                pass

    research_block = "\n\n---\n\n".join(signals) if signals else "No research signals available."

    user_prompt = f"""Scenario to analyze:
ID: {sid}
Title: {scenario.get('title', sid)}
Description: {scenario.get('description', '')}
Funding: {funded['funding_percent']:.1f}%

Research signals gathered by obsessives:
{research_block}

Follow the analyst archetype protocol. Translate these signals into structured findings."""

    dispatches.append({
        "id": f"analyst-{sid}",
        "provider": "anthropic",
        "model": "claude-opus-4-6",
        "system_prompt_file": "$SKILL_DIR/archetypes/analysts/analyst.md",
        "user_prompt": user_prompt,
        "output_file": f"$WORK_DIR/analysts/{sid}_analysis.json"
    })

with open("$WORK_DIR/analyst_dispatches.json", "w") as f:
    json.dump({"dispatches": dispatches}, f, indent=2)
print(f"Prepared {len(dispatches)} analyst dispatches")
PYEOF

mkdir -p "$WORK_DIR/analysts"
python3 "$SCRIPTS/bazaar_dispatch.py" \
  "$WORK_DIR/analyst_dispatches.json" \
  "$WORK_DIR/analysts/" \
  2>&1
```

Tell the user: "Phase 5 complete. Analysis translated for {N} scenarios. Generating report..."

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
python3 - <<'PYEOF'
import json, glob

analyst_outputs = {}
for path in glob.glob("$WORK_DIR/analysts/*.json"):
    with open(path) as f:
        data = json.load(f)
    parsed = data.get("parsed")
    if parsed and "scenario_id" in parsed:
        analyst_outputs[parsed["scenario_id"]] = parsed

with open("$WORK_DIR/analyst_outputs.json", "w") as f:
    json.dump(analyst_outputs, f, indent=2)
print(f"Collected {len(analyst_outputs)} analyst outputs")
PYEOF
```

### Generate Report

Use the report structure and analyst outputs to write the final report:

```bash
python3 - <<'PYEOF'
import json, sys
sys.path.insert(0, "$SCRIPTS")
from report import populate_template
from pathlib import Path

structure = json.loads(open("$WORK_DIR/report_structure.json").read())
analyst_outputs = json.loads(open("$WORK_DIR/analyst_outputs.json").read())
template = open("$TEMPLATES/report-template.md").read()

# Populate template with structure (analyst_outputs integrated)
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

### Output

Write `.skill-result.md` in the current directory:

```markdown
# Bazaar Analysis Complete

**Question**: {QUESTION}
**Scenarios funded**: {N}
**Word count**: ~{WORD_COUNT}
**Providers used**: {PROVIDERS_LIST}

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

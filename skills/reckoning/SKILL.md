---
name: reckoning
description: >
  Analyze a project's MASTER_PLAN.md to assess coherence, evolution trajectory,
  and intent alignment. Modes: default (full analysis), compare (delta between
  reckonings), operationalize (convert findings to actionable work via /decide),
  steer (strategic brainstorming grounded in findings).
argument-hint: "[compare | operationalize | steer | --deep | path to MASTER_PLAN.md]"
context: fork
agent: general-purpose
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
  - AskUserQuestion
  - WebFetch
  - Skill
---

# /reckoning — Project Trajectory & Coherence Assessment

Analyze a project's MASTER_PLAN.md to understand the core of the project, the
evolution of the idea, its development trajectory, whether the idea has evolved
constructively or diverged from core intent, and produce an honest assessment
in light of those findings.

**Why this exists:** The planner creates plans. The implementer follows them.
The guardian protects them. Nobody evaluates whether the whole trajectory makes
sense. The reckoning is the missing function — the project's honest self-exam.
It tells you whether your project has a soul and whether that soul has been
honored.

**What this is NOT:** A summary. Summaries are cheap. This is an analysis that
draws connections the plan itself doesn't make explicit — between early decisions
and late consequences, between stated principles and actual behavior, between
non-goals and scope drift. The value is in what it *reveals*, not what it *restates*.

---

## Phase 1: Locate, Ingest, and Orient

### 1a. Find the Plan

Parse `$ARGUMENTS` to determine the MASTER_PLAN.md location:

| Input | Interpretation |
|-------|---------------|
| A file path | Use that path directly |
| A directory path | Look for `MASTER_PLAN.md` in that directory |
| Empty / omitted | Search: CWD → `{project_root}/MASTER_PLAN.md` → ask user |

If the file doesn't exist or isn't a living-document format (no `## Identity` section),
stop and tell the user. Suggest invoking the planner if they need to create one.

### 1b. Read and Parse

Read the entire MASTER_PLAN.md. Extract and hold in working memory:

**Stable DNA (rarely changes):**
- Identity — what the project says it is
- Original Intent — the sacred text; the vision as first stated
- Principles — the enduring design values
- Architecture — the intended structure

**Evolutionary Record (append-only):**
- Decision Log — every significant decision, dated and rationalized
- Active Initiatives — current work with goals, non-goals, requirements, waves
- Completed Initiatives — compressed summaries of finished work
- Parked Issues — deferred work with rationale

**Derived Counts:**
- Total initiatives (active + completed)
- Total decisions in log
- Total parked issues
- Project age (Created date to today)

### 1c. Detect Maturity Tier

The analysis depth scales to the project's history:

| Tier | Signal | Focus |
|------|--------|-------|
| **Foundation** | 0 completed initiatives, <5 decisions | Is the foundation sound? Are Identity, Principles, and first initiative coherent? |
| **Growth** | 1-4 completed initiatives, 5-20 decisions | Is the trajectory constructive? Do initiatives build on each other? |
| **Mature** | 5+ completed, 20+ decisions | Full historical analysis — intent fidelity, decision coherence, scope evolution, architectural drift |

State the detected tier and why. This frames the entire analysis — don't apply
mature-project scrutiny to a project that's three days old.

---

## Phase 2: Cross-Reference with Reality (Adaptive)

The plan tells the *intended* story. Reality may differ. Gather what's available
— this phase is adaptive, not mandatory. Use what exists; note what doesn't.

### 2a. Git History (if in a git repo)

```bash
# Development timeline
git log --oneline --format="%h %ad %s" --date=short --since="[plan Created date]" | head -80

# Branch/merge history
git log --oneline --merges --since="[plan Created date]" | head -40

# Contributor pattern (if multi-author)
git shortlog -sn --since="[plan Created date]" | head -10
```

Map commits to initiatives and waves where possible. Note gaps (long periods
without commits) and bursts (many commits in short windows).

### 2b. Codebase Structure (if code exists)

```bash
# Compare actual structure to Architecture section
ls -d */ 2>/dev/null | head -20

# Look for @decision annotations
grep -r "@decision DEC-" --include="*.sh" --include="*.md" --include="*.py" --include="*.ts" --include="*.js" -l 2>/dev/null | head -20
```

Compare actual directory layout against the Architecture section in the plan.
Note discrepancies — directories that exist but aren't documented, documented
directories that don't exist.

### 2c. GitHub Issues (if available)

```bash
# Check if GitHub remote exists
gh repo view --json name 2>/dev/null && \
  gh issue list --state all --limit 50 --json number,title,state,labels,createdAt 2>/dev/null
```

If issues exist, map them to plan wave items. Note:
- Plan items without corresponding issues (untracked work)
- Closed issues not reflected in the plan (undocumented completions)
- Open issues for completed initiatives (stale tracking)

### 2d. @decision Annotations in Code

If code exists, grep for `@decision` annotations and compare against the
Decision Log:

- Decisions in code but not in the plan → undocumented decisions
- Decisions in the plan but not in code → unimplemented or unannotated
- DEC-ID mismatches → broken traceability

**Note what you found and what you didn't.** Missing cross-reference data is
itself a finding ("this project has no @decision annotations in code despite
15 decisions in the plan — traceability is broken").

---

## Phase 3: Seven-Dimensional Analysis

Apply each dimension sequentially. For each: gather evidence, draw connections,
surface questions. Every claim must reference specific plan elements by section,
DEC-ID, REQ-ID, or initiative name.

### Dimension 1: Core Extraction

**Question:** What is this project fundamentally about?

Don't restate the Identity section. *Distill*. Read the Original Intent, the
Principles, and the first initiative together — they form a triangle that
reveals the project's soul. Then read the Decision Log chronologically — it
shows what the project *actually values* through the choices it made.

Write 2-3 paragraphs capturing:
- The irreducible essence — what makes this project THIS project
- The founding tension — what problem demanded this project's existence
- The implicit philosophy — what beliefs about the domain are embedded in the design

### Dimension 2: Chronological Reconstruction

**Question:** What happened, in what order, and at what pace?

Build a timeline from:
- Decision Log dates (primary — these are append-only and dated)
- Initiative start dates
- Completed Initiative periods
- Git history (if available from Phase 2)

Calculate and interpret:
- **Decision density** — decisions per time period. High early = strong vision or
  rapid learning. Declining = stabilization or stagnation. Erratic = reactive development.
- **Initiative velocity** — how quickly initiatives progress through waves.
  Stalled initiatives are a signal.
- **Rhythm** — steady cadence? Bursts of activity with long pauses? Accelerating?

Identify **inflection points** — moments where decision frequency, initiative scope,
or project direction changed significantly. For each: what caused the shift?
Was it reactive (something broke) or proactive (new insight)?

### Dimension 3: Intent Alignment

**Question:** Has the work honored the Original Intent?

This is the most important dimension. Apply these specific tests:

1. **Principle-Initiative Mapping:** For each active and completed initiative,
   which Principles does it serve? An initiative that serves no stated Principle
   is either scope drift or evidence that the Principles are incomplete.

2. **Decision-Principle Alignment:** Do architectural decisions reference
   Principles in their rationale? They should — decisions grounded in Principles
   are more coherent than ad-hoc choices.

3. **Non-Goal Migration:** Scan non-goals across all initiatives. Has anything
   declared as a Non-Goal in initiative A appeared as a Goal or requirement in
   initiative B? If so: was the original exclusion wrong (learning), or did scope
   creep smuggle it back in?

4. **Language Drift:** Compare the language used in the Original Intent with
   language in recent initiatives. Semantic shift in how the project describes
   itself is a leading indicator of identity drift.

5. **Original Intent Fulfillment:** Is the Original Intent being actively
   pursued, or has the project moved on to tangential concerns?

Produce a verdict: **Strong | Moderate | Weak | Diverged**
With evidence for the rating.

### Dimension 4: Decision Coherence

**Question:** Do the project's decisions form a consistent structure?

1. **Internal Consistency:** Do later decisions contradict earlier ones?
   Contradictions aren't always bad — they can indicate learning — but they
   should be acknowledged and rationalized.

2. **Decision Chains:** Do decisions reference each other? A decision that says
   "because of DEC-003, we chose..." shows historical awareness. Isolated
   decisions suggest fragmented thinking.

3. **Rationale Quality:** Are decision rationales substantive ("we chose X over Y
   because of constraint Z, which matters more than benefit W") or performative
   ("this seemed like the best approach")?

4. **Decision Gaps:** Are there obvious choices that were made but never recorded?
   Things that clearly changed in the project's direction without a corresponding
   DEC-ID.

5. **Implementation Fidelity:** (If Phase 2 found @decision annotations) Do code
   decisions match plan decisions? Are there code-level decisions not in the plan?

Produce a verdict: **Strong | Moderate | Fragmented**

### Dimension 5: Scope Evolution

**Question:** How have the project's boundaries moved?

Map how scope has changed across initiatives:

1. **Expansions:** Things added that weren't in the original vision. For each:
   was this necessary learning (the original scope was too narrow) or undisciplined
   growth (we kept adding because we could)?

2. **Contractions:** Things dropped that were originally in scope. For each:
   wise pruning (we learned it wasn't needed) or failure to execute (we couldn't
   get it working)?

3. **Parked Issues Analysis:** The Parked Issues section reveals what the project
   considered but deferred. Assess:
   - Are these genuinely deferred, or effectively abandoned?
   - Do parked items accumulate faster than they're resolved?
   - Is there a pattern to what gets parked? (Always the same type of work?)

4. **P2 (Future Consideration) Tracking:** Requirements marked P2 are promises
   to a future self. Are prior P2 items showing up in later initiatives, or are
   they quietly abandoned?

### Dimension 6: Project Health

**Question:** How healthy is this project as a living system?

Derive composite indicators from the evidence gathered:

| Indicator | What It Measures | How to Assess |
|-----------|-----------------|---------------|
| **Vitality** | Is the project alive and evolving? | Recent decisions, active initiatives, git activity |
| **Focus** | Is effort concentrated or scattered? | Number of simultaneous active initiatives, scope breadth |
| **Momentum** | Is the completion rate healthy? | Completed vs. active vs. parked ratio, wave completion speed |
| **Coherence** | Do all pieces tell a consistent story? | Principle-decision alignment, initiative interconnection |
| **Sustainability** | Can this pace/pattern continue? | Decision density trends, initiative size trends, parked issue accumulation |

Rate each: use the scale given in the output template. Provide specific evidence
for each rating — never rate without justification.

### Dimension 7: Trajectory

**Question:** Where is this project heading, and should it be heading there?

This is the synthesis layer. Using everything from Dimensions 1-6:

1. **Current Vector:** What direction is the project actually moving? Not what the
   plan says — what the pattern of recent work reveals.

2. **Projected Destination:** If current patterns continue unchanged for 3-6 months,
   what does this project become? Is that what the Original Intent envisioned?

3. **Intent-Trajectory Gap:** The distance between stated intent and actual heading.
   A small gap means execution aligns with vision. A large gap means either the
   vision needs updating or execution needs correcting.

4. **External Context (optional, if deep-research is warranted):** Has the problem
   domain shifted since the project started? Is the project solving a problem that
   no longer exists, or has the landscape changed in ways the plan hasn't absorbed?
   If you detect strong signals of domain shift, and deep-research API keys are
   available, invoke `/deep-research` on the domain question. This is the ONE
   place where external research adds value to a reckoning — don't force it.

---

## Phase 4: Synthesis — The Reckoning

This is where the skill earns its name. Integrate all seven dimensions into a
single honest assessment.

### The Verdict

Choose one (and only one) verdict:

| Verdict | Meaning |
|---------|---------|
| **On course** | Development faithfully serves the Original Intent. Decisions are coherent. Trajectory matches vision. |
| **Drifting constructively** | Development has expanded beyond original scope, but the expansions serve the core vision. The project is becoming more than planned, in a good way. |
| **Drifting destructively** | Development has wandered from core intent. Energy is going to tangential concerns. The project risks losing its identity. |
| **Pivoted** | The project has intentionally changed direction. The Original Intent is no longer the north star — a new direction has emerged. This isn't bad if it was conscious. |
| **Evolved beyond original intent** | The project outgrew its original vision. The Original Intent was a seed; what grew is larger and different but legitimate. |
| **Stalled** | The project has stopped meaningful evolution. Active initiatives exist on paper but progress has frozen. |
| **Lost** | The project lacks coherent direction. Decisions contradict each other. Initiatives don't connect. The soul is unclear. |

### What to Celebrate

Genuine accomplishments. Things the project has done well. Be specific — not
"good architecture" but "the decision to separate hooks from agent prompts
(DEC-PROMPT-002) created a clean enforcement/guidance boundary that has held
across 3 initiatives."

### What to Confront

**This is the hardest section and the most important one.**

Say what needs saying. The user invoked this skill because they want the truth,
not comfort. Deliver it with respect but without flinching:

- A beloved initiative might be scope drift
- Decision quality might have declined
- The project might have lost focus
- Non-goals might have crept back in
- The pace might be unsustainable

Ground every confrontation in evidence. Never say "the project seems unfocused"
— say "the project has 3 active initiatives with no shared requirements, and
the Governance Signal Audit's P1 (optimization proposals) tensions with the
Prompt Restoration initiative's Non-Goal of not adding enforcement."

### What to Do Next

3-5 concrete, specific recommendations. Not "improve focus" but:
- "Close or merge the Governance Audit into Prompt Restoration — they're two sides of the same coin"
- "The 4 parked issues from Wave 2 have been parked for 3 months — declare them abandoned or schedule them"
- "Add a Principle about X — the project clearly values it (3 decisions reference it) but it's not stated"

---

## Phase 5: Write and Deliver

### Output Location

The reckoning belongs to the project and must be visible to the user — not
buried in a dotfile directory. Write to:

```
{project_root}/reckonings/{YYYY-MM-DD}-reckoning.md
```

Create the directory if it doesn't exist. If a reckoning already exists for today,
append a counter: `{YYYY-MM-DD}-reckoning-2.md`.

Optionally, also copy to `~/.claude/reckonings/` for cross-project reference —
but the project-root copy is the primary artifact the user sees.

### Output Template

```markdown
# Project Reckoning: [Project Name]

**Date:** [today]
**Source:** [absolute path to MASTER_PLAN.md]
**Project age:** [from Created date to today, in days/weeks/months]
**Maturity tier:** [Foundation | Growth | Mature]
**Initiatives:** [N active, M completed, K parked issues]
**Decisions:** [total in Decision Log]

---

## I. The Core

[2-3 paragraphs. The irreducible essence. The founding tension. The implicit
philosophy. Not a restatement — a distillation.]

## II. The Origin

[The Original Intent examined. What problem was being solved? What assumptions
were embedded? What constraints shaped the original vision? Quote the Original
Intent verbatim, then analyze it.]

## III. The Journey

### Timeline

| Period | Initiative | Status | Key Decisions | Outcome |
|--------|-----------|--------|---------------|---------|
[One row per initiative, chronologically]

### Decision Density
[Decisions per time period. Interpretation of the pattern.]

### Inflection Points
[Key moments where the project's trajectory changed. Cause and assessment.]

### Plan vs. Reality
[If cross-reference data was available: how well does the plan match
actual development? If not available: state that and note the limitation.]

## IV. Evolution Assessment

### Intent Alignment: [Strong | Moderate | Weak | Diverged]

[Evidence-based assessment with specific references to plan elements.]

### Principle Adherence

| Principle | Honored? | Evidence |
|-----------|----------|----------|
[One row per stated Principle]

### Constructive Expansions
[Where the project grew beyond original vision healthily. Each with assessment.]

### Scope Drift
[Where development wandered. Each categorized: beneficial, neutral, or harmful.]

### Non-Goal Violations
[Things excluded that crept back in. Assessment of each.]

### Abandoned Threads
[Ideas started but dropped. For each: wise pruning or lost potential?]

## V. Decision Quality

### Coherence: [Strong | Moderate | Fragmented]

[Assessment with specific decision references.]

### Notable Decision Chains
[Where decisions build on each other well — or where they contradict.]

### Decision Gaps
[Significant decisions missing from the record.]

### Traceability
[How well DEC-IDs connect plan to code. @decision annotation coverage.]

## VI. Project Health

| Indicator | Rating | Evidence |
|-----------|--------|----------|
| Vitality | [Thriving / Active / Steady / Stagnating / Declining] | [specific evidence] |
| Focus | [Sharp / Moderate / Diffuse / Scattered] | [specific evidence] |
| Momentum | [Accelerating / Steady / Decelerating / Stalled] | [specific evidence] |
| Coherence | [Strong / Moderate / Fragmented / Contradictory] | [specific evidence] |
| Sustainability | [Sustainable / Straining / Unsustainable] | [specific evidence] |

## VII. Trajectory

### Current Vector
[Where the project is actually heading based on recent work patterns.]

### Projected Destination
[If patterns continue, what does this project become?]

### Intent-Trajectory Gap
[Distance between stated intent and actual heading. Assessment.]

## VIII. The Reckoning

### Verdict: [on course | drifting constructively | drifting destructively |
              pivoted | evolved beyond original intent | stalled | lost]

[The honest, integrated assessment. Not a summary of prior sections — a
synthesis that says something they individually don't. 2-4 paragraphs.]

### What to Celebrate
[Genuine accomplishments with specific evidence.]

### What to Confront
[Uncomfortable truths, grounded in evidence, delivered with respect.]

### What to Do Next
[3-5 concrete, specific recommendations.]
```

### Present to User

After writing the file, present the key findings inline — don't just say
"reckoning written to X." Show the user the Verdict, What to Celebrate,
What to Confront, and What to Do Next directly. The full analysis is in the
file; the inline presentation is the executive summary that earns the user's
attention.

---

## Enforcement Rules

1. **Every claim references evidence.** "Intent alignment is weak" must be
   followed by specific plan references. No vibes-based assessments.

2. **The Verdict is singular.** Choose one verdict. Don't hedge with "somewhere
   between drifting constructively and on course." Commit to the assessment.

3. **What to Confront is mandatory.** Every project has uncomfortable truths.
   If you can't find any, you're not looking hard enough. Even a perfectly
   executed project has risks, blind spots, or deferred debts worth naming.

4. **Don't moralize.** The reckoning describes reality and assesses it — it
   doesn't lecture. "The project has 3 active initiatives with no shared
   requirements" is an observation. "The project should be more focused" is
   judgment. Pair them: observation first, then assessment of what it means.

5. **Scale to maturity.** A Foundation-tier project gets encouragement about
   its setup and pointed questions about its assumptions. A Mature-tier project
   gets rigorous historical analysis. Don't apply decade-long scrutiny to a
   week-old plan.

6. **Respect the Original Intent.** The Original Intent is sacred text — the
   founding vision. Assess against it honestly but remember: the user wrote it
   for a reason. If the project has moved away from it, that might be growth,
   not failure. Distinguish intentional evolution from unconscious drift.

7. **No modifications.** The reckoning reads and assesses. It never modifies
   the MASTER_PLAN.md, code, issues, or any other project artifact. It produces
   its report and stops.

8. **Cross-reference honestly.** If Phase 2 data is unavailable (no git, no
   GitHub, no code), say so in the Plan vs. Reality section. An analysis limited
   to the plan document is still valuable — but acknowledge the limitation.

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| No MASTER_PLAN.md found | Tell user; suggest invoking the planner |
| Old-format plan (no `## Identity`) | Note the format; analyze what exists with adapted dimensions |
| Brand new plan (created today) | Foundation tier; focus on setup quality and assumption testing |
| Plan with no completed initiatives | Growth tier at most; focus on whether active work is coherent |
| Plan with 10+ completed initiatives | Mature tier; full historical analysis with evolution arc |
| Plan with no Decision Log entries | Major finding — decisions are being made without recording |
| Plan with no Original Intent | Major finding — the project lacks a north star; recommend adding one |
| Very large plan (1000+ lines) | Read in sections; focus analysis on Decision Log and initiative patterns |
| `--deep` flag in arguments | Invoke `/deep-research` on the project's problem domain to assess external context shifts |
| Multiple MASTER_PLAN.md files | Ask user which one to analyze |

---

## Modes

The reckoning has four modes. The default (no subcommand) runs the full analysis.
Subcommands extend the analysis into action.

### `/reckoning` (default) — Full Analysis

The full seven-dimension analysis described in Phases 1-5 above. Produces a
reckoning report at `{project_root}/reckonings/{date}-reckoning.md`.

### `/reckoning compare` — Delta Analysis

When a previous reckoning exists, produce a structured comparison showing how
the project has changed between assessments.

**Trigger:** Automatically runs when a new reckoning is produced and a prior
reckoning exists in the `reckonings/` directory. Can also be invoked standalone.

**Process:**
1. Find the most recent prior reckoning in `{project_root}/reckonings/`
2. Read both the current and prior reckoning
3. Produce a delta report covering:

| Dimension | What Changed |
|-----------|-------------|
| Verdict | Did it change? In which direction? |
| Health indicators | Which ratings moved up/down? |
| Intent alignment | Stronger or weaker? |
| Decision coherence | Improved or degraded? |
| New findings | What appeared that wasn't in the prior reckoning? |
| Resolved findings | What was confronted that's now addressed? |
| Persistent findings | What was flagged before and remains unaddressed? |

4. Append a `## Reckoning Delta` section to the current reckoning report
5. Present the delta inline: "Since the last reckoning [date]: [key changes]"

**The delta is the accountability mechanism.** It shows whether the project acted
on prior reckoning recommendations or ignored them.

### `/reckoning operationalize` — Convert Findings to Action

Transform reckoning findings into two categories of actionable work:

**Big (Initiative-level):** Findings that require planning, architectural decisions,
and steering the project's direction. These become candidate initiatives or
amendments to existing initiatives. Each needs:
- A clear problem statement grounded in the reckoning evidence
- Options with trade-offs (suitable for `/decide`)
- Impact assessment: what happens if addressed vs. ignored
- Suggested DEC-ID prefix

**Small (Fixes/corrections):** Findings that need direct action — restoring deleted
content, fixing collisions, triaging issues, correcting dates. These become
GitHub issues or immediate tasks. Each needs:
- The specific fix
- Where to find the data (git commits, issue numbers)
- Whether it can be done by the orchestrator or needs an implementer

**Process:**
1. Read the most recent reckoning from `{project_root}/reckonings/`
2. Classify each "What to Confront" finding and "What to Do Next" recommendation
   into Big or Small
3. For Big items: invoke `/decide` with structured decision steps, presenting
   options with thorough context and trade-offs
4. For Small items: present as a numbered checklist with clear actions
5. Number everything with progress tracking: "Decision 3 of 7" / "Fix 2 of 5"
6. Support deferral: any item can be filed as a GitHub issue for later

**Decision presentation format (for Big items):**
Each decision is presented sequentially with:
```
--- Decision [N] of [total] ---
## [Title]

### Context (from the reckoning)
[What was found, why it matters, evidence]

### Options
A. [Option] — [trade-offs]
B. [Option] — [trade-offs]
C. [Option] — [trade-offs]

### Recommendation: [which option and why]
### Impact if ignored: [what gets worse]

Your choice (A/B/C/defer/file):
```

The user can:
- Choose an option → recorded as a decision
- `defer` → skip for now, come back later
- `file` → create a GitHub issue and move on

After all decisions are made, produce a summary of choices and dispatch
to the planner if any Big items need initiative creation.

### `/reckoning steer` — Strategic Discussion

A brainstorming mode grounded in reckoning findings, designed to help the user
think about where the project *should* go — not just where it has been.

**Purpose:** The default reckoning tells you the truth about your project. The
operationalize mode converts findings to action. The steer mode asks the bigger
question: given everything we know, what would benefit this project the most?

**Process:**
1. Read the most recent reckoning
2. Read the MASTER_PLAN.md (active initiatives, parked issues, principles)
3. Synthesize: what are the project's biggest opportunities and risks?
4. If `--deep` flag is present or the project's domain has shifted, invoke
   `/deep-research` on relevant domain questions
5. Present a structured discussion:

**Discussion structure:**
```
## Where You Are
[1-paragraph synthesis from the reckoning]

## Three Possible Futures

### Future A: [name] — [1-line description]
[2-3 paragraphs: what this future looks like, what it requires,
what it costs, who it serves]

### Future B: [name]
[...]

### Future C: [name]
[...]

## What Would Help Most Right Now
[Ranked recommendations with rationale. Not "what to fix" (that's
operationalize) but "what to invest in" — strategic bets.]

## Questions for You
[3-5 questions the reckoning can't answer — things only the user
knows about their priorities, constraints, and vision]
```

6. Engage in conversation with the user about their answers
7. When direction crystallizes, offer to:
   - File issues for future planning
   - Invoke the planner to create a new initiative
   - Update the project's Principles if the vision has evolved

**The steer mode is conversational, not reportorial.** It asks questions,
responds to the user's answers, and iterates toward clarity. It does NOT
produce a document and walk away — it stays engaged until the user has
direction.

---

## Write Context Summary (MANDATORY — do this LAST)

Write a compact result summary so the parent session receives key findings:

```bash
cat > .claude/.skill-result.md << 'SKILLEOF'
## Reckoning Result: [Project Name]

**Verdict:** [verdict]
**Maturity:** [tier]
**Output:** [path to reckoning file]

### Key Findings
1. [Most important finding]
2. [Second key finding]
3. [Third key finding]

### Recommendations
1. [Top recommendation]
2. [Second recommendation]
SKILLEOF
```

Keep under 2000 characters. This is consumed by a hook — the parent session
will see it automatically.

---

## After Completion

```
---
Project Reckoning complete.
- Project: [name]
- Verdict: [verdict]
- Report: {project_root}/.claude/reckonings/{date}-reckoning.md

Want me to act on any of the recommendations?
```

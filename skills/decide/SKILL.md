---
name: decide
description: Generate an interactive decision configurator from research or plan analysis. Presents options as explorable cards with trade-offs, costs, effort estimates, and filtering. Integrates with Planner to collect DEC-ID decisions.
argument-hint: "[topic, research path, or 'plan' to use current plan context]"
context: fork
agent: general-purpose
allowed-tools: Bash, Read, Write, Glob, Grep, AskUserQuestion
---

# Decide: Structured Decision Configurator

Generate interactive decision configurators that transform complex trade-off analysis into explorable interfaces. Presents options as cards with visual hierarchy, automatic filtering, cascading dependencies, and live cost/effort tracking.

## When to Use /decide

Use this skill when decisions have:
- **3+ options** with meaningful trade-offs
- **Dollar amounts** or effort estimates to compare
- **Cascading dependencies** (choice A eliminates options in choice B)
- **Multiple dimensions** to evaluate (cost, effort, quality, risk)

**Don't use for:**
- Binary yes/no decisions → use AskUserQuestion
- Simple 2-option choices → use AskUserQuestion
- Decisions already made → just document them

## Decision Sources

The skill can extract decision points from three sources:

1. **Research directories** — `/decide .claude/research/DeepResearch_Auth_2026-02-11`
   - Parses provider reports (openai.md, perplexity.md, gemini.md)
   - Extracts competing approaches, trade-offs, and effort estimates
   - Links to cited sources

2. **MASTER_PLAN.md context** — `/decide plan`
   - Extracts decision points from "Architectural Decisions" section
   - Pulls requirements from "Requirements" section
   - Associates DEC-IDs with plan phases

3. **Conversation context** — `/decide monitor purchase decision`
   - Analyzes recent conversation history
   - Identifies options, constraints, and trade-offs discussed
   - Generates from requirements stated in conversation

## Implementation Phases

### Phase 1: Identify Decision Source

**If argument is a filesystem path:**
- Check if it's a research directory (.claude/research/DeepResearch_*)
- Look for report.md, openai.md, perplexity.md, gemini.md
- Extract decision points from research findings

**If argument is "plan":**
- Read {project_root}/MASTER_PLAN.md
- Extract from "Architectural Decisions" section
- Map DEC-IDs to options
- Pull constraints from Requirements section

**If argument is topic/question:**
- Analyze recent conversation (last 5-10 messages)
- Identify options mentioned, trade-offs discussed
- Extract constraints and requirements from conversation

**If no source is clear:**
- Ask user: "I found these potential decision sources: [list]. Which should I use?"

### Phase 2: Decompose Decisions

For each decision source, identify:

1. **Steps** — Sequential decision points (e.g., "Choose auth method" → "Choose database" → "Choose deployment")
   - Each step has: title, subtitle, DEC-ID (if from plan), info box (optional context)
   - Steps should flow logically — dependencies become filters

2. **Options** — Alternatives within each step
   - Each option has: title, badge, price OR effort, specs (pros/cons), tags, links
   - Mark recommended option (if clear from research/plan)
   - Mark eliminated options (if constraints rule them out)

3. **Filtering logic** — Cascading constraints
   - "If user picks 5K resolution, hide 4K monitors"
   - "If user picks quantity=3, show triple-arm option"
   - Document as `filterBy` (data-based) or `visibleWhen` (state-based)

4. **Cost/effort tracking** — Live impact bar
   - Price-based: monitors ($799 × quantity) + arms ($398) + cables ($30 × quantity)
   - Effort-based: auth (2 days) + database (3 days) + deployment (1 day)
   - Mix allowed: some steps contribute price, others effort

5. **Summary & Export** — Final output
   - Grid items: "Your monitor: ASUS ProArt PA27JCV", "Total cost: ~$2,795"
   - Action items: setup instructions, next steps
   - Export: JSON blob with DEC-IDs and selected options

### Phase 3: Generate Config JSON

Write `decision-config.json` following the schema. The config is the single source of truth for the configurator. The build script injects it verbatim into the HTML template.

**Reference the fixtures as examples:**

1. **Purchase decision pattern** — See `fixtures/monitor-setup.json`:
   - `meta.type: "purchase"`
   - Price-based options with dollar amounts
   - Impact bar with price × quantity math
   - Buy links in summary
   - Info boxes with domain-specific guidance

2. **Technical decision pattern** — See `fixtures/tech-stack.json`:
   - `meta.type: "technical"`
   - Effort-based options (days/weeks)
   - Impact bar summing effort estimates
   - Documentation links instead of buy links
   - Export enabled with DEC-IDs

**Key config patterns:**

- **filterBy**: Filter options in step B based on data field from selected option in step A
  ```json
  {
    "id": "monitor",
    "filterBy": { "dataField": "tier", "matchStep": "priority" }
  }
  ```
  Meaning: "Show only monitors where option.data.tier matches the selected priority option's ID"

- **visibleWhen**: Show/hide option based on exact state match
  ```json
  {
    "id": "triple-arm",
    "visibleWhen": { "step": "quantity", "equals": "qty-3" }
  }
  ```
  Meaning: "Show this arm option only when step 'quantity' has option 'qty-3' selected"

- **impactBar.items**: Dynamic cost/effort calculation
  ```json
  {
    "label": "Monitors",
    "fromStep": "monitor",
    "multiplyByStep": "quantity"
  }
  ```
  Meaning: "Get price from selected monitor, multiply by quantity value"

**When generating config:**
1. Start from one of the fixture examples as a template
2. Replace domain-specific data (monitors → auth methods, prices → effort)
3. Preserve the structure: meta, steps, impactBar, summary, research (if applicable)
4. Validate against schema mentally before writing

Write the config to `decision-config.json` in the working directory (or user-specified path).

### Phase 4: Build and Serve

Run the build script with `--serve` to start a local server. This is **required** — the Confirm button POSTs decisions back to the server, which writes them to `decisions.json` on disk.

```bash
python3 ~/.claude/skills/decide/scripts/build.py decision-config.json --serve
```

**CRITICAL: Run this with `run_in_background: true`** so you can continue operating while the user interacts with the configurator. Set `timeout: 600000` (10 minutes).

The script will:
1. Validate config
2. Build HTML with config injected
3. Start HTTP server on a random port (localhost only)
4. Open `http://localhost:{port}/` in browser
5. Print `Decisions will be saved to: {cwd}/decisions.json`
6. Wait for the user to click Confirm
7. When Confirm is clicked, write `decisions.json` and print `>>> DECISIONS CONFIRMED`

**Flags:**
- `--serve` — start local server (primary mode, enables auto-submit)
- `--open` — open as file:// (fallback, clipboard-only, no auto-submit)
- `--decisions-out PATH` — custom path for decisions.json output

### Phase 5: Report Back & Wait for Decisions

Tell the user:
```
Generated decision configurator — opening in browser.
Server running at http://localhost:{port}/

The configurator presents {N} decision steps with {M} total options.
Make your selections, then click "Confirm Decisions" — your choices will be submitted automatically.
```

Then **wait for the user** to say they're done (or check the background task for the `>>> DECISIONS CONFIRMED` message).

### Phase 6: Read Confirmed Decisions

When the user confirms, the server writes `decisions.json` to disk. **Read it directly.**

**Method 1: Read from file (primary — works with --serve)**
```bash
cat decisions.json
```
Or use the Read tool on the `decisions.json` path that the server printed at startup. This is the default path — `{cwd}/decisions.json` unless `--decisions-out` was specified.

**Check the background task output** for the `>>> DECISIONS CONFIRMED` line to know when the file is ready. If the user says "done" but the file doesn't exist yet, tell them: "Please click the green 'Confirm Decisions' button in the configurator first."

**Method 2: Chrome extension (if available)**
If browser automation tools are available (`mcp__claude-in-chrome__*`):
```javascript
// Via javascript_tool on the configurator tab:
JSON.stringify(window.__DECISIONS__)
```

**Method 3: User pastes from clipboard**
Fallback for `--open` (file://) mode where the server isn't running. The Confirm button copies JSON to clipboard.

### Phase 7: Integrate Decisions

Once you have the decisions JSON, **parse it and take concrete action**. The JSON looks like:
```json
{
  "decisions": {
    "auth-method": {
      "decId": "DEC-AUTH-001",
      "selected": "jwt-pkce",
      "title": "JWT + PKCE Flow",
      "rationale": "Stateless, scales horizontally"
    }
  },
  "timestamp": "2026-02-11T14:30:00Z"
}
```

**Action depends on the invoking context:**

#### 7a. Invoked from Planner (most common)
Return the parsed decisions to the calling Planner agent. The Planner will:
1. Write each decision into `### Planned Decisions` in MASTER_PLAN.md:
   ```
   - DEC-AUTH-001: JWT + PKCE Flow — Stateless, scales horizontally — Addresses: REQ-P0-001
   ```
2. Populate phase `**Decision IDs:**` fields with the confirmed DEC-IDs
3. Continue to Phase 3 (Issue Decomposition) with user-validated decisions

To enable this, **output the decisions as a structured block** the Planner can parse:
```
CONFIRMED DECISIONS:
- DEC-AUTH-001 (auth-method): JWT + PKCE Flow — "Stateless, scales horizontally"
- DEC-DATA-001 (database): PostgreSQL + Prisma — "Type-safe queries with Prisma Client"
- DEC-DEPLOY-001 (deployment): Docker + Fly.io — "Full control over runtime environment"
SOURCE: configurator confirmed at {timestamp}
```

#### 7b. Invoked standalone
Present the decisions and take the next step:

1. **Show what was chosen** — summarize each decision with DEC-ID, selection, and rationale
2. **If MASTER_PLAN.md exists** — offer to update it:
   - Read the existing plan
   - Find the `### Planned Decisions` sections
   - Replace or append the confirmed decisions using the DEC-ID as the key
   - Write the updated plan
3. **If no plan exists** — offer to:
   - Create a new MASTER_PLAN.md with these decisions as the Architectural Decisions section
   - Start implementation directly based on the choices
4. **If this was a purchase decision** — compile the buy list with links and totals from the selected options

#### 7c. Invoked for purchase decisions (no plan context)
For purchase decisions (meta.type = "purchase"), skip plan integration. Instead:
1. Present the final shopping list with prices and buy links
2. Offer: "Want me to open the buy links in your browser?"
3. Save the decisions to `{cwd}/decisions.json` for reference

**Always end with forward motion** — never leave decisions hanging without a next action.

**Refinement workflow:**
If the user wants to adjust after confirming:
1. User requests change: "Add a fourth option" or "change the auth recommendation"
2. Read and update decision-config.json
3. Re-run `python3 ~/.claude/skills/decide/scripts/build.py decision-config.json --output configurator.html --open`
4. User re-confirms in the refreshed configurator
5. Re-read decisions (Phase 6) and re-integrate (Phase 7)

## Config JSON Schema Reference

The schema is defined in `schema/decision-config.schema.json`. Key fields:

### meta (required)
- `title` (string, required) — Configurator title
- `subtitle` (string, optional) — Subtitle/description
- `type` (enum, required) — "purchase" | "technical" | "implementation" | "configuration"
  - Controls theme color (indigo/purple/teal/blue)
- `researchDir` (string, optional) — Path to research directory
- `planContext` (object, optional) — { masterPlan, phase, requirements[] }

### steps[] (required, min 1)
- `id` (string, required) — Unique step identifier
- `title` (string, required) — Step title
- `subtitle` (string, optional) — Step subtitle
- `decId` (string, optional) — DEC-ID from MASTER_PLAN.md
- `filterBy` (object, optional) — { dataField, matchStep }
- `infoBox` (object, optional) — { html, variant: "default" | "critical" | "warning" }
- `options[]` (array, required, min 1) — Options for this step

### options[] (within steps)
- `id` (string, required) — Unique option identifier
- `title` (string, required) — Option title
- `badge` (object, optional) — { text, color }
- `recommended` (bool, default false) — Show "RECOMMENDED" ribbon
- `eliminated` (bool, default false) — Gray out and disable
- `price` (object, optional) — { amount: number, label: string }
- `effort` (object, optional) — { amount: string, label: string }
  - amount can be "2 days", "1 week", "3-5 days"
- `specs[]` (array, optional) — Bullet points
  - Each spec: { text, type: "highlight" | "warning" | "neutral" }
- `tags[]` (array, optional) — Tags with ok/not-ok states
  - Each tag: { text, ok: bool }
- `links[]` (array, optional) — Resource links
  - Each link: { label, url, detail }
- `data` (object, optional) — Arbitrary data for filtering
- `visibleWhen` (object, optional) — { step, equals }

### impactBar (optional)
- `items[]` (array, required if impactBar present)
  - Each item: { label, fromStep?, effortFromStep?, multiplyByStep?, perUnit?, approximate: bool }
- `totalLabel` (string, optional, default "Total")
- `prefix` (string, optional, default "$")

### summary (optional)
- `title` (string, required if summary present)
- `gridItems[]` (array, optional) — Summary grid
  - Each item: { label, template, highlight: bool }
  - Templates use {stepId.field} syntax: {monitor.title}, {total}
- `actions[]` (array, optional) — Action items
  - Each action: { text, critical: bool, condition?: string }
- `footer` (object, optional) — { html }
- `export` (object, optional) — { enabled: bool, filename, includeDecIds: bool }

### research (optional)
- `summary` (string, optional) — Executive summary from research
- `sources[]` (array, optional) — Research sources
  - Each source: { provider, title, content, citations[] }

## Fixture Examples (Inline Reference)

### 1. Purchase Decision: Monitor Setup

```json
{
  "meta": {
    "title": "Monitor Setup Configurator",
    "subtitle": "Triple-checked buying guide for Mac workstation",
    "type": "purchase"
  },
  "steps": [
    {
      "id": "priority",
      "title": "What matters most?",
      "subtitle": "This determines your resolution tier",
      "options": [
        {
          "id": "5k",
          "title": "Maximum Text Crispness",
          "badge": { "text": "218 PPI", "color": "green" },
          "recommended": true,
          "price": { "amount": 0, "label": "5K Resolution" },
          "specs": [
            { "text": "218 PPI — native 2x Retina on macOS", "type": "highlight" },
            { "text": "Zero interpolation, zero scaling artifacts", "type": "highlight" }
          ],
          "data": { "tier": "5k" }
        },
        {
          "id": "4k",
          "title": "Good Text, Great Value",
          "badge": { "text": "163 PPI", "color": "amber" },
          "price": { "amount": 0, "label": "4K Resolution" },
          "specs": [
            { "text": "163 PPI — requires fractional macOS scaling", "type": "neutral" },
            { "text": "Subtle font softness possible", "type": "warning" }
          ],
          "data": { "tier": "4k" }
        }
      ],
      "infoBox": {
        "html": "<strong>For astigmatism:</strong> 5K is dramatically crisper.",
        "variant": "critical"
      }
    },
    {
      "id": "monitor",
      "title": "Choose your monitor",
      "filterBy": { "dataField": "tier", "matchStep": "priority" },
      "options": [
        {
          "id": "asus-5k",
          "title": "ASUS ProArt PA27JCV",
          "badge": { "text": "5K • BEST VALUE", "color": "green" },
          "recommended": true,
          "price": { "amount": 799, "label": "per monitor" },
          "specs": [
            { "text": "5120 x 2880 — 218 PPI", "type": "highlight" },
            { "text": "99% DCI-P3, Delta E < 2", "type": "highlight" }
          ],
          "links": [
            { "label": "Amazon", "url": "https://amazon.com/...", "detail": "Ships to 20002" }
          ],
          "data": { "tier": "5k" }
        }
      ]
    }
  ],
  "impactBar": {
    "items": [
      { "label": "Monitors", "fromStep": "monitor", "multiplyByStep": "quantity" },
      { "label": "Arms", "fromStep": "arms" },
      { "label": "Cables", "perUnit": 30, "multiplyByStep": "quantity", "approximate": true }
    ],
    "totalLabel": "Total Setup Cost",
    "prefix": "$"
  },
  "summary": {
    "title": "Your Setup — Ready to Buy",
    "gridItems": [
      { "label": "Monitors", "template": "{quantity.value}x {monitor.title}", "highlight": false },
      { "label": "Total Cost", "template": "${total}", "highlight": true }
    ],
    "export": { "enabled": false }
  }
}
```

### 2. Technical Decision: Tech Stack

```json
{
  "meta": {
    "title": "Authentication & Database Decisions",
    "subtitle": "Choose your tech stack for the auth microservice",
    "type": "technical",
    "planContext": {
      "masterPlan": "MASTER_PLAN.md",
      "phase": "Phase 1: Core Authentication",
      "requirements": ["REQ-P0-001", "REQ-P0-002"]
    }
  },
  "steps": [
    {
      "id": "auth-method",
      "title": "Choose authentication method",
      "decId": "DEC-AUTH-001",
      "options": [
        {
          "id": "jwt-pkce",
          "title": "JWT + PKCE Flow",
          "badge": { "text": "Modern", "color": "purple" },
          "recommended": true,
          "effort": { "amount": "2 days", "label": "implementation" },
          "specs": [
            { "text": "Stateless, scales horizontally", "type": "highlight" },
            { "text": "No server-side session storage needed", "type": "highlight" },
            { "text": "Requires careful token rotation strategy", "type": "warning" }
          ],
          "links": [
            { "label": "RFC 7636 (PKCE)", "url": "https://...", "detail": "OAuth 2.0 extension" }
          ]
        },
        {
          "id": "session-based",
          "title": "Session-Based Auth",
          "badge": { "text": "Traditional", "color": "blue" },
          "effort": { "amount": "1 day", "label": "implementation" },
          "specs": [
            { "text": "Simple to implement", "type": "highlight" },
            { "text": "Requires sticky sessions or shared state", "type": "warning" }
          ]
        }
      ]
    },
    {
      "id": "database",
      "title": "Choose database",
      "decId": "DEC-DATA-001",
      "options": [
        {
          "id": "postgres-prisma",
          "title": "PostgreSQL + Prisma",
          "recommended": true,
          "effort": { "amount": "3 days", "label": "schema + migrations" },
          "specs": [
            { "text": "Type-safe queries with Prisma Client", "type": "highlight" },
            { "text": "Built-in migration system", "type": "highlight" }
          ]
        }
      ]
    }
  ],
  "impactBar": {
    "items": [
      { "label": "Auth Implementation", "effortFromStep": "auth-method" },
      { "label": "Database Setup", "effortFromStep": "database" }
    ],
    "totalLabel": "Total Effort",
    "prefix": ""
  },
  "summary": {
    "title": "Your Tech Stack",
    "gridItems": [
      { "label": "Auth Method", "template": "{auth-method.title}", "highlight": false },
      { "label": "Database", "template": "{database.title}", "highlight": false },
      { "label": "Total Effort", "template": "{total}", "highlight": true }
    ],
    "export": {
      "enabled": true,
      "filename": "tech-decisions.json",
      "includeDecIds": true
    }
  }
}
```

## Integration with Planner

The `/decide` skill is invoked by the Planner during Phase 2 (Architecture Design). The full round-trip:

### Step 1: Planner invokes `/decide`
```
Planner Phase 2, Step 2 (Research Gate):
  → Identifies 3+ decisions with trade-offs
  → Invokes: /decide plan
  → Skill generates configurator, opens in browser
  → Skill tells user to click "Confirm Decisions" when done
  → Skill WAITS for user to return
```

### Step 2: User interacts in browser
User explores options, sees trade-offs, makes selections, clicks **"Confirm Decisions"**.
- Decisions stored in `window.__DECISIONS__` (for Chrome extension)
- Decisions auto-copied to clipboard (for paste fallback)
- Green banner tells user to return to Claude Code

### Step 3: Skill reads decisions back (Phase 6)
```
User says "done" or "confirmed"
  → Skill reads window.__DECISIONS__ via Chrome extension
  → OR asks user to paste from clipboard
  → Parses the decisions JSON
```

### Step 4: Skill outputs structured block (Phase 7a)
```
CONFIRMED DECISIONS:
- DEC-AUTH-001 (auth-method): JWT + PKCE Flow — "Stateless, scales horizontally"
- DEC-DATA-001 (database): PostgreSQL + Prisma — "Type-safe queries with Prisma Client"
- DEC-DEPLOY-001 (deployment): Docker + Fly.io — "Full control over runtime environment"
SOURCE: configurator confirmed at 2026-02-11T14:30:00Z
```

### Step 5: Planner writes decisions into MASTER_PLAN.md
The Planner receives the structured block and writes each decision into the plan:

```markdown
### Planned Decisions
- DEC-AUTH-001: JWT + PKCE Flow — Stateless, scales horizontally — Addresses: REQ-P0-001, REQ-P0-003
- DEC-DATA-001: PostgreSQL + Prisma — Type-safe queries with Prisma Client — Addresses: REQ-P0-002
- DEC-DEPLOY-001: Docker + Fly.io — Full control over runtime environment — Addresses: REQ-P0-004
```

The `Addresses:` field comes from the config's `meta.planContext.requirements` array, mapped by the Planner based on which requirements each decision satisfies.

### Decisions JSON format
```json
{
  "decisions": {
    "auth-method": {
      "decId": "DEC-AUTH-001",
      "selected": "jwt-pkce",
      "title": "JWT + PKCE Flow",
      "rationale": "Stateless, scales horizontally"
    },
    "database": {
      "decId": "DEC-DATA-001",
      "selected": "postgres-prisma",
      "title": "PostgreSQL + Prisma",
      "rationale": "Type-safe queries with Prisma Client"
    }
  },
  "timestamp": "2026-02-11T14:23:45Z"
}
```

### What happens after
The Planner proceeds to Phase 2 Step 3 (Finalize decisions) with the user's confirmed selections, then Phase 3 (Issue Decomposition) and Phase 4 (MASTER_PLAN.md generation). The DEC-IDs from `/decide` carry through to `@decision` annotations in code, creating full traceability: **User selection → DEC-ID in plan → @decision in code**.

## Error Handling

**Config validation fails:**
- Show validation error with specific field missing
- Point to schema file and fixture examples
- Offer to fix automatically if error is clear

**Build script not found:**
- Check ~/.claude/skills/decide/scripts/build.py exists
- If missing, tell user to complete /decide skill installation

**No decision source found:**
- "I couldn't find decisions in [source]. Can you point me to: (1) research directory, (2) MASTER_PLAN.md with decisions section, or (3) describe the decision in chat?"

**Research directory exists but no reports:**
- "Research directory exists but I found no reports. Expected report.md, openai.md, perplexity.md, or gemini.md. Should I skip research context?"

## Example Invocations

```
/decide .claude/research/DeepResearch_Auth_2026-02-11
→ Generates configurator from deep research findings on auth methods

/decide plan
→ Generates configurator from current MASTER_PLAN.md architectural decisions

/decide monitor purchase decision
→ Analyzes recent conversation about monitor purchasing, generates configurator

/decide "nextjs vs remix" after research
→ Looks for recent research on Next.js vs Remix, generates framework comparison configurator
```

## Write Context Summary (MANDATORY — do this LAST)

Write a compact result summary so the parent session receives key findings:

```bash
cat > .claude/.skill-result.md << 'SKILLEOF'
## Decision Configurator Result

**Decisions made:** [n]
**Confirmed DEC-IDs:** [DEC-XXX-001, DEC-XXX-002, ...]

### Decisions Summary
1. [DEC-ID]: [Choice made] — [1-line rationale]
2. [DEC-ID]: [Choice made] — [1-line rationale]

### Pending
- [Any decisions deferred or needing follow-up]
SKILLEOF
```

Keep under 2000 characters. This is consumed by a hook — the parent session will see it automatically.

---

## Notes

- The configurator is a single HTML file — no build tools, no npm, no server
- It works offline after generation
- Users can save and share the HTML file
- The config JSON is embedded directly in the HTML (view source to see it)
- All styling is scoped within the file — no external CSS
- JavaScript is vanilla ES6 — no frameworks

---

**This skill enables the Planner to present complex trade-off analysis as explorable interfaces, making architectural decisions tangible and user-driven.**

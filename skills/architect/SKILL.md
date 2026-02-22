---
name: architect
description: Content-agnostic structural analysis — maps any codebase, document set, or folder into Mermaid diagrams, per-module documentation, and a reusable manifest.
argument-hint: "[path] [--research] [--analytics] [--depth essentials|deep] [--output path]"
context: fork
agent: general-purpose
allowed-tools: Bash, Read, Write, Glob, Grep, WebSearch, Task, AskUserQuestion
---

<!--
@decision DEC-ARCH-001
@title Skill structure: two-phase Map + Analyze with optional research
@status accepted
@rationale Phase 1 (Map) always runs and produces a self-contained structural manifest and
Mermaid diagrams. Phase 2 (Analyze) is opt-in via --research or --analytics flags so the
skill stays fast for the common case (structural snapshot) while supporting deep analysis
when needed. This matches the uplevel pattern: parallel subagent dispatch for heavy work,
sequential pipeline for the core phase.
-->

# /architect — Content-Agnostic Structural Analysis

Maps any codebase, document set, folder, or mixed content into Mermaid diagrams, per-module
documentation, and a reusable manifest. Useful for onboarding, architecture review, or feeding
structural context into downstream research and analytics.

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Flag | Effect | Default |
|------|--------|---------|
| `[path]` | Target path to analyze | Current working directory |
| `--depth essentials\|deep` | Essentials: overview + summary table only. Deep: per-node detail files too. | `deep` |
| `--output <path>` | Output directory for generated files | `docs/architecture/` |
| `--research` | Run Phase 2: dispatch /deep-research per batch of nodes | Off |
| `--analytics` | Run Phase 2: define structured-analytics contract (placeholder) | Off |

**Example invocations:**
- `/architect` — deep map of CWD, output to docs/architecture/
- `/architect /path/to/repo` — map a specific path
- `/architect --depth essentials` — high-level overview only (no per-node files)
- `/architect --output .claude/arch --depth deep` — custom output path
- `/architect --research` — map + dispatch deep-research per node batch
- `/architect /path/to/docs --depth essentials` — quick map of a document set

---

## Phase 1: Map (Always Runs)

### Step 1: Detect Content Type

Run the detection script to classify the input:

```bash
bash ~/.claude/skills/architect/scripts/detect_content.sh "<resolved_path>"
```

Save the JSON output as `content_info`. It contains:
- `content_type`: one of `codebase`, `documents`, `mixed`, `single_file`
- `root_path`: absolute path
- `languages`: array of `{name, files, percentage}` objects
- `file_counts`: `{total, source, docs, config}`
- `entry_points`: notable root-level files
- `framework_signals`: detected frameworks/tools
- `doc_formats`: detected document formats

If the path does not exist or is unreadable, report the error and stop.

**Edge cases:**
- **Empty directory:** Report as `content_type: "empty"`, write a minimal manifest with zero nodes, and note in essentials.md that no content was found.
- **Binary-heavy repo:** If >80% of files are binary (images, compiled artifacts, archives), warn the user and analyze only the non-binary files.
- **Monorepo:** Treat top-level directories containing their own package manifests (package.json, Cargo.toml, etc.) as separate modules — each becomes a top-level node.
- **Single file:** Skip directory traversal; analyze internal structure only (functions/classes/sections).
- **Permission errors:** Skip unreadable paths, note them in the manifest under `warnings`.

### Step 2: Prepare Output Directory

```bash
OUTPUT_DIR="<resolved_output_path>"
mkdir -p "$OUTPUT_DIR/modules"
```

Write a preliminary `manifest.json` with skeleton structure so downstream steps can append.

### Step 3: Extract Structural Nodes and Edges

Based on `content_type`, use the appropriate analysis strategy:

#### For `codebase`

1. **Directory structure:** List top-level directories. Each significant directory (containing source files) becomes a node.
2. **Package boundaries:** Look for sub-manifests (package.json, Cargo.toml, go.mod, pyproject.toml). Each is a module boundary.
3. **Entry points:** Identify main entrypoints from `content_info.entry_points` plus common conventions (main.ts, index.js, __main__.py, cmd/, src/).
4. **Import/dependency analysis:** For each top-level module, sample 3-5 source files and extract import statements. Build edges from these imports. Use Grep to find cross-module imports:
   ```bash
   # Example for TypeScript
   grep -r "from '\.\./other-module" <path> --include="*.ts" -l
   ```
5. **Config nodes:** package.json, Makefile, Dockerfile, CI configs are config-type nodes.

Each node:
```json
{
  "id": "slug-of-module-name",
  "name": "Human-readable name",
  "type": "module|service|library|config",
  "path": "relative/path",
  "description": "1-2 sentence description from README or inferred from structure",
  "files": ["list", "of", "key", "files"],
  "edges": [{"target": "other-node-id", "type": "depends-on", "description": "why"}],
  "metrics": {"files": 12, "loc": 840, "complexity": "medium"}
}
```

#### For `documents`

1. **Heading structure:** Read each document and extract H1/H2/H3 headings. Each top-level document becomes a node.
2. **Cross-references:** Find `[link text](./other-doc.md)` style links and wikilinks. These become `references` edges.
3. **Topic clustering:** Group documents by shared heading patterns or naming conventions (e.g., `*-api.md`, `*-guide.md`).
4. **Section nodes:** For large documents (>200 lines), create sub-nodes for each major H2 section.

Each node:
```json
{
  "id": "slug-of-doc-name",
  "name": "Document Title",
  "type": "topic|section|concept",
  "path": "relative/path/to/doc.md",
  "description": "First paragraph or abstract of the document",
  "files": ["doc.md"],
  "edges": [{"target": "other-doc", "type": "references", "description": "links to"}]
}
```

#### For `mixed`

Combine both strategies with layered analysis:
1. Run codebase analysis for source directories
2. Run document analysis for doc directories
3. Add `contains` edges from code modules to their co-located docs

#### For `single_file`

Analyze internal structure:
- **Source file:** Extract functions, classes, exported symbols. Each becomes a node of type `section`.
- **Markdown:** Extract H1/H2 sections. Each becomes a node.
- **JSON/YAML/TOML:** Extract top-level keys as nodes.

### Step 4: Generate manifest.json

Write the complete manifest to `$OUTPUT_DIR/manifest.json`. Follow the schema in
`~/.claude/skills/architect/schema/manifest-schema.json`.

Key fields:
```json
{
  "content_type": "<from detect_content.sh>",
  "root": "<absolute path>",
  "generated": "<ISO 8601 timestamp>",
  "nodes": [...],
  "diagrams": {
    "system": "<Mermaid diagram string>",
    "per_node": {}
  }
}
```

### Step 5: Generate Mermaid Diagrams

Select the appropriate template from `~/.claude/skills/architect/templates/`:

| Content Type | Template |
|---|---|
| `codebase` | `mermaid-module-dependency.md` |
| `documents` | `mermaid-concept-map.md` |
| `mixed` | `mermaid-module-dependency.md` (primary) + `mermaid-concept-map.md` (docs layer) |
| `single_file` | `mermaid-data-flow.md` or `mermaid-concept-map.md` |

Populate the template PLACEHOLDER markers with extracted nodes and edges:

**Node format for Mermaid:**
```
ModuleId["Module Name\n(type)"]
```

**Edge format:**
```
ModuleA -->|"depends-on"| ModuleB
ModuleA -.->|"references"| ModuleC
```

**Style classes:**
```
classDef module fill:#dbeafe,stroke:#2563eb
classDef service fill:#dcfce7,stroke:#16a34a
classDef library fill:#fef3c7,stroke:#d97706
classDef config fill:#f3f4f6,stroke:#6b7280
```

Write the populated diagram string into `manifest.json` under `diagrams.system`.

For `--depth deep`: also generate per-node sub-diagrams showing each node's immediate neighbors.
Store these in `manifest.json` under `diagrams.per_node[node_id]`.

### Step 6: Write essentials.md

Write `$OUTPUT_DIR/essentials.md` — the human-readable high-level overview:

```markdown
# Architecture: [Target Name]

**Analyzed:** [ISO date]
**Content type:** [codebase|documents|mixed|single_file]
**Root:** [path]

## System Diagram

```mermaid
[populated system diagram]
```

## Component Summary

| Component | Type | Files | Description |
|-----------|------|-------|-------------|
| [node name] | [type] | [count] | [1-sentence description] |
...

## Key Entry Points

[List from content_info.entry_points + detected main files]

## Languages & Frameworks

[Table of languages with file counts and percentages]

## Notes

[Any warnings: binary-heavy, permission errors, empty dirs, monorepo detection]
```

### Step 7: Write Per-Node Deep-Dive Files (--depth deep only)

For each node in the manifest, write `$OUTPUT_DIR/modules/<node-id>.md`:

```markdown
# [Node Name]

**Type:** [module|service|library|config|topic|section|concept]
**Path:** [relative path]
**Files:** [count] | **LOC:** [count] | **Complexity:** [low|medium|high]

## Purpose

[Description from manifest]

## Dependencies

[List of outbound edges with edge type and description]

## Consumers

[List of inbound edges — nodes that depend on this one]

## Key Files

[List of notable files in this node]

## Sub-diagram

```mermaid
[per-node diagram from manifest.diagrams.per_node]
```
```

Update `manifest.json` `diagrams.per_node` with the Mermaid string for each node.

---

## Phase 2: Analyze (Only with --research or --analytics)

### --research: Deep Research Per Node Batch

1. Read `manifest.json` from Phase 1
2. Group nodes into batches of 3-5 (by dependency proximity — connected nodes together)
3. For each batch, dispatch a Task subagent running /deep-research with a focused brief:

```
Research the following components from the [project name] codebase:
- [node 1 name]: [description]
- [node 2 name]: [description]

Focus on:
- Known patterns, anti-patterns, or best practices for this type of component
- Common failure modes or technical debt signals
- Improvement opportunities

Context: This is a [language/framework] project. The full dependency graph is: [brief summary]
```

4. Collect research results and write `$OUTPUT_DIR/improvements.md`:

```markdown
# Improvement Opportunities

Generated by /architect --research on [date]

## [Node Name]

[Research findings relevant to this node]

### Suggested Actions
- [Actionable improvement]
- [Actionable improvement]
```

### --analytics: Structured Analytics Contract (Placeholder)

When `--analytics` is passed, output a contract file at `$OUTPUT_DIR/analytics-contract.json`:

```json
{
  "version": "1.0",
  "generated": "<timestamp>",
  "manifest": "<path to manifest.json>",
  "requested_analyses": [
    {
      "type": "dependency-cycles",
      "input": "manifest.nodes",
      "expected_output": "Array of cycle paths"
    },
    {
      "type": "complexity-hotspots",
      "input": "manifest.nodes[].metrics",
      "expected_output": "Ranked list of high-complexity nodes"
    },
    {
      "type": "coupling-cohesion",
      "input": "manifest.nodes[].edges",
      "expected_output": "Per-node coupling score"
    }
  ],
  "note": "Dispatch to /structured-analytics when available"
}
```

Inform the user that --analytics requires the /structured-analytics skill (not yet implemented)
and that this contract file defines the expected interface.

---

## Error Handling

| Scenario | Response |
|----------|----------|
| Path does not exist | Report error, stop |
| Path is unreadable (permission denied) | Report error, stop |
| Empty directory | Write manifest with zero nodes, note in essentials.md |
| detect_content.sh not found | Report missing script, check `~/.claude/skills/architect/scripts/` |
| Binary-heavy repo (>80% binary) | Warn, analyze non-binary files only |
| Monorepo (multiple package roots) | Treat each package root as a top-level node |
| Very large repo (>500 source files) | Limit per-node deep-dive to top 20 nodes by file count |
| Single file input | Skip directory traversal, analyze internal structure |
| No jq available | detect_content.sh uses printf fallback; note in output |
| --research with no API keys | Skip research phase, note missing keys, output contract file |

---

## Output File Tree

```
<output_dir>/
  manifest.json          # Machine-readable structural manifest (always)
  essentials.md          # Human-readable overview + system diagram (always)
  modules/               # Per-node deep-dive files (--depth deep only)
    <node-id>.md
    ...
  improvements.md        # Research findings (--research only)
  analytics-contract.json # Analytics contract (--analytics only)
```

---

## Write Context Summary (MANDATORY — do this LAST)

Write a compact result summary so the parent session receives key findings:

```bash
cat > .claude/.skill-result.md << 'SKILLEOF'
## Architect Result: [target name]

**Content type:** [codebase|documents|mixed|single_file]
**Nodes mapped:** [count]
**Output:** [path to essentials.md]

### Structure Summary
- [Top-level modules/topics with 1-line description]
- [Key dependencies identified]
- [Any warnings or notable findings]

### Next Steps
- Review essentials.md for system diagram
- [If --research: improvements.md has research findings]
- [If --analytics: analytics-contract.json defines the structured-analytics interface]
SKILLEOF
```

Keep under 2000 characters. This is consumed by a hook — the parent session will see it automatically.

---

## After Completion

```
---
/architect complete.
- Content type: [type]
- Nodes: [count] mapped
- Output: [output_dir]/essentials.md

[If --depth deep]:  [count] per-node files written to [output_dir]/modules/
[If --research]:    Improvements written to [output_dir]/improvements.md
[If --analytics]:   Contract written to [output_dir]/analytics-contract.json

Want me to dig deeper into any specific component, or run --research on a subset?
```

---
name: architect
description: Content-agnostic structural analysis — maps any codebase, document set, or folder into Mermaid diagrams, per-module documentation, and a reusable manifest.
argument-hint: "[path] [--research] [--analytics] [--depth essentials|deep] [--output path]"
visibility: private
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

Phase 2 only runs when `--research` or `--analytics` is passed. Both flags may be used together.
Phase 1 must have already completed and written `manifest.json` to `$OUTPUT_DIR`.

### --research: Deep Research Per Node Batch

<!--
@decision DEC-ARCH-003
@title Sequential batch dispatch for --research to avoid .skill-result.md collision
@status accepted
@rationale /deep-research writes its result to .claude/.skill-result.md. Parallel Task
dispatch would cause batches to overwrite each other's results. Sequential dispatch (one
batch at a time, read result, then dispatch next) is slower but correct. Batch size
cap of 5 prevents context overflow in /deep-research. Path-prefix grouping keeps
related nodes together for richer cross-node analysis.
-->

**Step 1: Pre-check**

Verify `$OUTPUT_DIR/manifest.json` exists. If missing, stop with:
```
Error: manifest.json not found in $OUTPUT_DIR.
Phase 1 must complete before Phase 2 can run. Run /architect without --research first.
```

**Step 2: Read manifest**

Read `$OUTPUT_DIR/manifest.json`. Extract `nodes` array (list of all nodes), `content_type`,
`root`, `detect_info`, and `diagrams.system`.

If `nodes` is empty or has length 0, write `$OUTPUT_DIR/improvements.md` with:
```
No nodes found in manifest — nothing to research.
```
and stop.

**Step 3: Batch the nodes**

Use this concrete heuristic based on total node count:

- **<= 5 nodes total:** Single batch containing all nodes.

- **6–15 nodes:** Group by shared path prefix (first path segment after root).
  - Nodes whose `path` starts with the same top-level directory go in the same batch.
  - Nodes with no `path` field (concepts, topics) form their own batch.
  - If any group exceeds 5 nodes: split it at the 5-node boundary (alphabetical by node id).
  - If any group has only 1 node: merge it into the group it shares the most edges with (count
    edges where source or target is in that group). Break ties by alphanumeric group key.

- **> 15 nodes:** Same path-prefix grouping as above, but cap at 4 batches total.
  - After initial path-prefix grouping, merge the smallest groups until you have at most 4.
  - Merge smallest into second-smallest, repeat until 4 or fewer remain.
  - Each batch should aim for 3–5 nodes; if a merged batch exceeds 5, it's acceptable (max ~8).

- **Edge refinement (apply after path-prefix grouping, any size):**
  After forming batches, scan all edges. If two nodes in different batches have a `depends-on`
  edge AND moving the source node to join its target's batch would NOT cause that batch to
  exceed 5 nodes, move the source node. Apply at most one move per edge to avoid cascade.

**Step 4: Generate research brief per batch**

For each batch, read the template at `~/.claude/skills/architect/templates/research-brief.md`.
Populate all PLACEHOLDER markers with manifest data:

- `PLACEHOLDER: project-name` → `basename` of `manifest.root`
- `PLACEHOLDER: content-type` → `manifest.content_type`
- `PLACEHOLDER: language-framework-context` → From `manifest.detect_info`: list top 2 languages
  by percentage and any `framework_signals`. Example: "TypeScript (72%), JavaScript (28%). Framework signals: Next.js, React."
- `PLACEHOLDER: batch-nodes` → For each node in this batch:
  ```
  - **[node.name]** ([node.type]): [node.description]
    - Path: [node.path or "N/A"]
    - Files: [node.metrics.files or "?"] | LOC: [node.metrics.loc or "?"] | Complexity: [node.metrics.complexity or "unknown"]
    - Key files: [node.files joined by ", " or "N/A"]
  ```
- `PLACEHOLDER: batch-relationships` → For each edge where BOTH source node and target node are
  in this batch:
  ```
  - [source node name] --[edge.type]--> [target node name]: [edge.description or ""]
  ```
  If no intra-batch edges exist, write: "(no relationships within this batch)"
- `PLACEHOLDER: external-edges` → For each edge where source is in this batch but target is NOT:
  ```
  - [source node name] --[edge.type]--> [target node name] (not in this batch)
  ```
  If none, write: "(no cross-batch dependencies)"
- `PLACEHOLDER: system-context` → First 3 lines of `manifest.diagrams.system` as a text summary,
  plus: "Total nodes: [N]. Content type: [content_type]."

**Step 5: Dispatch per batch (sequential)**

For each batch (index 0, 1, 2, ...):
1. Populate the brief (Step 4).
2. Dispatch a Task subagent:
   ```
   Task(
     subagent_type="general-purpose",
     prompt="Run /deep-research with the following research brief:\n\n[populated brief]",
     max_turns=30
   )
   ```
3. After the Task returns, read `~/.claude/.skill-result.md`. Store its content as `batch_results[i]`.
4. If the file is missing or empty, store `batch_results[i] = "INCOMPLETE: dispatch returned no result"`.
5. Proceed to the next batch only after the current Task completes.

Do NOT dispatch batches in parallel — `.skill-result.md` is a shared file and parallel writes corrupt results.

**Step 6: Fold results into improvements.md**

After all batches complete, write `$OUTPUT_DIR/improvements.md`:

```markdown
# Improvement Opportunities

Generated by /architect --research on [ISO date]
Based on [total node count] nodes in [batch count] batches

---

## [node.name] ([node.type])

**Path:** [node.path or "N/A"]
**Complexity:** [node.metrics.complexity or "unknown"]

### Findings

[Extract the section of batch_results[i] most relevant to this specific node.
If the research covered multiple nodes in the batch, synthesize only the portion
about this node. Do not copy-paste the entire batch result — distill it.]

### Suggested Actions

- [Actionable improvement 1]
- [Actionable improvement 2]
- [Add as many as the research supports; omit if research was incomplete]

### Confidence

[high|medium|low] — Based on [consensus across 3 providers | majority agreement | single provider | incomplete research]

### Related

- See [modules/[node.id].md](modules/[node.id].md) for structural deep-dive
- Connected to: [list of node names linked by any edge type]

---

[Repeat the above block for each node across all batches, ordered by batch then by node position in batch]

## Incomplete Batches

[List each batch index where batch_results[i] contains "INCOMPLETE", with the node names that were not researched.
If all batches succeeded, omit this section entirely.]
```

**Step 7: Error handling for --research**

| Scenario | Action |
|----------|--------|
| No `manifest.json` | Error: "Phase 1 must complete first." Stop. |
| 0 nodes in manifest | Write improvements.md with note, stop. |
| No API keys for /deep-research | Write improvements.md with note: "Research dispatch skipped — /deep-research requires API keys for OpenAI, Perplexity, and Gemini." Stop. |
| Task dispatch returns empty | Mark batch as INCOMPLETE, continue to next batch. |
| Task dispatch throws | Catch error, mark batch as INCOMPLETE with error message, continue. |
| All batches INCOMPLETE | Write improvements.md with Incomplete Batches section covering all nodes. |

---

### --analytics: Structured Analytics Contract

**Step 1: Pre-check**

Same as --research: verify `$OUTPUT_DIR/manifest.json` exists. If missing, stop with the same error.

**Step 2: Write analytics-contract.json**

Write `$OUTPUT_DIR/analytics-contract.json` with this exact structure:

```json
{
  "version": "1.0",
  "generated": "[ISO 8601 timestamp — use current datetime]",
  "manifest": "[absolute path to $OUTPUT_DIR/manifest.json]",
  "requested_analyses": [
    {
      "type": "dependency-cycles",
      "input": "manifest.nodes[*].edges where type=depends-on",
      "expected_output": "Array of cycle paths, each path being an ordered array of node IDs forming a dependency cycle"
    },
    {
      "type": "complexity-hotspots",
      "input": "manifest.nodes[*].metrics",
      "expected_output": "Ranked list of nodes by composite complexity score (LOC * file_count * complexity_weight), highest first"
    },
    {
      "type": "coupling-cohesion",
      "input": "manifest.nodes[*].edges",
      "expected_output": "Per-node object with afferent_coupling (inbound edges), efferent_coupling (outbound edges), instability ratio (Ce / (Ca + Ce))"
    }
  ],
  "note": "Contract for future /structured-analytics skill. Dispatch to /structured-analytics when available. Currently no implementation exists."
}
```

The contract schema is defined at `~/.claude/skills/architect/schema/analytics-input-schema.json`.

**Step 3: Inform the user**

After writing the file, tell the user:
```
analytics-contract.json written to $OUTPUT_DIR.

This contract defines the expected interface for the /structured-analytics skill,
which is not yet implemented. The contract file specifies 3 analysis types:
dependency-cycles, complexity-hotspots, and coupling-cohesion.

When /structured-analytics becomes available, pass it the path to analytics-contract.json
to run all three analyses against your manifest.
```

**Step 4: Error handling for --analytics**

| Scenario | Action |
|----------|--------|
| No `manifest.json` | Error: "Phase 1 must complete first." Stop. |
| Cannot write to `$OUTPUT_DIR` | Report permission error, stop. |

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

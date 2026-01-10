---
name: surface
description: Surface living documentation from source annotations
allowed-tools: Read, Write, Grep, Glob, Task
---

# Surface Living Documentation

Reconcile decision annotations in source code with generated documentation.

## Usage

```
/project:surface [flags]
```

## Flags
- `--check-only`: Validate without writing (for CI)
- `--scope=<path>`: Limit extraction to directory
- `--format=json|summary`: Output format
- `--verbose`: Show detailed validation output

## Pipeline

### 1. Extract

Spawn extractor agents to scan source directories in parallel.
Find all `@decision` blocks and `# DECISION:` inline annotations.

**Report**: `[SURFACE] Extracting decisions from {path}/`

**Patterns detected**:
```typescript
/**
 * @decision ADR-001
 * @title OAuth2 with PKCE for mobile auth
 * @status accepted
 * @rationale Mobile apps cannot securely store client secrets
 */
```

```python
# DECISION: Use connection pooling. Rationale: reduces latency 40%. Status: accepted.
```

```go
// DECISION(DEC-API-001): Rate limit at 100 req/min. Rationale: Prevent abuse.
```

### 2. Validate

For each decision, verify:
- **Required fields**: id, title, status, rationale
- **Valid status**: proposed | accepted | deprecated | superseded
- **ID format**: `ADR-XXX` or `DEC-COMPONENT-XXX`
- **References resolve**: `superseded_by` points to existing decision

**Report**: `[SURFACE] {total} decisions found, {new} new, validating...`

**Validation errors**:
- Missing required field
- Invalid status value
- Duplicate ID
- Broken supersession reference
- Circular supersession chain

### 3. Generate (unless --check-only)

Write to `docs/decisions/`:

```
docs/decisions/
├── index.md              # Master list with status badges
├── system/               # Cross-cutting decisions
│   ├── ADR-001.md
│   └── ADR-002.md
├── components/           # By-component grouping
│   └── auth/
│       └── decisions.md
└── graph.json            # Dependency visualization data
```

**Report**: `[SURFACE] Generated {n} files`

### 4. Summary

Return structured result:

```json
{
  "decisions": {
    "total": 12,
    "new": 1,
    "modified": 0,
    "deprecated": 2
  },
  "validation": {
    "errors": [],
    "warnings": ["ADR-003 missing rationale"]
  },
  "generated": [
    "docs/decisions/index.md",
    "docs/decisions/system/ADR-001.md"
  ]
}
```

**Report**: `[OUTCOME] Documentation current` or `[OUTCOME] {n} changes published`

## Examples

### Validate without writing (CI integration)
```bash
claude -p "/project:surface --check-only"
```

### Surface specific component
```bash
claude -p "/project:surface --scope=src/auth"
```

### Full surface with verbose output
```bash
claude -p "/project:surface --verbose"
```

## Integration

### CI Workflow
```yaml
- uses: anthropics/claude-code-action@v1
  with:
    prompt: "/project:surface --check-only"
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

### Git Hook (pre-push)
```bash
claude -p "/project:surface --check-only --format=json" || exit 1
```

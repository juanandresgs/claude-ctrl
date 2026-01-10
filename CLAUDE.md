# Claude Code Configuration

## Development Root
Use ~/Code/ as the development root directory.

## Available Commands
Use /sc: commands for workflows: implement, build, test, analyze, troubleshoot, explain, improve, cleanup, git, workflow

Use /project:surface to surface living documentation from source annotations.

## Living Documentation System

This environment uses Living Documentation. The system enforces decision annotations on source files and surfaces them into navigable documentation.

### Decision Annotations

Source files over 50 lines require decision annotations:

**TypeScript/JavaScript Block Format**:
```typescript
/**
 * @decision DEC-COMPONENT-001
 * @title Brief description
 * @status accepted
 * @rationale Why this approach was chosen
 * @context Background information (optional)
 * @consequences What follows from this (optional)
 * @alternatives What was considered (optional)
 */
```

**Python/Shell Inline Format**:
```python
# DECISION: Use connection pooling. Rationale: reduces latency 40%. Status: accepted.
```

**Go/Rust/C++ Inline Format**:
```go
// DECISION(DEC-API-001): Rate limit at 100 req/min. Rationale: Prevent abuse. Status: accepted.
```

### Required Fields

| Field | Description |
|-------|-------------|
| `id` | Unique identifier (ADR-XXX or DEC-COMPONENT-XXX) |
| `title` | Brief description (max 100 chars) |
| `status` | proposed, accepted, deprecated, superseded |
| `rationale` | Why this decision was made |

### Commands

- `/project:surface` — Regenerate documentation from source annotations
- `/project:surface --check-only` — Validate without writing (for CI)
- `/project:surface --verbose` — Show detailed validation output

### Gate Behavior

The gate hook currently runs in **warn mode** by default. Files without annotations will show warnings but writes won't be blocked.

To enable enforcement:
```bash
export GATE_MODE=enforce
```

### Output

Generated documentation lives in `docs/decisions/`. Never edit directly—modify source annotations instead.

### Status Reports

The system reports activity using this format:
```
[STAGE] Brief outcome description
```

Stages flow: `GATE → DECISION → SURFACE → OUTCOME`

Example session output:
```
[GATE] src/auth/middleware.ts requires decision annotation
[GATE] src/auth/middleware.ts ready — DEC-AUTH-001 documented
[DECISION] 3 source files updated this session
[SURFACE] Extracting decisions from src/
[SURFACE] 8 decisions found, 1 new, validating...
[OUTCOME] Documentation current. Run /project:surface to publish.
```

## Reference Documentation

For detailed command documentation: @COMMANDS.md
For flag reference: @FLAGS.md
For core principles: @PRINCIPLES.md
For operational rules: @RULES.md

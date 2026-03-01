#!/usr/bin/env bash
# repair-traces.sh — Scan traces/ for incomplete entries and attempt reconstruction.
#
# Purpose: Identifies stale or incomplete traces that are missing summary.md or
# manifest.json, attempts to reconstruct metadata from available artifacts, and
# reports unrecoverable traces. Provides a --dry-run mode for safe inspection.
#
# Usage:
#   repair-traces.sh [--dry-run] [--traces-dir /path/to/traces]
#
# Exit codes:
#   0 — All traces OK or successfully repaired
#   1 — Unrecoverable traces found (report printed to stdout)
#
# @decision DEC-REPAIR-TRACES-001
# @title repair-traces.sh reconstructs only what can be inferred from artifacts
# @status accepted
# @rationale A trace missing manifest.json is unrecoverable — manifest is the
#   identity record (trace_id, agent_type, project, started_at). Without it, we
#   cannot assign the trace to a project or agent without risky guesswork.
#   A trace missing only summary.md can be partially repaired: if artifacts/
#   contains test-output.txt or verification-output.txt, we can generate a minimal
#   summary.md from that content. Manifest reconstruction is explicitly NOT attempted
#   to avoid creating misleading provenance records. Unrecoverable traces are reported
#   so operators can decide whether to delete them manually.
#
# @decision DEC-REPAIR-TRACES-002
# @title compliance.json regenerated from artifacts when missing
# @status accepted
# @rationale compliance.json is a derived artifact — its content can be reconstructed
#   from the artifacts/ directory contents and manifest.json fields. If compliance.json
#   is missing (legacy trace from before Observatory v2), repair-traces.sh generates a
#   minimal one so that observatory queries have consistent data. The generated file is
#   marked with "source": "repaired" to distinguish it from check-*.sh-generated files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"

# Source core-lib for utility functions if available
if [[ -f "${SCRIPT_DIR}/../hooks/source-lib.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/../hooks/source-lib.sh" 2>/dev/null || true
fi

# Default traces directory
DEFAULT_TRACES_DIR="${CLAUDE_DIR}/traces"
TRACES_DIR="${DEFAULT_TRACES_DIR}"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --traces-dir)
            TRACES_DIR="$2"
            shift 2
            ;;
        --help|-h)
            cat <<EOF
Usage: repair-traces.sh [--dry-run] [--traces-dir /path/to/traces]

Scans traces/ for incomplete entries and attempts reconstruction from artifacts.

Options:
  --dry-run           Preview repairs without writing any files
  --traces-dir PATH   Override the default traces directory (${DEFAULT_TRACES_DIR})
  --help              Show this help

Exit codes:
  0  All traces OK or successfully repaired
  1  Unrecoverable traces found (report printed to stdout)
EOF
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ ! -d "$TRACES_DIR" ]]; then
    echo "Traces directory not found: $TRACES_DIR"
    exit 0
fi

DRY_PREFIX=""
[[ "$DRY_RUN" == "true" ]] && DRY_PREFIX="[DRY-RUN] "

SCANNED=0
REPAIRED=0
UNRECOVERABLE=0
ALREADY_OK=0

echo "Scanning traces in: $TRACES_DIR"
[[ "$DRY_RUN" == "true" ]] && echo "Mode: DRY-RUN (no files will be written)"
echo ""

# Track unrecoverable traces for exit code
UNRECOVERABLE_LIST=()

# Scan all trace directories (pattern: agent-type-YYYYMMDD-HHMMSS-*)
for trace_dir in "$TRACES_DIR"/*/; do
    [[ -d "$trace_dir" ]] || continue
    trace_id=$(basename "$trace_dir")

    # Skip non-trace directories (index.json, etc.)
    [[ "$trace_id" =~ ^(implementer|tester|guardian|planner|explorer|unknown)-[0-9]{8}- ]] || continue

    SCANNED=$((SCANNED + 1))

    has_manifest=false
    has_summary=false
    has_compliance=false
    has_artifacts=false

    [[ -f "$trace_dir/manifest.json" ]] && has_manifest=true
    [[ -f "$trace_dir/summary.md" ]] && has_summary=true
    [[ -f "$trace_dir/compliance.json" ]] && has_compliance=true
    [[ -d "$trace_dir/artifacts" ]] && has_artifacts=true

    # Fully healthy trace
    if [[ "$has_manifest" == "true" && "$has_summary" == "true" && "$has_compliance" == "true" ]]; then
        ALREADY_OK=$((ALREADY_OK + 1))
        continue
    fi

    # --- Case 1: No manifest.json — unrecoverable ---
    if [[ "$has_manifest" == "false" ]]; then
        echo "UNRECOVERABLE: $trace_id"
        echo "  Reason: manifest.json missing — cannot determine agent_type, project, or started_at"
        if [[ "$has_artifacts" == "true" ]]; then
            artifact_count=$(find "$trace_dir/artifacts" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
            echo "  Artifacts present: $artifact_count file(s)"
        else
            echo "  Artifacts: none"
        fi
        echo ""
        UNRECOVERABLE=$((UNRECOVERABLE + 1))
        UNRECOVERABLE_LIST+=("$trace_id (no manifest.json)")
        continue
    fi

    # Read manifest fields for repair context
    agent_type=$(jq -r '.agent_type // "unknown"' "$trace_dir/manifest.json" 2>/dev/null || echo "unknown")
    project=$(jq -r '.project // ""' "$trace_dir/manifest.json" 2>/dev/null || echo "")
    started_at=$(jq -r '.started_at // ""' "$trace_dir/manifest.json" 2>/dev/null || echo "")

    repaired_this=false
    issues=()

    # --- Case 2: Missing summary.md — attempt reconstruction ---
    if [[ "$has_summary" == "false" ]]; then
        issues+=("summary.md missing")

        # Try to reconstruct from available artifacts
        reconstructed_summary=""

        if [[ "$has_artifacts" == "true" ]]; then
            # Prefer verification-output.txt (tester) or test-output.txt (implementer)
            for artifact in "verification-output.txt" "test-output.txt" "commit-info.txt" "diff.patch"; do
                if [[ -f "$trace_dir/artifacts/$artifact" ]]; then
                    artifact_content=$(head -c 3000 "$trace_dir/artifacts/$artifact" 2>/dev/null || echo "")
                    if [[ -n "$artifact_content" ]]; then
                        reconstructed_summary="# Reconstructed summary (repair-traces.sh)
Agent type: $agent_type
Started at: $started_at
Project: $project
Repair timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Content from ${artifact}

\`\`\`
${artifact_content}
\`\`\`"
                        break
                    fi
                fi
            done
        fi

        if [[ -n "$reconstructed_summary" ]]; then
            echo "${DRY_PREFIX}REPAIRABLE: $trace_id"
            echo "  Missing: summary.md"
            echo "  Action: reconstruct from artifacts"
            if [[ "$DRY_RUN" == "false" ]]; then
                echo "$reconstructed_summary" > "$trace_dir/summary.md"
                echo "  Written: summary.md (reconstructed)"
            fi
            repaired_this=true
        else
            # Write a minimal diagnostic summary if no artifacts available
            minimal_summary="# Agent trace — no content available
Agent type: $agent_type
Started at: $started_at
Project: $project
Repair timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Status: Trace has no readable artifacts. Agent may have exited before writing output."
            echo "${DRY_PREFIX}REPAIRABLE: $trace_id"
            echo "  Missing: summary.md"
            echo "  Action: write minimal diagnostic summary (no artifacts available)"
            if [[ "$DRY_RUN" == "false" ]]; then
                echo "$minimal_summary" > "$trace_dir/summary.md"
                echo "  Written: summary.md (minimal diagnostic)"
            fi
            repaired_this=true
        fi
    fi

    # --- Case 3: Missing compliance.json — regenerate from artifacts ---
    if [[ "$has_compliance" == "false" ]]; then
        issues+=("compliance.json missing")

        # Reconstruct compliance.json from manifest + artifact presence
        sm_present=false
        to_present=false
        fc_present=false
        dp_present=false
        vo_present=false
        ci_present=false

        if [[ "$has_artifacts" == "true" ]]; then
            [[ -f "$trace_dir/summary.md" ]] && sm_present=true
            [[ -f "$trace_dir/artifacts/test-output.txt" ]] && to_present=true
            [[ -f "$trace_dir/artifacts/files-changed.txt" ]] && fc_present=true
            [[ -f "$trace_dir/artifacts/diff.patch" ]] && dp_present=true
            [[ -f "$trace_dir/artifacts/verification-output.txt" ]] && vo_present=true
            [[ -f "$trace_dir/artifacts/commit-info.txt" ]] && ci_present=true
        fi

        # Determine test_result from manifest (may have been set by finalize_trace)
        test_result=$(jq -r '.test_result // "not-provided"' "$trace_dir/manifest.json" 2>/dev/null || echo "not-provided")

        echo "${DRY_PREFIX}REPAIRABLE: $trace_id"
        echo "  Missing: compliance.json"
        echo "  Action: regenerate from manifest + artifact presence"

        if [[ "$DRY_RUN" == "false" ]]; then
            # Build artifacts section based on agent type
            case "$agent_type" in
                implementer)
                    artifacts_json="{
    \"summary.md\": {\"present\": $sm_present, \"source\": \"repaired\"},
    \"test-output.txt\": {\"present\": $to_present, \"source\": \"repaired\"},
    \"files-changed.txt\": {\"present\": $fc_present, \"source\": \"repaired\"},
    \"diff.patch\": {\"present\": $dp_present, \"source\": \"repaired\"}
  }"
                    ;;
                tester)
                    artifacts_json="{
    \"summary.md\": {\"present\": $sm_present, \"source\": \"repaired\"},
    \"verification-output.txt\": {\"present\": $vo_present, \"source\": \"repaired\"}
  }"
                    ;;
                guardian)
                    artifacts_json="{
    \"summary.md\": {\"present\": $sm_present, \"source\": \"repaired\"},
    \"commit-info.txt\": {\"present\": $ci_present, \"source\": \"repaired\"}
  }"
                    ;;
                *)
                    artifacts_json="{
    \"summary.md\": {\"present\": $sm_present, \"source\": \"repaired\"}
  }"
                    ;;
            esac

            cat > "$trace_dir/compliance.json" << COMPLIANCE_REPAIR_EOF
{
  "agent_type": "$agent_type",
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "repaired_by": "repair-traces.sh",
  "artifacts": $artifacts_json,
  "test_result": "$test_result",
  "test_result_source": "repaired",
  "issues_count": 0
}
COMPLIANCE_REPAIR_EOF
            echo "  Written: compliance.json (repaired)"
        fi
        repaired_this=true
    fi

    if [[ "$repaired_this" == "true" ]]; then
        REPAIRED=$((REPAIRED + 1))
        echo ""
    fi
done

# Print summary
echo "==================================="
echo "Scan complete"
echo "  Scanned:       $SCANNED"
echo "  Already OK:    $ALREADY_OK"
echo "  Repaired:      $REPAIRED"
echo "  Unrecoverable: $UNRECOVERABLE"

if [[ ${#UNRECOVERABLE_LIST[@]} -gt 0 ]]; then
    echo ""
    echo "Unrecoverable traces:"
    for t in "${UNRECOVERABLE_LIST[@]}"; do
        echo "  - $t"
    done
    echo ""
    echo "To remove unrecoverable traces manually:"
    for t in "${UNRECOVERABLE_LIST[@]}"; do
        trace_name="${t%% *}"
        echo "  rm -rf ${TRACES_DIR}/${trace_name}"
    done
fi

[[ "$DRY_RUN" == "true" ]] && echo ""
[[ "$DRY_RUN" == "true" ]] && echo "DRY-RUN: no files were modified"

# Exit 1 if unrecoverable traces exist
[[ "$UNRECOVERABLE" -gt 0 ]] && exit 1
exit 0

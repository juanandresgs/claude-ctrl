#!/usr/bin/env bash
# release-public.sh — generate clean public export from visibility declarations
#
# Reads: VISIBILITY.yaml (registry) + skills/*/SKILL.md + agents/*.md frontmatter
# Produces: file list (--dry-run), staging directory (--staging), or tarball (--tarball)
#
# Usage:
#   release-public.sh --dry-run
#   release-public.sh --staging /path/to/staging/dir
#   release-public.sh --tarball /path/to/output.tar.gz
#
# @decision DEC-VIS-001
# @title VISIBILITY.yaml as single source of truth for non-skill/agent public components
# @status accepted
# @rationale Skills and agents self-declare via frontmatter; everything else is governed
#   centrally in VISIBILITY.yaml. This two-tier approach avoids scattering visibility
#   metadata across many config files while still keeping skill/agent declarations
#   co-located with their content. The release script merges both sources at export time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VISIBILITY_FILE="$ROOT_DIR/VISIBILITY.yaml"

# ─── Argument parsing ────────────────────────────────────────────────────────
MODE=""
MODE_ARG=""

usage() {
    echo "Usage: $0 --dry-run | --staging DIR | --tarball FILE"
    echo ""
    echo "  --dry-run          Print the list of public files that would be exported"
    echo "  --staging DIR      Rsync public files into DIR (creates if missing)"
    echo "  --tarball FILE     Package public files into FILE (gzip tarball)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            MODE="dry-run"
            shift
            ;;
        --staging)
            MODE="staging"
            MODE_ARG="${2:-}"
            if [[ -z "$MODE_ARG" ]]; then
                echo "ERROR: --staging requires a directory argument" >&2
                usage
            fi
            shift 2
            ;;
        --tarball)
            MODE="tarball"
            MODE_ARG="${2:-}"
            if [[ -z "$MODE_ARG" ]]; then
                echo "ERROR: --tarball requires a file argument" >&2
                usage
            fi
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage
            ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "ERROR: Must specify --dry-run, --staging DIR, or --tarball FILE" >&2
    usage
fi

# ─── Verify inputs ────────────────────────────────────────────────────────────
if [[ ! -f "$VISIBILITY_FILE" ]]; then
    echo "ERROR: VISIBILITY.yaml not found at $VISIBILITY_FILE" >&2
    exit 1
fi

# ─── Parse VISIBILITY.yaml ────────────────────────────────────────────────────
# Parses flat YAML with this structure:
#   public:
#     category:
#       - file1
#       - file2   # optional comment
#
# Populates PUBLIC_FILES array with "category/file" entries.
declare -a PUBLIC_FILES=()

parse_visibility_yaml() {
    local current_category=""
    local in_public=0

    while IFS= read -r line; do
        # Skip blank lines and pure comment lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        # Detect top-level "public:" section
        if [[ "$line" =~ ^public: ]]; then
            in_public=1
            continue
        fi

        # Detect end of public section (another top-level key, non-indented)
        if [[ $in_public -eq 1 && "$line" =~ ^[a-z] && ! "$line" =~ ^public: ]]; then
            in_public=0
            continue
        fi

        # Skip if not in public section
        [[ $in_public -eq 0 ]] && continue

        # Detect category header (2-space indent + word + colon)
        if [[ "$line" =~ ^[[:space:]]{2}([a-z_]+): ]]; then
            current_category="${BASH_REMATCH[1]}"
            continue
        fi

        # Detect list entry (4-space indent + "- ")
        if [[ "$line" =~ ^[[:space:]]{4}-[[:space:]]+(.*) ]]; then
            local entry="${BASH_REMATCH[1]}"
            # Strip trailing comment (everything after " # ")
            entry="${entry%% \#*}"
            # Strip trailing whitespace
            entry="$(echo "$entry" | sed 's/[[:space:]]*$//')"

            if [[ -n "$current_category" && -n "$entry" ]]; then
                PUBLIC_FILES+=("${current_category}/${entry}")
            fi
            continue
        fi
    done < "$VISIBILITY_FILE"
}

parse_visibility_yaml

# ─── Scan skills frontmatter ──────────────────────────────────────────────────
# Populates PUBLIC_SKILLS array with "skills/<name>" entries.
declare -a PUBLIC_SKILLS=()

scan_skills() {
    local skills_dir="$ROOT_DIR/skills"
    [[ ! -d "$skills_dir" ]] && return

    while IFS= read -r skill_file; do
        local skill_dir
        skill_dir="$(dirname "$skill_file")"
        local skill_name
        skill_name="$(basename "$skill_dir")"
        local visibility=""
        local in_frontmatter=0
        local fm_count=0

        while IFS= read -r line; do
            if [[ "$line" == "---" ]]; then
                fm_count=$((fm_count + 1))
                if [[ $fm_count -eq 1 ]]; then
                    in_frontmatter=1
                    continue
                elif [[ $fm_count -ge 2 ]]; then
                    break
                fi
            fi
            if [[ $in_frontmatter -eq 1 && "$line" =~ ^visibility:[[:space:]]*(.*) ]]; then
                visibility="${BASH_REMATCH[1]}"
                break
            fi
        done < "$skill_file"

        if [[ "$visibility" == "public" ]]; then
            PUBLIC_SKILLS+=("skills/${skill_name}")
        fi
    done < <(find "$skills_dir" -name "SKILL.md" | sort)
}

scan_skills

# ─── Scan agents frontmatter ──────────────────────────────────────────────────
# Populates PUBLIC_AGENTS array with "agents/<name>.md" entries.
declare -a PUBLIC_AGENTS=()

scan_agents() {
    local agents_dir="$ROOT_DIR/agents"
    [[ ! -d "$agents_dir" ]] && return

    while IFS= read -r agent_file; do
        local agent_name
        agent_name="$(basename "$agent_file")"
        local visibility=""
        local in_frontmatter=0
        local fm_count=0

        while IFS= read -r line; do
            if [[ "$line" == "---" ]]; then
                fm_count=$((fm_count + 1))
                if [[ $fm_count -eq 1 ]]; then
                    in_frontmatter=1
                    continue
                elif [[ $fm_count -ge 2 ]]; then
                    break
                fi
            fi
            if [[ $in_frontmatter -eq 1 && "$line" =~ ^visibility:[[:space:]]*(.*) ]]; then
                visibility="${BASH_REMATCH[1]}"
                break
            fi
        done < "$agent_file"

        if [[ "$visibility" == "public" ]]; then
            PUBLIC_AGENTS+=("agents/${agent_name}")
        fi
    done < <(find "$agents_dir" -name "*.md" | sort)
}

scan_agents

# ─── Build combined inclusion list ───────────────────────────────────────────
# Maps category-prefixed entries to real relative paths under ROOT_DIR.
declare -a INCLUSION_LIST=()

category_to_prefix() {
    # Echoes the directory prefix for a given category
    local cat="$1"
    case "$cat" in
        hooks)    echo "hooks" ;;
        tests)    echo "tests" ;;
        agents)   echo "agents" ;;
        config)   echo "" ;;        # config entries live at root level
        commands) echo "commands" ;;
        skills)   echo "skills" ;;
        *)        echo "$cat" ;;
    esac
}

resolve_paths() {
    local entry cat name prefix
    local -a combined=("${PUBLIC_FILES[@]}" "${PUBLIC_SKILLS[@]}" "${PUBLIC_AGENTS[@]}")

    for entry in "${combined[@]}"; do
        cat="${entry%%/*}"
        name="${entry#*/}"
        prefix="$(category_to_prefix "$cat")"

        if [[ -z "$prefix" ]]; then
            INCLUSION_LIST+=("$name")
        else
            INCLUSION_LIST+=("${prefix}/${name}")
        fi
    done
}

resolve_paths

# ─── Helper: run leak check on a staging directory ───────────────────────────
run_leak_check() {
    local staging_dir="$1"
    echo ""
    echo "--- Leak check ---"
    local pattern='todo\.sh|community-check|observatory/|MASTER_PLAN'
    local found=0

    if grep -rElq "$pattern" "$staging_dir" 2>/dev/null; then
        echo "WARNING: Potential private content detected in staging:"
        grep -rEl "$pattern" "$staging_dir" 2>/dev/null || true
        found=1
    else
        echo "PASS: No private content leaked."
    fi

    return $found
}

# ─── Helper: copy a single entry to a destination directory ──────────────────
copy_entry() {
    local entry="$1"
    local dest_root="$2"
    local src="$ROOT_DIR/$entry"

    # Handle directory entries (trailing slash notation from VISIBILITY.yaml)
    if [[ "$entry" == */ ]]; then
        local dir_entry="${entry%/}"
        src="$ROOT_DIR/$dir_entry"
        if [[ -d "$src" ]]; then
            mkdir -p "$dest_root/$(dirname "$dir_entry")"
            rsync -a "$src/" "$dest_root/$dir_entry/"
            echo "  DIR  $entry"
        else
            echo "  SKIP $entry (directory not found at $src)"
        fi
    elif [[ -d "$src" ]]; then
        # Skills entries are directories (no trailing slash in array)
        mkdir -p "$dest_root/$(dirname "$entry")"
        rsync -a "$src/" "$dest_root/$entry/"
        echo "  DIR  $entry/"
    elif [[ -f "$src" ]]; then
        mkdir -p "$dest_root/$(dirname "$entry")"
        rsync -a "$src" "$dest_root/$entry"
        echo "  FILE $entry"
    else
        echo "  SKIP $entry (not found at $src)"
    fi
}

# ─── Mode: dry-run ────────────────────────────────────────────────────────────
if [[ "$MODE" == "dry-run" ]]; then
    echo "=== Public Export File List (dry-run) ==="
    echo ""
    echo "Source: $ROOT_DIR"
    echo ""
    echo "--- From VISIBILITY.yaml ---"
    for f in "${PUBLIC_FILES[@]}"; do
        cat="${f%%/*}"
        name="${f#*/}"
        prefix="$(category_to_prefix "$cat")"
        if [[ -z "$prefix" ]]; then
            echo "  $name"
        else
            echo "  ${prefix}/${name}"
        fi
    done

    echo ""
    echo "--- From skill frontmatter (visibility: public) ---"
    for s in "${PUBLIC_SKILLS[@]}"; do
        echo "  $s/"
    done

    echo ""
    echo "--- From agent frontmatter (visibility: public) ---"
    for a in "${PUBLIC_AGENTS[@]}"; do
        echo "  $a"
    done

    echo ""
    echo "Total entries: ${#INCLUSION_LIST[@]}"
    exit 0
fi

# ─── Mode: staging ────────────────────────────────────────────────────────────
if [[ "$MODE" == "staging" ]]; then
    STAGING_DIR="$MODE_ARG"
    mkdir -p "$STAGING_DIR"

    echo "=== Staging Public Export ==="
    echo "Source: $ROOT_DIR"
    echo "Dest:   $STAGING_DIR"
    echo ""

    for entry in "${INCLUSION_LIST[@]}"; do
        copy_entry "$entry" "$STAGING_DIR"
    done

    echo ""
    echo "Staging complete: $STAGING_DIR"

    leak_exit=0
    run_leak_check "$STAGING_DIR" || leak_exit=$?
    if [[ $leak_exit -ne 0 ]]; then
        echo ""
        echo "WARNING: Review the flagged files before distributing."
    fi

    exit 0
fi

# ─── Mode: tarball ────────────────────────────────────────────────────────────
if [[ "$MODE" == "tarball" ]]; then
    TARBALL_FILE="$MODE_ARG"

    TMPDIR_STAGING="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_STAGING"' EXIT

    echo "=== Packaging Public Export ==="
    echo "Source: $ROOT_DIR"
    echo "Output: $TARBALL_FILE"
    echo ""

    for entry in "${INCLUSION_LIST[@]}"; do
        copy_entry "$entry" "$TMPDIR_STAGING"
    done

    leak_exit=0
    run_leak_check "$TMPDIR_STAGING" || leak_exit=$?
    if [[ $leak_exit -ne 0 ]]; then
        echo ""
        echo "WARNING: Tarball may contain private content. Review before distributing."
    fi

    tar -czf "$TARBALL_FILE" -C "$TMPDIR_STAGING" .
    echo ""
    echo "Tarball created: $TARBALL_FILE"
    echo "Size: $(du -sh "$TARBALL_FILE" | cut -f1)"

    exit 0
fi

#!/usr/bin/env bash
# detect_content.sh — Classify input content type for /architect skill.
#
# @decision DEC-ARCH-002
# @title Shell implementation with jq-optional JSON output
# @status accepted
# @rationale Pure bash for zero dependencies and fast startup. jq is used when
# available for clean JSON serialization; printf fallback ensures the script
# works in environments without jq. Mirrors detect_project.sh pattern from
# /uplevel skill.
#
# Usage: bash detect_content.sh [path]
# Output: JSON to stdout describing content type and structure.
#
# Content types:
#   codebase    — directory with source code files
#   documents   — directory with only documentation files (no source code)
#   mixed       — directory with both source and documentation
#   single_file — input is a file, not a directory

set -euo pipefail

INPUT_PATH="${1:-.}"

# Resolve to absolute path
if command -v realpath > /dev/null 2>&1; then
    INPUT_PATH="$(realpath "$INPUT_PATH")"
elif command -v python3 > /dev/null 2>&1; then
    INPUT_PATH="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$INPUT_PATH")"
else
    # POSIX fallback
    INPUT_PATH="$(cd "$(dirname "$INPUT_PATH")" && pwd)/$(basename "$INPUT_PATH")"
fi

# --- Error handling ---

if [[ ! -e "$INPUT_PATH" ]]; then
    echo '{"error":"path does not exist","content_type":"unknown","root_path":"'"$INPUT_PATH"'"}' >&2
    exit 1
fi

# --- Single file detection ---

if [[ -f "$INPUT_PATH" ]]; then
    ext="${INPUT_PATH##*.}"
    printf '{"content_type":"single_file","root_path":"%s","file_extension":".%s","languages":[],"file_counts":{"total":1,"source":0,"docs":0,"config":0},"entry_points":["%s"],"framework_signals":[],"doc_formats":[]}\n' \
        "$INPUT_PATH" "$ext" "$(basename "$INPUT_PATH")"
    exit 0
fi

# From here: input is a directory
ROOT="$INPUT_PATH"

# --- Helpers ---

has_file()  { [[ -f "$ROOT/$1" ]]; }
has_dir()   { [[ -d "$ROOT/$1" ]]; }
has_glob()  { compgen -G "$ROOT/$1" > /dev/null 2>&1; }

count_files_by_ext() {
    local exts=("$@")
    local count=0
    for ext in "${exts[@]}"; do
        local n
        n=$(find "$ROOT" -type f -name "*.$ext" \
            -not -path '*/.git/*' \
            -not -path '*/node_modules/*' \
            -not -path '*/vendor/*' \
            -not -path '*/__pycache__/*' \
            -not -path '*/target/*' \
            -not -path '*/.next/*' \
            -not -path '*/dist/*' \
            -not -path '*/build/*' \
            2>/dev/null | wc -l | tr -d ' ')
        count=$((count + n))
    done
    echo "$count"
}

count_files_total() {
    find "$ROOT" -type f \
        -not -path '*/.git/*' \
        -not -path '*/node_modules/*' \
        -not -path '*/vendor/*' \
        -not -path '*/__pycache__/*' \
        -not -path '*/target/*' \
        -not -path '*/.next/*' \
        -not -path '*/dist/*' \
        -not -path '*/build/*' \
        2>/dev/null | wc -l | tr -d ' '
}

# --- Count source files ---

SOURCE_EXTS=(js ts jsx tsx py go rs java c cpp h hpp sh bash rb cs vue svelte)
DOC_EXTS=(md txt rst adoc asciidoc)
CONFIG_EXTS=(json yaml yml toml ini cfg conf)

source_count=$(count_files_by_ext "${SOURCE_EXTS[@]}")
doc_count=$(count_files_by_ext "${DOC_EXTS[@]}")
config_count=$(count_files_by_ext "${CONFIG_EXTS[@]}")
total_count=$(count_files_total)

# --- Determine content type ---

# Codebase: has a package manifest OR significant source files (>2)
has_package_manifest="false"
for manifest in package.json Cargo.toml go.mod pyproject.toml setup.py Makefile Gemfile pom.xml build.gradle; do
    if has_file "$manifest"; then
        has_package_manifest="true"
        break
    fi
done

# Also treat it as codebase if there's a .git directory
has_git="false"
if has_dir ".git" || git -C "$ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    has_git="true"
fi

# Determine whether this looks like a codebase, document set, or both.
#
# Rules:
#   mixed     = significant source code (>2 files or package manifest) AND doc files present (>=1)
#   codebase  = significant source code, no doc files
#   documents = only doc files, no significant source code (<=2 source files)
#   empty     = no files at all
#
# The "significant source" threshold (>2) avoids false positives when a doc repo
# has a lone build script or config file.
has_significant_source="false"

if [[ "$has_package_manifest" == "true" ]] || \
   ( [[ "$has_git" == "true" ]] && [[ "$source_count" -gt 2 ]] ) || \
   [[ "$source_count" -gt 2 ]]; then
    has_significant_source="true"
fi

# Determine final content_type
if [[ "$has_significant_source" == "true" ]] && [[ "$doc_count" -gt 0 ]]; then
    # Source code project WITH documentation files → mixed
    CONTENT_TYPE="mixed"
elif [[ "$has_significant_source" == "true" ]]; then
    # Source code only
    CONTENT_TYPE="codebase"
elif [[ "$doc_count" -gt 0 ]]; then
    # Documentation only (source_count <= 2, treated as noise/config)
    CONTENT_TYPE="documents"
elif [[ "$total_count" -eq 0 ]]; then
    CONTENT_TYPE="empty"
else
    # Some files but not clearly categorized — default to codebase
    CONTENT_TYPE="codebase"
fi

# --- Language detection ---
# Bash 3.2 compatible (macOS default) — no declare -A associative arrays.
# Use parallel indexed arrays: lang_names[i] and lang_file_counts[i].

lang_names=()
lang_file_counts=()

add_lang() {
    local lang="$1"
    shift
    local c
    c=$(count_files_by_ext "$@")
    if [[ "$c" -gt 0 ]]; then
        lang_names+=("$lang")
        lang_file_counts+=("$c")
    fi
}

add_lang "javascript"  js jsx
add_lang "typescript"  ts tsx
add_lang "python"      py
add_lang "go"          go
add_lang "rust"        rs
add_lang "java"        java
add_lang "c"           c h
add_lang "cpp"         cpp hpp
add_lang "shell"       sh bash
add_lang "ruby"        rb
add_lang "csharp"      cs
add_lang "vue"         vue
add_lang "svelte"      svelte
add_lang "markdown"    md
add_lang "yaml"        yaml yml
add_lang "toml"        toml

# Build languages JSON array from parallel arrays
languages_json="["
first_lang=true
i=0
while [[ $i -lt ${#lang_names[@]} ]]; do
    lname="${lang_names[$i]}"
    lcount="${lang_file_counts[$i]}"
    pct=0
    if [[ "$source_count" -gt 0 ]]; then
        pct=$(( lcount * 100 / source_count ))
    fi
    if [[ "$first_lang" == "true" ]]; then
        first_lang=false
    else
        languages_json+=","
    fi
    languages_json+="{\"name\":\"$lname\",\"files\":$lcount,\"percentage\":$pct}"
    i=$((i + 1))
done
languages_json+="]"

# --- Entry points detection ---

entry_points=()
for ep in package.json Cargo.toml go.mod pyproject.toml Makefile README.md index.ts index.js main.py src/main.rs cmd/main.go; do
    if has_file "$ep"; then
        entry_points+=("$ep")
    fi
done

entry_points_json="["
first_ep=true
for ep in "${entry_points[@]+"${entry_points[@]}"}"; do
    if [[ "$first_ep" == "true" ]]; then
        first_ep=false
    else
        entry_points_json+=","
    fi
    entry_points_json+="\"$ep\""
done
entry_points_json+="]"

# --- Framework signals ---

framework_signals=()

if has_file "package.json"; then
    pkg_content=$(cat "$ROOT/package.json" 2>/dev/null || echo "{}")
    for fw in next react vue svelte express fastify nestjs nuxt astro remix; do
        if echo "$pkg_content" | grep -q "\"$fw\""; then
            framework_signals+=("$fw")
        fi
    done
fi

if has_file "pyproject.toml" || has_file "requirements.txt"; then
    py_deps=""
    [[ -f "$ROOT/pyproject.toml" ]] && py_deps+=$(cat "$ROOT/pyproject.toml" 2>/dev/null || true)
    [[ -f "$ROOT/requirements.txt" ]] && py_deps+=$(cat "$ROOT/requirements.txt" 2>/dev/null || true)
    for fw in django flask fastapi; do
        if echo "$py_deps" | grep -qi "$fw"; then
            framework_signals+=("$fw")
        fi
    done
fi

fw_json="["
first_fw=true
for fw in "${framework_signals[@]+"${framework_signals[@]}"}"; do
    if [[ "$first_fw" == "true" ]]; then
        first_fw=false
    else
        fw_json+=","
    fi
    fw_json+="\"$fw\""
done
fw_json+="]"

# --- Doc formats ---

doc_formats=()
for ext in md txt rst adoc docx pdf; do
    n=$(count_files_by_ext "$ext")
    if [[ "$n" -gt 0 ]]; then
        doc_formats+=(".$ext")
    fi
done

df_json="["
first_df=true
for df in "${doc_formats[@]+"${doc_formats[@]}"}"; do
    if [[ "$first_df" == "true" ]]; then
        first_df=false
    else
        df_json+=","
    fi
    df_json+="\"$df\""
done
df_json+="]"

# --- Output JSON ---

# Use jq if available for clean serialization; otherwise printf
if command -v jq > /dev/null 2>&1; then
    jq -n \
        --arg ct "$CONTENT_TYPE" \
        --arg rp "$ROOT" \
        --argjson langs "$languages_json" \
        --argjson fc_total "$total_count" \
        --argjson fc_source "$source_count" \
        --argjson fc_docs "$doc_count" \
        --argjson fc_config "$config_count" \
        --argjson eps "$entry_points_json" \
        --argjson fw "$fw_json" \
        --argjson df "$df_json" \
        '{
            content_type: $ct,
            root_path: $rp,
            languages: $langs,
            file_counts: {
                total: $fc_total,
                source: $fc_source,
                docs: $fc_docs,
                config: $fc_config
            },
            entry_points: $eps,
            framework_signals: $fw,
            doc_formats: $df
        }'
else
    # printf fallback — no jq dependency
    printf '{"content_type":"%s","root_path":"%s","languages":%s,"file_counts":{"total":%s,"source":%s,"docs":%s,"config":%s},"entry_points":%s,"framework_signals":%s,"doc_formats":%s}\n' \
        "$CONTENT_TYPE" \
        "$ROOT" \
        "$languages_json" \
        "$total_count" \
        "$source_count" \
        "$doc_count" \
        "$config_count" \
        "$entry_points_json" \
        "$fw_json" \
        "$df_json"
fi

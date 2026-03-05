#!/usr/bin/env bash
# scripts/check-deps.sh — Dependency checker for Claude-Ctrl
#
# Verifies all required and optional system dependencies before first use.
# Run after cloning: bash scripts/check-deps.sh
#
# Exit codes:
#   0 — All required dependencies present
#   1 — One or more required dependencies missing
#
# @decision DEC-DEPS-CHECK-001
# @title Dependency checker mirrors hook detection patterns
# @status accepted
# @rationale SHA and lock tool detection mirrors hooks/log.sh and hooks/core-lib.sh
#   exactly so users get accurate results matching runtime hook behavior.

set -euo pipefail

# ─── Color helpers ───────────────────────────────────────────────────────────

# Check if terminal supports color
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    GREEN=$(tput setaf 2)
    RED=$(tput setaf 1)
    YELLOW=$(tput setaf 3)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    GREEN="" RED="" YELLOW="" BOLD="" RESET=""
fi

_pass() { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
_fail() { printf "  ${RED}✗${RESET} %s\n" "$1"; }
_info() { printf "  ${YELLOW}○${RESET} %s\n" "$1"; }
_head() { printf "\n${BOLD}%s${RESET}\n" "$1"; }

FAILED=0

# ─── Required: bash version ──────────────────────────────────────────────────

_head "Required dependencies"

_bash_version=$(bash --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
_bash_major=${_bash_version%%.*}
_bash_minor=${_bash_version#*.}
_bash_minor=${_bash_minor%%.*}

if [[ -z "$_bash_version" ]]; then
    _fail "bash — not found"
    FAILED=1
elif [[ "$_bash_major" -gt 3 ]] || { [[ "$_bash_major" -eq 3 ]] && [[ "$_bash_minor" -ge 2 ]]; }; then
    _pass "bash ${_bash_version} (>= 3.2 required)"
else
    _fail "bash ${_bash_version} — version 3.2+ required"
    FAILED=1
fi

# ─── Required: git version ───────────────────────────────────────────────────

_git_version=$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
_git_major=${_git_version%%.*}
_git_minor=${_git_version#*.}
_git_minor=${_git_minor%%.*}

if [[ -z "$_git_version" ]]; then
    _fail "git — not found"
    FAILED=1
elif [[ "$_git_major" -gt 2 ]] || { [[ "$_git_major" -eq 2 ]] && [[ "$_git_minor" -ge 20 ]]; }; then
    _pass "git ${_git_version} (>= 2.20 required)"
else
    _fail "git ${_git_version} — version 2.20+ required"
    FAILED=1
fi

# ─── Required: jq ────────────────────────────────────────────────────────────

if command -v jq >/dev/null 2>&1; then
    _jq_version=$(jq --version 2>/dev/null || echo "unknown")
    _pass "jq ${_jq_version}"
else
    _fail "jq — not found (install: brew install jq / apt-get install jq)"
    FAILED=1
fi

# ─── Required: POSIX utilities ───────────────────────────────────────────────

for _util in sed awk grep sort; do
    if command -v "$_util" >/dev/null 2>&1; then
        _pass "${_util}"
    else
        _fail "${_util} — not found"
        FAILED=1
    fi
done

# ─── Required: SHA-256 tool (mirrors hooks/log.sh detection) ─────────────────

# Mirrors the exact detection order from hooks/log.sh:
#   if command -v shasum; then _SHA256_CMD="shasum -a 256"
#   elif command -v sha256sum; then _SHA256_CMD="sha256sum"
if command -v shasum >/dev/null 2>&1; then
    _pass "shasum (SHA-256 via 'shasum -a 256')"
elif command -v sha256sum >/dev/null 2>&1; then
    _pass "sha256sum (SHA-256 via 'sha256sum')"
else
    _fail "sha256sum / shasum — neither found; project state hashing will degrade"
    FAILED=1
fi

# ─── Required: file locking tool (mirrors hooks/core-lib.sh detection) ───────

# Mirrors the exact detection from hooks/core-lib.sh _lock_fd():
#   case "$(uname -s)" in
#       Darwin) _LOCK_CMD="lockf"  ;;
#       Linux)  _LOCK_CMD="flock"  ;;
_platform=$(uname -s)
case "$_platform" in
    Darwin)
        if command -v lockf >/dev/null 2>&1; then
            _pass "lockf (macOS native, atomic state file operations)"
        else
            _fail "lockf — not found on macOS (should be in /usr/bin/lockf)"
            FAILED=1
        fi
        ;;
    Linux)
        if command -v flock >/dev/null 2>&1; then
            _pass "flock (Linux native, atomic state file operations)"
        else
            _fail "flock — not found on Linux (install: util-linux package)"
            FAILED=1
        fi
        ;;
    *)
        _fail "Unknown platform '${_platform}' — cannot verify lock tool"
        FAILED=1
        ;;
esac

# ─── Optional dependencies ───────────────────────────────────────────────────

_head "Optional dependencies"

if command -v gh >/dev/null 2>&1; then
    _pass "gh CLI — /backlog command and issue tracking available"
else
    _info "gh CLI — not found (optional: enables /backlog command and issue tracking)"
fi

if command -v terminal-notifier >/dev/null 2>&1; then
    _pass "terminal-notifier — macOS desktop notifications available"
else
    _info "terminal-notifier — not found (optional: macOS desktop notifications; brew install terminal-notifier)"
fi

if command -v shellcheck >/dev/null 2>&1; then
    _pass "shellcheck — hook linting available"
else
    _info "shellcheck — not found (optional: hook development and CI linting; brew install shellcheck)"
fi

# API keys checked via environment variables
_api_keys_found=0
for _key in OPENAI_API_KEY PERPLEXITY_API_KEY GEMINI_API_KEY; do
    if [[ -n "${!_key:-}" ]]; then
        _api_keys_found=$(( _api_keys_found + 1 ))
    fi
done
if [[ "$_api_keys_found" -gt 0 ]]; then
    _pass "${_api_keys_found}/3 research API keys set (deep-research skill)"
else
    _info "No research API keys set (optional: OPENAI_API_KEY, PERPLEXITY_API_KEY, GEMINI_API_KEY for deep-research)"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

printf "\n"
if [[ "$FAILED" -eq 0 ]]; then
    printf "${GREEN}${BOLD}All required dependencies present. Claude-Ctrl is ready to use.${RESET}\n\n"
    exit 0
else
    printf "${RED}${BOLD}One or more required dependencies missing. See above for install instructions.${RESET}\n\n"
    exit 1
fi

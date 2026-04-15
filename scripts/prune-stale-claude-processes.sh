#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/prune-stale-claude-processes.sh [--kill] [--hard] [--protect-session NAME]

Preview or kill stale Claude-related process trees while protecting tmux-owned
descendants of the protected sessions.

Defaults:
  protected sessions: 36, overnight-braid-v2-stable
  mode: preview only

Flags:
  --kill                 send SIGTERM to candidate pids
  --hard                 with --kill, send SIGKILL instead
  --protect-session NAME add another tmux session to protect
  -h, --help             show help

Reports are written under:
  ~/traces/headless-claude-prune-<timestamp>/

This script never deletes transcript files.
EOF
}

MODE="preview"
HARD=0
declare -a PROTECTED_SESSIONS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kill)
      MODE="kill"
      shift
      ;;
    --hard)
      HARD=1
      shift
      ;;
    --protect-session)
      [[ $# -ge 2 ]] || { echo "--protect-session requires a value" >&2; exit 1; }
      PROTECTED_SESSIONS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ${#PROTECTED_SESSIONS[@]} -eq 0 ]]; then
  PROTECTED_SESSIONS=(36 overnight-braid-v2-stable)
fi

STAMP="$(date +%Y%m%dT%H%M%S)"
REPORT_DIR="${HOME}/traces/headless-claude-prune-${STAMP}"
KEEP_ROOTS="${REPORT_DIR}/keep-roots.txt"
KEEP_PIDS="${REPORT_DIR}/keep-pids.txt"
CANDIDATES="${REPORT_DIR}/candidates.txt"
KILLED="${REPORT_DIR}/killed.txt"

mkdir -p "$REPORT_DIR"

for session in "${PROTECTED_SESSIONS[@]}"; do
  tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null || true
done | awk 'NF && !seen[$1]++' > "$KEEP_ROOTS"

if [[ ! -s "$KEEP_ROOTS" ]]; then
  echo "No protected tmux pane roots found." >&2
  echo "Looked for sessions: ${PROTECTED_SESSIONS[*]}" >&2
  exit 1
fi

cp "$KEEP_ROOTS" "$KEEP_PIDS"

while :; do
  CHILDREN_TMP="${REPORT_DIR}/children.txt"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    pgrep -P "$pid" 2>/dev/null || true
  done < "$KEEP_PIDS" | awk 'NF && !seen[$1]++' > "$CHILDREN_TMP"

  cat "$KEEP_PIDS" "$CHILDREN_TMP" | awk 'NF && !seen[$1]++' | sort -n > "${KEEP_PIDS}.new"
  if cmp -s "$KEEP_PIDS" "${KEEP_PIDS}.new"; then
    rm -f "${KEEP_PIDS}.new" "$CHILDREN_TMP"
    break
  fi
  mv "${KEEP_PIDS}.new" "$KEEP_PIDS"
  rm -f "$CHILDREN_TMP"
done

ps -axo pid=,ppid=,etime=,rss=,command= | \
awk '
NR == FNR {
  keep[$1] = 1
  next
}
{
  pid = $1
  cmd = $0
  if (keep[pid]) next
  if (cmd !~ /(claude|2\.1\.[0-9]+|node|bash)/) next

  stale = 0
  if (cmd ~ /\/private\/tmp\/claudex-main-workspace/) stale = 1
  else if (cmd ~ /\/private\/tmp\/claudex-braid-v2-workspace/) stale = 1
  else if (cmd ~ /\/Users\/turla\/Code\/braid/) stale = 1
  else if (cmd ~ /\/Users\/turla\/Code\/ConfigRefactor\/claude-ctrl-hardFork/ &&
           cmd !~ /\/\.worktrees\/claudex-braid-v2-live-checkpoint/) stale = 1

  if (stale) print
}
' "$KEEP_PIDS" - > "$CANDIDATES"

echo "report_dir=$REPORT_DIR"
echo "protected_sessions=${PROTECTED_SESSIONS[*]}"
echo "protected_roots=$(wc -l < "$KEEP_ROOTS" | tr -d ' ')"
echo "protected_descendants=$(wc -l < "$KEEP_PIDS" | tr -d ' ')"
echo "candidate_count=$(wc -l < "$CANDIDATES" | tr -d ' ')"

if [[ ! -s "$CANDIDATES" ]]; then
  echo "No stale candidates matched the current rules."
  exit 0
fi

sed -n '1,80p' "$CANDIDATES"

if [[ "$MODE" != "kill" ]]; then
  echo
  echo "Preview only. Re-run with --kill to terminate these candidates."
  exit 0
fi

awk '{print $1}' "$CANDIDATES" > "${REPORT_DIR}/candidate-pids.txt"

if [[ "$HARD" -eq 1 ]]; then
  xargs kill -9 < "${REPORT_DIR}/candidate-pids.txt"
else
  xargs kill < "${REPORT_DIR}/candidate-pids.txt"
fi

cp "${REPORT_DIR}/candidate-pids.txt" "$KILLED"
echo
echo "Killed $(wc -l < "$KILLED" | tr -d ' ') candidate pids."
echo "Killed pid list: $KILLED"

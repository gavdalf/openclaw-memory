#!/usr/bin/env bash
# watcher.sh — Reactive observer trigger via inotify (Linux) or fswatch (macOS)
# Watches session JSONL files. After LINE_THRESHOLD new writes, triggers observer.
#
# Environment variables:
#   OPENCLAW_DIR      — OpenClaw data directory
#   WORKSPACE_DIR     — Agent workspace
#   LINE_THRESHOLD    — Lines before trigger (default: 40)
#   COOLDOWN_SECS     — Seconds between triggers (default: 300)

set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/clawd}"
SESSIONS_DIR="${OPENCLAW_DIR}/agents/main/sessions"
SESSIONS_INDEX="${SESSIONS_DIR}/sessions.json"
MARKER_FILE="/tmp/observer-watcher-lastrun"
COOLDOWN_SECS="${COOLDOWN_SECS:-300}"
LINE_THRESHOLD="${LINE_THRESHOLD:-40}"
LOG="${WORKSPACE_DIR}/logs/observer-watcher.log"
PIDFILE="/tmp/observer-watcher.pid"
ACCUMULATED_LINES=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# PID management
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Watcher already running (PID $OLD_PID). Exiting."
    exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; log "Watcher stopped (PID $$)"; exit 0' EXIT INT TERM

# Get main session IDs (not subagent/cron/topic)
get_main_session_ids() {
  jq -r 'to_entries[] | select(.key | test("subagent|cron|topic") | not) | .value.sessionId' "$SESSIONS_INDEX" 2>/dev/null | sort -u
}

is_main_session() {
  local session_id="${1%.jsonl}"
  if [ -z "${MAIN_IDS:-}" ] || [ $(( $(date +%s) - ${CACHE_TIME:-0} )) -gt 60 ]; then
    MAIN_IDS=$(get_main_session_ids)
    CACHE_TIME=$(date +%s)
  fi
  echo "$MAIN_IDS" | grep -qF "$session_id"
}

in_cooldown() {
  [ -f "$MARKER_FILE" ] || return 1
  local last_run=$(stat -c %Y "$MARKER_FILE" 2>/dev/null || stat -f %m "$MARKER_FILE" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - last_run )) -lt "$COOLDOWN_SECS" ]
}

trigger_observer() {
  if in_cooldown; then
    log "Cooldown active (${COOLDOWN_SECS}s). Skipping trigger. Lines accumulated: $ACCUMULATED_LINES"
    return
  fi
  log "TRIGGER: $ACCUMULATED_LINES lines accumulated. Firing observer."
  touch "$MARKER_FILE"
  ACCUMULATED_LINES=0
  "${WORKSPACE_DIR}/scripts/observer.sh" >> "$LOG" 2>&1 &
  log "Observer started (PID $!)"
}

check_cron_ran() {
  if [ -f "$MARKER_FILE" ]; then
    local mt=$(stat -c %Y "$MARKER_FILE" 2>/dev/null || stat -f %m "$MARKER_FILE" 2>/dev/null || echo 0)
    if [ "${LAST_MARKER_TIME:-0}" != "$mt" ] && [ "${LAST_MARKER_TIME:-0}" != "0" ]; then
      log "External observer run detected. Resetting line counter from $ACCUMULATED_LINES to 0."
      ACCUMULATED_LINES=0
    fi
    LAST_MARKER_TIME="$mt"
  fi
}

log "Watcher started (PID $$). Threshold: ${LINE_THRESHOLD} lines, Cooldown: ${COOLDOWN_SECS}s"

MAIN_IDS=$(get_main_session_ids)
CACHE_TIME=$(date +%s)
log "Tracking $(echo "$MAIN_IDS" | wc -l) main session files"

# Platform detection: inotifywait (Linux) vs fswatch (macOS)
if command -v inotifywait &>/dev/null; then
  inotifywait -m -e modify --format '%f' "$SESSIONS_DIR" 2>/dev/null | while read -r FILENAME; do
    [[ "$FILENAME" == *.jsonl ]] || continue
    is_main_session "$FILENAME" || continue
    ACCUMULATED_LINES=$(( ACCUMULATED_LINES + 1 ))
    check_cron_ran
    [ "$ACCUMULATED_LINES" -ge "$LINE_THRESHOLD" ] && trigger_observer
  done
elif command -v fswatch &>/dev/null; then
  fswatch -0 "$SESSIONS_DIR" 2>/dev/null | while IFS= read -r -d '' filepath; do
    FILENAME=$(basename "$filepath")
    [[ "$FILENAME" == *.jsonl ]] || continue
    is_main_session "$FILENAME" || continue
    ACCUMULATED_LINES=$(( ACCUMULATED_LINES + 1 ))
    check_cron_ran
    [ "$ACCUMULATED_LINES" -ge "$LINE_THRESHOLD" ] && trigger_observer
  done
else
  log "ERROR: Neither inotifywait nor fswatch found. Install inotify-tools (Linux) or fswatch (macOS)."
  exit 1
fi

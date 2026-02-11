#!/usr/bin/env bash
# observer.sh — Extracts durable facts from OpenClaw session transcripts
# Runs on cron (every 15 min) and via memoryFlush pre-compaction hook
#
# Usage:
#   ./observer.sh              # Normal mode (lookback = LOOKBACK_MIN)
#   ./observer.sh --flush      # Pre-compaction mode (2hr lookback, skip dedup)
#
# Environment variables (set in .env or export):
#   OPENCLAW_DIR      — OpenClaw data directory (default: ~/.openclaw)
#   WORKSPACE_DIR     — Your agent workspace (default: ~/clawd)
#   OPENROUTER_API_KEY — API key for OpenRouter (or any OpenAI-compatible API)
#   OBSERVER_MODEL    — Model to use (default: google/gemini-2.0-flash-001)
#   OBSERVER_API_URL  — API base URL (default: https://openrouter.ai/api/v1)
#   LOOKBACK_MIN      — Minutes to look back for changes (default: 20)

set -euo pipefail

# --- Configuration (override via env vars) ---
OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/clawd}"
SESSIONS_DIR="${OPENCLAW_DIR}/agents/main/sessions"
OBSERVATIONS_FILE="${WORKSPACE_DIR}/memory/observations.md"
PROMPTS_DIR="${WORKSPACE_DIR}/prompts"
LOG_DIR="${WORKSPACE_DIR}/logs"
MARKER_FILE="${WORKSPACE_DIR}/memory/.observer-last-run"
HASH_FILE="${WORKSPACE_DIR}/memory/.observer-last-hash"
LOCK_FILE="/tmp/observer-running.lock"

MODEL="${OBSERVER_MODEL:-google/gemini-2.0-flash-001}"
API_URL="${OBSERVER_API_URL:-https://openrouter.ai/api/v1/chat/completions}"
LOOKBACK="${LOOKBACK_MIN:-20}"

# --- Flush mode ---
FLUSH_MODE=false
if [ "${1:-}" = "--flush" ]; then
  FLUSH_MODE=true
  LOOKBACK=120  # 2 hours
fi

# --- Setup ---
mkdir -p "$LOG_DIR" "$(dirname "$OBSERVATIONS_FILE")" "$(dirname "$MARKER_FILE")"
LOG="${LOG_DIR}/observer.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# --- Lock ---
if [ -f "$LOCK_FILE" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0) ))
  if [ "$LOCK_AGE" -lt 120 ]; then
    log "Another observer is running (${LOCK_AGE}s old) — skipping"
    exit 0
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log "Observer agent starting$([ "$FLUSH_MODE" = true ] && echo ' (FLUSH MODE)')"

# --- Find recent transcripts ---
TRANSCRIPTS=""
while IFS= read -r f; do
  BASENAME=$(basename "$f" .jsonl)
  # Skip subagent/cron/topic sessions
  echo "$BASENAME" | grep -qE "(topic|subagent)" && continue
  TRANSCRIPTS+="$f"$'\n'
done < <(find "$SESSIONS_DIR" -name "*.jsonl" -mmin -${LOOKBACK} -type f 2>/dev/null | head -10)

if [ -z "$TRANSCRIPTS" ]; then
  log "No recent transcripts found"
  exit 0
fi

# --- Extract messages ---
TMPMSGS=$(mktemp)
trap 'rm -f "$LOCK_FILE" "$TMPMSGS"' EXIT

echo "$TRANSCRIPTS" | while IFS= read -r f; do
  [ -z "$f" ] && continue
  jq -r 'select(.message.role == "user" or .message.role == "assistant") |
    "\(.timestamp // .ts) [\(.message.role)]: \(.message.content | if type == "array" then map(select(.type == "text") | .text) | join(" ") elif type == "string" then . else "" end)"' "$f" 2>/dev/null
done | tail -150 >> "$TMPMSGS"

LINES=$(wc -l < "$TMPMSGS")
if [ "$LINES" -lt 3 ]; then
  log "Too few lines ($LINES) to observe"
  exit 0
fi

# --- Dedup check (skip in flush mode) ---
if [ "$FLUSH_MODE" = false ]; then
  HASH=$(md5sum "$TMPMSGS" | cut -d' ' -f1)
  if [ -f "$HASH_FILE" ] && [ "$(cat "$HASH_FILE")" = "$HASH" ]; then
    log "No new content (hash unchanged)"
    exit 0
  fi
  echo "$HASH" > "$HASH_FILE"
fi

log "Found $LINES lines to compress"

# --- Load system prompt ---
SYSTEM_PROMPT="You are an observation agent. Extract durable facts from conversation transcripts.
Output format: prioritised bullet points with emoji markers (🔴 high, 🟡 medium, 🟢 low).
Include timestamps. Focus on: decisions, preferences, commitments, financial info, project updates, family logistics.
Skip: casual chat, jokes, routine confirmations, tool call details.
Be concise. Plain text, no markdown headers."

if [ -f "${PROMPTS_DIR}/observer-system.txt" ]; then
  SYSTEM_PROMPT=$(cat "${PROMPTS_DIR}/observer-system.txt")
fi

# --- Call LLM ---
CONTENT=$(cat "$TMPMSGS")
PAYLOAD=$(jq -n --arg sys "$SYSTEM_PROMPT" --arg content "$CONTENT" '{
  model: env.MODEL,
  messages: [
    {role: "system", content: $sys},
    {role: "user", content: ("Extract observations from these messages:\n\n" + $content)}
  ],
  temperature: 0.3,
  max_tokens: 2000
}')

RESPONSE=$(curl -s -X POST "$API_URL" \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>/dev/null)

OBSERVATIONS=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

if [ -z "$OBSERVATIONS" ]; then
  log "ERROR: No observations returned from LLM"
  exit 1
fi

# --- Filter self-observations ---
OBSERVATIONS=$(echo "$OBSERVATIONS" | grep -v -i "observer\|reflector\|observation.*agent\|memory.*system.*running" || echo "$OBSERVATIONS")

# --- Append to observations file ---
if [ ! -f "$OBSERVATIONS_FILE" ]; then
  echo "# Observations Log" > "$OBSERVATIONS_FILE"
  echo "" >> "$OBSERVATIONS_FILE"
  echo "Auto-generated by Observer agent. Loaded at session startup for cross-session memory." >> "$OBSERVATIONS_FILE"
  echo "" >> "$OBSERVATIONS_FILE"
  echo "---" >> "$OBSERVATIONS_FILE"
  echo "" >> "$OBSERVATIONS_FILE"
fi

TODAY=$(date '+%Y-%m-%d')
if ! grep -q "^Date: $TODAY" "$OBSERVATIONS_FILE" 2>/dev/null; then
  echo "" >> "$OBSERVATIONS_FILE"
  echo "Date: $TODAY" >> "$OBSERVATIONS_FILE"
fi

echo "$OBSERVATIONS" >> "$OBSERVATIONS_FILE"

date +%s > "$MARKER_FILE"
touch /tmp/observer-watcher-lastrun 2>/dev/null || true

OBS_WORDS=$(wc -w < "$OBSERVATIONS_FILE")
log "Observations appended. Total: $OBS_WORDS words (~$((OBS_WORDS * 4 / 3)) tokens)"
echo "OBSERVATIONS_ADDED"

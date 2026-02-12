#!/bin/bash
# Session Recovery — checks if previous session was observed, captures if not
# Run at session startup as 5th layer of redundancy
# Works without git — uses session files and hash tracking

set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/clawd}"
SESSIONS_DIR="${OPENCLAW_DIR}/agents/main/sessions"
HASH_FILE="${WORKSPACE_DIR}/memory/.observer-last-hash"
RECOVERY_LOG="${WORKSPACE_DIR}/logs/session-recovery.log"

mkdir -p "${WORKSPACE_DIR}/logs"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$RECOVERY_LOG"
}

log "Session recovery check starting"

# Find the most recent session file (excluding current)
LAST_SESSION=$(ls -t "$SESSIONS_DIR"/*.jsonl 2>/dev/null | head -1 || true)

if [ -z "$LAST_SESSION" ]; then
  log "No session files found"
  exit 0
fi

# Calculate hash of last 50 lines (recent activity)
CURRENT_HASH=$(tail -50 "$LAST_SESSION" 2>/dev/null | md5sum | cut -d' ' -f1 || echo "")

if [ -z "$CURRENT_HASH" ]; then
  log "Could not hash session file"
  exit 0
fi

# Check if this session was already observed
if [ -f "$HASH_FILE" ]; then
  STORED_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")
  if [ "$CURRENT_HASH" = "$STORED_HASH" ]; then
    log "Last session already observed (hash match)"
    exit 0
  fi
fi

# Session changed but wasn't observed — run observer in recovery mode
log "Unobserved session detected: $(basename "$LAST_SESSION") (hash: ${CURRENT_HASH:0:8})"
log "Triggering emergency observer capture..."

# Run observer with extended lookback to capture what was missed
bash "${WORKSPACE_DIR}/scripts/observer.sh" --recover "$LAST_SESSION" 2>/dev/null || {
  # Fallback: direct capture
  log "Direct recovery capture..."
  CUTOFF_ISO=$(date -u -d "4 hours ago" '+%Y-%m-%dT%H:%M:%SZ')
  
  # Extract messages from the missed session
  RECENT_MESSAGES=$(jq -r --arg cutoff "$CUTOFF_ISO" '
    select(.timestamp != null and (.timestamp > $cutoff)) |
    select(.message.role == "user" or .message.role == "assistant") |
    .message as $m |
    (if $m.role == "user" then "USER" else "ASSISTANT" end) as $who |
    (
      if ($m.content | type) == "array" then
        [$m.content[] | select(.type == "text") | .text] | join(" ")
      elif ($m.content | type) == "string" then
        $m.content
      else
        ""
      end
    ) as $text |
    select($text != "" and ($text | length) > 5) |
    select($text != "HEARTBEAT_OK" and $text != "NO_REPLY") |
    "[\($who)]: \($text[0:400])"
  ' "$LAST_SESSION" 2>/dev/null | head -100 || true)
  
  if [ -n "$RECENT_MESSAGES" ]; then
    # Append raw to observations with recovery marker
    echo "" >> "${WORKSPACE_DIR}/memory/observations.md"
    echo "<!-- Session Recovery Capture: $(date '+%Y-%m-%d %H:%M') -->" >> "${WORKSPACE_DIR}/memory/observations.md"
    echo "$RECENT_MESSAGES" >> "${WORKSPACE_DIR}/memory/observations.md"
    echo "$CURRENT_HASH" > "$HASH_FILE"
    log "Emergency capture complete ($(echo "$RECENT_MESSAGES" | wc -l) lines)"
  fi
}

log "Session recovery complete"

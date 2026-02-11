# Architecture

## Overview

The memory system operates as an external layer on top of OpenClaw's native compaction. It writes to plain Markdown files on disk that survive compaction entirely.

## Components

### Observer Agent (`scripts/observer.sh`)
- Reads recent session JSONL transcripts
- Extracts durable facts via LLM (Gemini Flash recommended)
- Appends to `memory/observations.md` with priority markers
- Runs every 15 minutes via cron + reactively via watcher
- Supports `--flush` mode for pre-compaction emergency capture

### Reflector Agent (`scripts/reflector.sh`)
- Consolidates observations when they exceed ~8000 words
- Merges duplicates, removes outdated entries, compresses low-priority items
- Backs up before reflecting (safety net)
- Sanity check: rejects output if larger than input

### Reactive Watcher (`scripts/watcher.sh`)
- Uses inotify (Linux) or fswatch (macOS) to watch session files
- Triggers observer after 40 new JSONL writes (configurable)
- 5-minute cooldown between triggers
- Filters to main sessions only (skips subagent/cron sessions)

### Pre-Compaction Hook
- OpenClaw's `memoryFlush` config fires a silent agent turn before compaction
- We configure it to run the observer in `--flush` mode first
- 2-hour lookback, skip dedup — maximum capture before context is lost

## Data Flow

```
User conversations → Session JSONL files (raw, real-time)
    ↓
Observer (every 15 min + reactive + pre-compaction)
    ↓
observations.md (prioritised facts, ~5000 tokens)
    ↓
Reflector (when >8000 words, consolidate)
    ↓
Session startup loads: observations.md + favorites.md + daily memory
```

## Why External Files?

Compaction only affects the in-memory conversation transcript. Our files live on disk, completely independent. This means:

1. Compaction can't destroy our saved facts
2. Multiple sessions can share the same memory files
3. The files are human-readable and debuggable
4. No changes to OpenClaw core required

# OpenClaw Memory — Quad-Redundant Memory Protection

> Your AI has the same attention problem you do — and we fixed it the same way your brain does.

A drop-in memory system for [OpenClaw](https://openclaw.ai) agents that eliminates post-compaction amnesia through continuous observation, reflection, and reactive triggers.

## The Problem

OpenClaw's context compaction is lossy by design. It takes 200k tokens of conversation and crushes it to ~10-20k tokens of summary. Specifics get lost: exact numbers, subtle decisions, the reasoning behind choices.

## The Solution

Four layers of protection that work **with** (not against) native compaction:

1. ⏰ **Observer Cron** (every 15 min) — Continuously extracts durable facts from session transcripts
2. 🎯 **Reactive Watcher** (inotify/fswatch) — Fires within seconds during heavy conversations
3. 🛡️ **Pre-Compaction Hook** (memoryFlush) — Emergency capture right before compaction fires
4. 📝 **Session Startup** — Loads all saved memory at the start of every new session

**Cost:** ~$0.05/day using Gemini Flash via OpenRouter.
**Context overhead:** ~4.5% of window (saves 20-30% that would be wasted re-explaining).

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/gavdalf/openclaw-memory.git
cd openclaw-memory

# 2. Run the installer
./install.sh

# 3. Done — memory system is active
```

## Architecture

```
Session JSONL files (raw transcripts)
    ↓ (every 15 min + reactive triggers)
Observer Agent (compress via LLM → observations.md)
    ↓ (when observations > 8000 words)
Reflector Agent (consolidate → compressed observations.md)
    ↓ (session startup)
Agent loads: observations.md + favorites.md + daily memory
```

See [docs/architecture.md](docs/architecture.md) for the full breakdown.

## Requirements

- OpenClaw (any recent version)
- bash, jq, curl
- An LLM API key (OpenRouter recommended — Gemini Flash is ~$0.001/run)
- `inotify-tools` (Linux) or `fswatch` (macOS) for the reactive watcher

## Inspired By

- [Mastra Observational Memory](https://mastra.ai) (94.87% on LongMemEval benchmark)
- Stanford Generative Agents (Park et al., 2023)
- MemGPT/Letta tiered memory architecture
- Cognitive science: hippocampal replay during sleep transitions

## License

MIT

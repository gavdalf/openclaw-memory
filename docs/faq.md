# Frequently Asked Questions

## "OpenClaw already fixed post-compaction amnesia. Why do we need this?"

OpenClaw's fix (#12283) repaired a bug where the compaction summary was malformed. That's important — but compaction is still lossy by design. It takes 200k tokens and crushes them to ~10-20k. Specifics get lost.

Our system pre-empts compaction. Before it fires, the observer has already saved every durable fact to permanent files. OpenClaw's fix makes the exam notes legible. Our system is the friend who took notes during the entire lecture.

## "Does this conflict with OpenClaw's native compaction?"

No — everything is completely complementary. Our files live outside the conversation context. Compaction never touches them. The flow works together: observer saves facts → compaction summarises conversation → new session loads both the summary AND our files.

## "Aren't we inflating the context by loading saved memory?"

Yes, by about 4.5% (~9,000 tokens out of 200k). But without the system, you'd spend 20-30% of context re-explaining things after compaction. It's a net win. The Reflector prevents unbounded growth by consolidating when observations exceed ~8,000 words.

## "What LLM should I use for the observer?"

Any cheap, fast model works. We recommend Gemini Flash via OpenRouter (~$0.001 per run, ~$0.05/day). The observer doesn't need deep reasoning — just fact extraction.

## "Does this work on macOS?"

Yes. The watcher uses `fswatch` instead of `inotifywait`. Everything else is standard bash/jq/curl.

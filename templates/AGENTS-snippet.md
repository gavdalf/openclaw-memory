## Session Start — Mandatory Context Load (add to your AGENTS.md)

On EVERY new session (including /new, /reset, greeting messages), BEFORE answering:
1. `memory/observations.md` — always load (auto-generated cross-session memory)
2. `memory/favorites.md` — always load (critical facts, urgent items)
3. `memory/YYYY-MM-DD.md` for TODAY — always read directly
4. `memory/YYYY-MM-DD.md` for YESTERDAY — always read directly
5. THEN run `memory_search` for additional context

**Do not rely solely on semantic search** — it may rank today's updates low.

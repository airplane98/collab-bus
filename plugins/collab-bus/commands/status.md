---
description: Show the collab-bus inbox state and the peer agent's herdr state/output
---

Report the current collab-bus state. Peer from `$1` (default `codex`).

1. **Inbox**: list `collab/inbox/to/claude/`, `collab/inbox/to/<peer>/`, and
   `collab/inbox/archive/`. Flag any `open` messages waiting on either side.
2. **Peer agent (herdr)**: it's agent-aware, so read state directly — no pane-scraping guess:
   - `herdr agent list` — confirm the peer is detected; note its `pane_id` and `agent_status`.
   - `herdr agent get <pane_id>` — full state (idle/working/blocked/done/unknown).
   - `herdr agent read <pane_id> --lines 12` — recent terminal output, if you need context.
   If `herdr status` shows the server isn't running, or the peer isn't listed, say so and
   point to `/collab-bus:init`.
3. Summarize in one compact table: pending messages (each side), last archived exchange,
   and the peer's live `agent_status` (working / idle / blocked / done).

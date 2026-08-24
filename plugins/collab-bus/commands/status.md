---
description: Show the collab-bus inbox state and the peer agent's herdr state/output
---

Report the current collab-bus state. Peer from `$1` (default `codex`).

1. **Inbox**: list `collab/inbox/to/claude/`, `collab/inbox/to/<peer>/`, and
   `collab/inbox/archive/`. **Show only messages whose `pair` matches your own
   `tab_id` by default** — in a workspace with two pairs the others' open items are
   not your queue, and reporting them as pending is how an agent ends up processing
   another pair's work. Mention the count of other-pair messages in one line, and
   support an explicit `--all` when the human really wants everything.
2. **Peer agent (herdr)**: resolve *your* peer, not just "a peer of that kind":
   `herdr pane current` gives your own `tab_id` live (fallback: match your session
   id against `agent_session.value` in `herdr agent list`), then require **exactly
   one** agent of the peer kind in that tab; if there are zero or several, say so
   and stop rather than reporting somebody else's agent.
   `--all` widens which *messages* are listed — it never widens peer targeting.
   - `herdr agent list` — confirm the peer is detected; note its `pane_id` and `agent_status`.
   - `herdr agent get <pane_id>` — full state (idle/working/blocked/done/unknown).
   - `herdr agent read <pane_id> --lines 12` — recent terminal output, if you need context.
   - If the peer is `working` and the human wants the outcome, offer
     `herdr agent wait <pane_id> --timeout <ms>` — it blocks until the turn settles
     without submitting anything, so there's no duplicate nudge.
   - If the peer is `blocked`, `herdr agent read <pane_id>` shows the approval UI
     it is stuck on; surface that to the human.
   If `herdr status` shows the server isn't running, or the peer isn't listed, say so and
   point to `/collab-bus:init`.
3. Summarize in one compact table: pending messages (each side), last archived exchange,
   and the peer's live `agent_status` (working / idle / blocked / done).

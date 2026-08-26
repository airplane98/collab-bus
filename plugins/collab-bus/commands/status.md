---
description: Show the collab-bus inbox state and the peer agent's herdr state/output
---

Report the current collab-bus state. Peer from `$1` (default `codex`).

1. **Vet the project runtime before reading through it.** Run from the project root:
   ```bash
   COLLAB_BUS_TRUSTED_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
   PROJECT_ROOT="$(pwd -P)"
   BIN=$("$COLLAB_BUS_TRUSTED_SCRIPTS/preflight.sh" --dir "$PROJECT_ROOT") || exit 1
   ```
   The installed plugin is the trust anchor; do not run the project's own preflight
   to decide whether project code is safe to execute.
2. **Inbox**: run `"$BIN/route.sh" list` for the messages addressed to you
   (add `--agent <id>` if this session is not bound), and list
   `collab/inbox/archive/` for history. **Report only your own as pending** — in a
   workspace with two pairs the others' open items are not your queue, and counting
   them is how an agent ends up processing another pair's work. Say in one line how
   many belong to someone else, and support an explicit `--all` when the human
   really wants everything — that is a *report* option of this command, and it is not
   `route.sh --include-closed`, which only widens the list to your own closed
   messages. Anything `route.sh` calls unrouted or unreadable belongs
   in the report too: those are messages nobody will pick up.
3. **Peer agent (herdr)**: resolve *your* peer, not just "a peer of that kind":
   `herdr pane current` gives your own `tab_id` live (fallback: match your session
   id against `agent_session.value` in `herdr agent list`), then require **exactly
   one** agent of the peer kind in that tab; if there are zero or several, say so
   and stop rather than reporting somebody else's agent.
   `--all` widens which *messages* are reported — it never widens peer targeting.
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
4. Summarize in one compact table: pending messages (each side), last archived exchange,
   and the peer's live `agent_status` (working / idle / blocked / done).

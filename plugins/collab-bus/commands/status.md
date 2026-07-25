---
description: Show the collab-bus inbox state and the peer's tmux pane
---

Report the current collab-bus state. Peer from `$1` (default `codex`).

1. **Inbox**: list `collab/inbox/to/claude/`, `collab/inbox/to/<peer>/`, and
   `collab/inbox/archive/`. Flag any `open` messages waiting on either side.
2. **Peer pane**: with `SOCK=${COLLAB_TMUX_SOCK:-/tmp/collab-bus.sock}` and
   `SESSION` = git-toplevel basename (`.`/`:`→`_`), show it's alive and what it's doing:
   ```
   tmux -S "$SOCK" list-panes -a -F '#{session_name}:#{window_name} [#{pane_current_command}]'
   tmux -S "$SOCK" capture-pane -p -t "$SESSION:<peer>" | tail -8
   ```
   If those tmux commands are blocked by a permission/safety classifier while plain
   `ls` works, say so and ask the human to eyeball the peer window directly.
3. Summarize in one compact table: pending messages (each side), last archived
   exchange, and whether the peer pane is running / idle / stuck with unsent input.

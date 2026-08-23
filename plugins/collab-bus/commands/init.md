---
description: Scaffold collab/ + PROTOCOL in the current project and wire the peer as a herdr agent
---

Set up the collab-bus in **this** project so Claude Code and a peer AI CLI can
collaborate over herdr. Peer name from `$1` (default `codex`).

1. **Check herdr.** `herdr status` must show `server: status: running`. If herdr is
   missing, tell the user to install it (https://herdr.dev) — collab-bus ≥0.2 needs it.

2. **Resolve names.**
   - `PEER` = `$1` or `codex`.
   - `PROJECT` = basename of the git toplevel (`git rev-parse --show-toplevel`), else cwd.

3. **Scaffold** (idempotent — don't clobber existing message files):
   ```
   collab/inbox/to/<PEER>/   collab/inbox/to/claude/   collab/inbox/archive/
   collab/reviews/           collab/tasks/
   ```
   Add a `.gitkeep` in each so the structure survives a clone.

4. **Wire the peer as a herdr agent.** Note its `pane_id` for *this session only* —
   do **not** bake it into PROTOCOL.md. With more than one pair in the workspace a
   stored pane_id points at somebody else's agent; the template therefore tells
   agents to resolve by `tab_id` every round.
   - Run `herdr agent list`. If the peer already shows up (detected kind matches PEER),
     use its `pane_id`.
   - Otherwise instruct the human: open a new herdr pane/tab (split the workspace) and
     run the peer CLI there in this project dir, e.g. `cd <project> && codex`. herdr
     auto-detects ~20 agent kinds (Codex, Claude Code, Copilot CLI, …). Then re-run
     `herdr agent list` and take the new `pane_id`.
   - Optional but recommended for a stable target: `herdr agent rename <pane_id> <PEER>`.

5. **Write `collab/PROTOCOL.md`** from `${CLAUDE_PLUGIN_ROOT}/templates/PROTOCOL.template.md`,
   substituting `{{PROJECT}}` and `{{PEER}}`. (`{{TARGET}}` is gone — coordinates are
   resolved dynamically, not stored.) Also vendor the allocator into the project so
   the peer CLI — which has no `CLAUDE_PLUGIN_ROOT` — can call it too:
   `mkdir -p collab/bin && cp "${CLAUDE_PLUGIN_ROOT}/scripts/next-id.sh" collab/bin/`
   and record the plugin version it came from in PROTOCOL.md.

6. **Write the onboarding message** via the allocator (not a hardcoded `0001`):
   `DEST=$(collab/bin/next-id.sh <PEER> onboarding <your-tab-id>)`, with
   `pair: <your tab_id>` in the frontmatter
   (frontmatter per PROTOCOL, `type: task`, `status: open`) instructing the peer to:
   read `collab/PROTOCOL.md` and any project `CLAUDE.md`/`AGENTS.md`; confirm its role
   as reviewer; then reply with `0002-onboarding-ack.md` to `collab/inbox/to/claude/`
   (its stack summary + whether it can run git/tests) and archive `0001`.

7. **Kick off the handshake** (only if the peer agent is already detected): knock it —
   `"${CLAUDE_PLUGIN_ROOT}/scripts/knock.sh" <PEER> "Handshake: process 0001-onboarding"` —
   which submits and waits for the peer's turn, then read `0002` and archive per PROTOCOL.
   If the peer isn't wired yet, tell the human the one step (run the peer in a herdr pane)
   and stop.

Keep output tight: confirm what was scaffolded and the peer's herdr target, then the
next action (either "peer wired, handshake done" or "run the peer in a herdr pane").

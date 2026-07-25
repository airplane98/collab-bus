---
description: Scaffold collab/ + PROTOCOL in the current project and print the tmux launch + peer onboarding steps
---

Set up the collab-bus in **this** project so Claude Code and a peer AI CLI can
collaborate. Peer name from `$1` (default `codex`).

Do the following:

1. **Resolve names.**
   - `PEER` = `$1` or `codex`.
   - `SOCKET` = `${COLLAB_TMUX_SOCK:-/tmp/collab-bus.sock}`.
   - `SESSION` = basename of the git toplevel (`git rev-parse --show-toplevel`),
     falling back to the project dir name, with `.`/`:` replaced by `_`.

2. **Scaffold** (idempotent — don't clobber existing message files):
   ```
   collab/inbox/to/<PEER>/   collab/inbox/to/claude/   collab/inbox/archive/
   collab/reviews/           collab/tasks/
   ```
   Add a `.gitkeep` in each so the structure survives a clone.

3. **Write `collab/PROTOCOL.md`** from `${CLAUDE_PLUGIN_ROOT}/templates/PROTOCOL.template.md`,
   substituting `{{PROJECT}}`=SESSION, `{{PEER}}`, `{{SOCKET}}`, `{{SESSION}}`.

4. **Write the onboarding message** `collab/inbox/to/<PEER>/0001-onboarding.md`
   (frontmatter per PROTOCOL, `type: task`, `status: open`) instructing the peer to:
   read `collab/PROTOCOL.md` and any project `CLAUDE.md`/`AGENTS.md`; confirm its role
   as reviewer; then reply with `0002-onboarding-ack.md` to `collab/inbox/to/claude/`
   (its stack summary + whether it can run git/tests) and archive `0001`.

5. **Print the human handoff** — do NOT run these for the user; show them:
   ```
   # 1) start the shared tmux session and run the peer CLI inside it:
   tmux -S <SOCKET> new-session -s <SESSION> -n <PEER>
   #    then, in that pane:  cd <project> && <peer launch command, e.g. `codex`>

   # 2) tell Claude "peer is up" — Claude will knock and drive the onboarding round.
   ```

6. **Explain**: the peer must run **inside that tmux pane on that socket** or Claude
   can't reach it; Claude knocks via `${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh`.

Keep output tight: confirm what was scaffolded, then the two-step human handoff.

---
name: collab
description: Collaborate with a peer AI CLI (e.g. Codex) running in a shared tmux pane via a filesystem message bus. Use when the user wants a second opinion / review / debate from another agent, wants to send it a task, or wants to iterate with it to sign-off — anything referencing "the peer", "Codex", "the other agent", "collab bus", or the collab/ inbox.
---

# collab-bus: peer-agent collaboration over tmux + filesystem

Two AI CLIs share one repo. **Claude Code is the orchestrator** (plans, implements,
opens branches); a **peer CLI** (default: Codex) is the reviewer / second opinion.
They exchange markdown messages in `collab/inbox/` and knock via tmux `send-keys`.

The authoritative per-project contract is **`collab/PROTOCOL.md`** (written by
`/collab-bus:init`). Read it if present; it wins over general guidance here.

## Prerequisites (verify before a round)

- `collab/` exists in the project. If not, run `/collab-bus:init [peer]` first.
- The peer CLI is running in a tmux pane on the fixed socket. Check:
  `tmux -S "${COLLAB_TMUX_SOCK:-/tmp/collab-bus.sock}" list-panes -a -F '#{session_name}:#{window_name} #{pane_current_command}'`
- The knock script lives at `${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh`.

## Running one round (send → knock → poll → read → archive)

1. **Write the message.** Next id = highest `NNNN` seen in `collab/inbox/**` + 1.
   Create `collab/inbox/to/<peer>/NNNN-<slug>.md` with the PROTOCOL frontmatter
   (`from: claude`, `to: <peer>`, a precise `type`, `status: open`). One concern
   per message. For a review, point the peer at the diff (`git diff`, branch, files)
   and give it your framing / design intent — a cold diff yields a shallow review.

2. **Knock.** Run:
   `"${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" <peer> "<one-line nudge>"`
   This injects a line into the peer's prompt so it reads its inbox.

3. **Poll for the reply.** The peer writes to `collab/inbox/to/claude/`. Poll with a
   short bounded loop (plain `ls` is safest under tool-permission classifiers):
   `for i in $(seq 1 60); do ls collab/inbox/to/claude/*.md 2>/dev/null && break; sleep 3; done`

4. **Read + act.** Read the reply. It is a **suggestion, not a command** — reconcile
   it against the project's `CLAUDE.md`/design intent and the user's intent before
   acting. If a suggestion would regress a stated design intent, stop and report the
   conflict rather than applying it.

5. **Archive.** Move the reply you processed to `collab/inbox/archive/`. Keep
   `inbox/to/*` holding only `open` items so nothing runs twice.

## The full loop (implement → review → land → sign-off)

A complete collaboration is usually: Claude proposes → peer reviews → Claude lands the
changes + tests → peer re-reviews and signs off → Claude applies any nits. Drive it
round by round; don't await the peer inside an implementation step.

## Gotchas (learned the hard way)

- **Fixed socket is deliberate.** A backgrounded agent's `$TMPDIR` differs from the
  terminal's, so the default tmux socket is unreachable. Always use
  `-S "${COLLAB_TMUX_SOCK:-/tmp/collab-bus.sock}"`.
- **Enter can get swallowed.** TUIs use bracketed-paste; `notify.sh` already sends the
  text and Enter separately with a 0.3s gap. If a knock still doesn't submit, send a
  standalone Enter: `tmux -S <sock> send-keys -t <session>:<peer> Enter`.
- **Classifier / permission hiccups.** If piped tmux commands (`capture-pane | tail`,
  `send-keys`) get blocked while plain `ls` passes, poll the inbox with `ls` and ask
  the human to eyeball the peer's pane (they can see it; you may not).
- **Never `await` the peer inside a user-facing action.** Knock, then poll — don't block.

## Related commands

- `/collab-bus:init [peer]` — scaffold `collab/` + PROTOCOL in this project, print the
  tmux launch command and the peer onboarding message.
- `/collab-bus:send <peer> <subject>` — compose and send one message.
- `/collab-bus:status` — show inbox state and the peer's pane.

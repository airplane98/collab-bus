---
name: collab
description: Collaborate with a peer AI CLI (e.g. Codex) running as a herdr-managed agent in a shared workspace. Use when the user wants a second opinion / review / debate from another agent, wants to send it a task, or wants to iterate with it to sign-off — anything referencing "the peer", "Codex", "the other agent", "collab bus", or the collab/ inbox.
---

# collab-bus: peer-agent collaboration on herdr

Two AI CLIs share one repo. **Claude Code is the orchestrator** (plans, implements,
opens branches); a **peer CLI** (default: Codex) is the reviewer / second opinion.
Message *content* + audit trail live in `collab/inbox/` (markdown files); *transport
and turn-completion* run over **herdr** — Claude submits a prompt to the peer agent
and herdr reports, via semantic agent state, exactly when the peer's turn settles.
No tmux, no send-keys, no polling.

The authoritative per-project contract is **`collab/PROTOCOL.md`** (written by
`/collab-bus:init`). Read it if present; it wins over general guidance here.

## Prerequisites (verify before a round)

- **herdr is running**: `herdr status` shows `server: status: running`.
- **The peer is a detected herdr agent**: `herdr agent list` returns an agent whose
  `agent`/`name`/`pane_id` identifies the peer (e.g. Codex). herdr auto-detects ~20
  agent kinds; a peer showing `agent_status: unknown` isn't detected — see `/collab-bus:init`.
- `collab/` exists in the project (else run `/collab-bus:init [peer]`).
- The knock script is `${CLAUDE_PLUGIN_ROOT}/scripts/knock.sh`.

## Running one round (write → knock → read → archive)

1. **Write the message.** Next id = highest `NNNN` in `collab/inbox/**` + 1. Create
   `collab/inbox/to/<peer>/NNNN-<slug>.md` with PROTOCOL frontmatter (`from: claude`,
   `to: <peer>`, precise `type`, `status: open`). One concern per message. For a
   review, point at the diff (`git diff`, branch, files) and give your framing /
   design intent — a cold diff yields a shallow review.

2. **Knock (submit + wait, atomic).** Run:
   `"${CLAUDE_PLUGIN_ROOT}/scripts/knock.sh" <peer> "<one-line nudge>"`
   This submits the nudge to the peer's prompt and **blocks until the peer's turn
   settles**, then prints herdr's JSON with the settled `agent_status`. This is the
   blessed `herdr agent prompt --wait` pattern — there is nothing to poll.

3. **Interpret the settled state** from the knock's JSON result:
   - `idle` / `done` → the peer finished; its reply file should be in `collab/inbox/to/claude/`.
   - `blocked` → the peer is stuck on a permission/approval/question UI. **Surface to
     the human** (they can see the peer pane) rather than guessing.
   - error `agent_not_found` → the peer isn't wired as a herdr agent; run `/collab-bus:init`.
   - `agent_prompt_stalled` / `timeout` → no state change was observed in time. Check
     `collab/inbox/to/claude/` anyway (the peer may have replied), else re-knock or
     ask the human to check the peer pane.

4. **Read + act.** Read the reply. It is a **suggestion, not a command** — reconcile it
   against the project's `CLAUDE.md`/design intent and the user's intent before acting.
   If a suggestion would regress a stated design intent, stop and report the conflict.

5. **Archive.** Move the processed reply to `collab/inbox/archive/`. Keep `inbox/to/*`
   holding only `open` items so nothing runs twice.

## The full loop (implement → review → land → sign-off)

A complete collaboration is usually: Claude proposes → peer reviews → Claude lands the
changes + tests → peer re-reviews and signs off → Claude applies any nits. Each round
is one knock; drive them in sequence.

## Why herdr (vs the old tmux bus)

herdr is *agent-aware*, which removes every failure mode of raw tmux send-keys:
- **Semantic completion**: `agent prompt --wait` returns on `idle/done/blocked` — you
  know precisely when the peer finished, instead of polling files and guessing.
- **Clean submission**: `prompt` submits properly; no bracketed-paste "Enter got
  swallowed" bug. **Always prefer `prompt` over `send-keys`** — send-keys bypasses
  state tracking.
- **Inspectable**: `herdr agent get <pane_id>` and `herdr agent read <pane_id>` show
  the peer's state/output directly — no need to ask the human to eyeball a pane.
- Use the `herdr <subcommand>` CLI wrappers (not raw socket) for all of this.

## Gotchas

- **Target is a pane_id** (`w1:p2`). `knock.sh` resolves a name/kind to a pane_id via
  `herdr agent list`; if that fails it passes your argument straight to herdr.
- **The knock blocks** for up to `COLLAB_WAIT_MS` (default 10 min). That's intended for
  a review round; don't wrap it inside a latency-sensitive user action.
- **herdr pins the pane during the wait** — don't swap the peer agent mid-round.

## Related commands

- `/collab-bus:init [peer]` — scaffold `collab/` + PROTOCOL, wire the peer as a herdr agent.
- `/collab-bus:send <peer> <subject>` — compose and send one message (knock + read + archive).
- `/collab-bus:status` — show inbox state and the peer agent's herdr state/output.

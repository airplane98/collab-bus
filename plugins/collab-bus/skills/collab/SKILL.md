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
`/collab-bus:init`). Read it if present; it wins over general guidance here —
**with one carve-out**: the multi-pair safety rules below (atomic id allocation,
`pair` routing, resolve-the-peer-every-round) **supersede any PROTOCOL.md that
predates them**. A file generated before v0.3.0 still says "next id = highest + 1"
and pins a static `peer agent target: <pane_id>`; both are known to break once a
second Claude+peer pair opens in the same repo, so do not follow them. Tell the
human their PROTOCOL.md is stale and offer to patch those two sections.

## Prerequisites (verify before a round)

- **herdr is running**: `herdr status` shows `server: status: running`.
- **The peer is a detected herdr agent**: `herdr agent list` returns an agent whose
  `agent`/`name`/`pane_id` identifies the peer (e.g. Codex). herdr auto-detects ~20
  agent kinds; a peer showing `agent_status: unknown` isn't detected — see `/collab-bus:init`.
- `collab/` exists in the project (else run `/collab-bus:init [peer]`).
- The knock script is `${CLAUDE_PLUGIN_ROOT}/scripts/knock.sh`.

## Running one round (write → knock → read → archive)

1. **Write the message.** Allocate the id atomically — never compute
   "highest + 1" yourself, that races with a concurrent pair and produces two
   messages with the same number:

   ```bash
   DEST=$("${CLAUDE_PLUGIN_ROOT}/scripts/next-id.sh" <peer> <slug> <my-tab-id>)
   ```

   It returns the path of an empty placeholder file it already reserved; write the
   content into that path. Fill PROTOCOL frontmatter (`pair: <my tab_id>`,
   `from: claude`, `to: <peer>`, precise `type`, `status: open`). One concern per
   message. For a review, point at the diff (`git diff`, branch, files) and give
   your framing / design intent — a cold diff yields a shallow review.

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

## Multiple pairs in one repo

Two independent failure modes appear as soon as a second Claude+peer pair opens in
the same workspace:

- **Id collisions.** Always use `scripts/next-id.sh`. It is an owner-aware
  mkdir mutex: the lock records a `host:pid:rand` token, only the holder releases
  it, a waiter that times out never touches it, and the destination is created
  with `noclobber` so nothing is truncated. **Its guarantee is single-host only** —
  `mkdir` is atomic within one filesystem namespace, so in a synced folder
  (Dropbox/iCloud/Drive) two machines can each take the lock in their own local
  view and allocate the same id. For cross-machine ids use a central allocator or
  switch to UUID/ULID. Ids past 9999 fail loudly rather than silently repeating.
- **No real addressee.** `pair` prevents *accidents*, not access — every agent in a
  shared workspace can read and write every inbox, so it is not a security
  boundary. `inbox/to/<peer>/` says *which kind*, not *which one*, and
  both peers read the same directory. Stamp `pair: <tab_id>` in the frontmatter,
  process only messages whose `pair` matches your own tab, and leave the rest
  untouched (they belong to the other pair). Name the file in the knock nudge
  rather than saying "check the inbox".

## Resolving the peer (do this every round)

Never hardcode a pane_id, and never trust one written into an older PROTOCOL.md —
a second pair makes it point at somebody else's agent. Resolve fresh:

1. **Find yourself** by matching `agent_session.value` against your own session id
   (for Claude Code that is the last path segment of your scratchpad directory).
   Do *not* use `focused==true`: it fails whenever terminal focus is elsewhere.
2. **Find the peer** as the agent of the peer kind sharing your `tab_id`.
   (A peer CLI identifies *itself* from herdr's caller env instead: check
   `HERDR_ENV=1`, then `herdr agent get "$HERDR_PANE_ID"`; fall back to matching
   its own session id — e.g. `CODEX_SESSION_ID` — against exactly one
   `herdr agent list` record.)
3. **Print "ME → PEER" before knocking** so the human can catch a misroute.
4. If no peer shares your tab, or more than one does, **stop and ask** rather than
   falling back to a static pane_id.

Knocking the wrong pair interrupts whatever that pair was doing. If it happens,
stop the round, do not retry, and tell the human which pane you hit.

## Gotchas

- **Target is a pane_id** (`w1:p2`). `knock.sh` resolves a name/kind to a pane_id via
  `herdr agent list`, but only when the match is unambiguous — with two agents of the
  same kind it refuses. That refusal is the signal to resolve by tab (above), not a
  reason to dig an old pane_id out of PROTOCOL.md.
- **The knock blocks** for up to `COLLAB_WAIT_MS` (default 10 min). That's intended for
  a review round; don't wrap it inside a latency-sensitive user action.
- **herdr pins the pane during the wait** — don't swap the peer agent mid-round.

## Related commands

- `/collab-bus:init [peer]` — scaffold `collab/` + PROTOCOL, wire the peer as a herdr agent.
- `/collab-bus:send <peer> <subject>` — compose and send one message (knock + read + archive).
- `/collab-bus:status` — show inbox state and the peer agent's herdr state/output.

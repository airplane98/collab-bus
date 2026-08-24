---
name: collab
description: Collaborate with a peer AI CLI (e.g. Codex) running as a herdr-managed agent in a shared workspace. Use when the user wants a second opinion / review / debate from another agent, wants to send it a task, or wants to iterate with it to sign-off — anything referencing "the peer", "Codex", "the other agent", "collab bus", or the collab/ inbox.
---

# collab-bus: peer-agent collaboration on herdr

Two AI CLIs share one repo. **Claude Code is the orchestrator** (plans, implements,
opens branches); a **peer CLI** (default: Codex) is the reviewer / second opinion.
Message *content* + audit trail live in `collab/inbox/` (markdown files); *transport
and turn-completion* run over **herdr** — Claude submits a prompt to the peer agent
and herdr reports, via semantic agent state, when the peer's turn settles.
No tmux, no send-keys, no polling.

The authoritative per-project contract is **`collab/PROTOCOL.md`** (written by
`/collab-bus:init`). Read it if present; it wins over general guidance here —
**with two carve-outs** that supersede any PROTOCOL.md predating them:

1. The **multi-pair safety rules** below (atomic id allocation, `pair` routing,
   resolve-the-peer-every-round). A file generated before v0.3.0 still says
   "next id = highest + 1" — never follow that — and pins a static
   `peer agent target: <pane_id>`; both are known to break once a second
   Claude+peer pair opens in the same repo.
2. The **guarded transport rule**: *both* directions knock through the vendored
   `collab/bin/knock.sh` (pre-settle + prompt), never a bare
   `herdr agent prompt ... --wait`. A file generated before v0.4.0 still tells
   the peer to bare-prompt Claude back, and the project has no (or a pre-0.4)
   `collab/bin/knock.sh` — so the turn race this version closes survives in the
   peer → Claude direction until the project is migrated.

**Migrating a stale project** (do this before the first round, with the human's
OK): re-vendor `collab/bin/` from the plugin
(`mkdir -p collab/bin && cp "${CLAUDE_PLUGIN_ROOT}/scripts/next-id.sh" "${CLAUDE_PLUGIN_ROOT}/scripts/knock.sh" collab/bin/`
— the `mkdir -p` matters: a v0.2 project has `collab/` but no `collab/bin/` yet)
and patch the PROTOCOL.md sections the carve-outs cover — the id-allocation
text, the pair-routing text, and every line that has an agent bare-prompt the
other side. **Patch those sections in place; never regenerate the whole file** —
an existing PROTOCOL.md usually carries project-specific customizations that a
fresh template would silently discard.

## Prerequisites (verify before a round)

- **herdr is running**: `herdr status` shows `server: status: running`.
  collab-bus ≥0.4 needs **herdr ≥ 0.8**: `knock.sh` pre-settles with `agent wait`,
  and self-identification uses `herdr pane current` (both absent in older herdr).
- **The peer is a detected herdr agent**: `herdr agent list` returns an agent whose
  `agent`/`name`/`pane_id` identifies the peer (e.g. Codex). herdr auto-detects ~20
  agent kinds; a peer showing `agent_status: unknown` isn't detected — see `/collab-bus:init`.
- `collab/` exists in the project (else run `/collab-bus:init [peer]`).
- The knock script is `${CLAUDE_PLUGIN_ROOT}/scripts/knock.sh`.

## Running one round (write → knock → read → archive)

1. **Write the message.** Allocate the id atomically.
   Never compute "highest + 1" yourself: that races with a concurrent pair and
   hands both of them the same number.

   ```bash
   # Prefer the project's vendored copy — the peer CLI has no CLAUDE_PLUGIN_ROOT,
   # so both sides must call one entrypoint or they drift apart.
   ALLOC=collab/bin/next-id.sh
   [ -x "$ALLOC" ] || ALLOC="${CLAUDE_PLUGIN_ROOT}/scripts/next-id.sh"
   DEST=$("$ALLOC" <peer> <slug> <my-tab-id>)
   ```

   It returns the path of an empty placeholder file it already reserved; write the
   content into that path. Fill PROTOCOL frontmatter (`pair: <my tab_id>`,
   `from: claude`, `to: <peer>`, precise `type`, `status: open`). One concern per
   message. For a review, point at the diff (`git diff`, branch, files) and give
   your framing / design intent — a cold diff yields a shallow review.

2. **Knock (pre-settle, then submit + wait).** Run:
   `"${CLAUDE_PLUGIN_ROOT}/scripts/knock.sh" <peer-pane-id> "<nudge naming the exact file>"`
   Pass the pane_id you resolved this round, not the kind name, and name the file —
   "the newest open message" misroutes as soon as another pair has one.
   This first settles any in-flight peer turn (`agent wait` — herdr's `prompt --wait`
   does **not** track turns, so prompting a `working` peer can match the *old* turn's
   completion), then submits the nudge and **blocks until the peer's turn settles**,
   printing herdr's JSON with the settled `agent_status`. This is the blessed
   `herdr agent prompt --wait` pattern — there is nothing to poll. Worst case it
   blocks ~2× `COLLAB_WAIT_MS` (settle the old turn + wait for ours).

3. **Interpret the settled state** from the knock's JSON result:
   - `idle` / `done` → the peer finished; its reply file should be in `collab/inbox/to/claude/`.
     **If the reply file is missing**, the wait matched a turn that wasn't ours
     (e.g. another pair knocked the peer in the window between the pre-settle and
     the prompt) and our nudge is still queued. A plain `agent wait` is useless
     here — the peer is already settled, so it matches that same idle instantly.
     Wait for the *next* turn instead: `herdr agent wait <pane_id> --until working
     --timeout 15000` (flips when the queued nudge starts running), then
     `herdr agent wait <pane_id> --timeout 600000` for it to settle. **Re-check the
     inbox after this — including when the `--until working` wait times out**: the
     queued turn may have started and finished before that wait began, so a timeout
     does not mean the nudge was lost. Only if the inbox is *still* empty, surface
     to the human before re-knocking (a blind re-knock duplicates the nudge).
   - `blocked` (settled state, or knock exit 3 / error `agent_blocked` before
     submission) → the peer is stuck on a permission/approval/question UI.
     `herdr agent read <pane_id>` shows what it's stuck on; **surface to the
     human** rather than guessing.
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
  learn when a turn settles from agent state, instead of polling files and guessing
  (which turn it was is what the knock's pre-settle guard and step 3 are about).
- **Clean submission**: `prompt` submits properly; no bracketed-paste "Enter got
  swallowed" bug. **Always prefer `prompt` over `send-keys`** — send-keys bypasses
  state tracking.
- **Inspectable**: `herdr agent get <pane_id>` and `herdr agent read <pane_id>` show
  the peer's state/output directly — no need to ask the human to eyeball a pane.
- **Waitable without prompting**: `herdr agent wait <pane_id>` blocks until the peer
  settles (idle/done/blocked) *without* submitting anything — use it to wait out a
  peer that is currently `working`. On an already-settled peer it returns
  immediately, so it cannot by itself "wait for a late reply" — for a missing
  reply follow the two-stage recovery in step 3.
- Use the `herdr <subcommand>` CLI wrappers (not raw socket) for all of this.
- For herdr control beyond what this file covers, run `herdr --skill` — herdr ships
  a version-matched control skill; prefer it over remembered flag syntax.

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

1. **Find yourself with `herdr pane current`** (herdr ≥ 0.8): it resolves the
   *calling* pane live and returns your `pane_id`, `tab_id`, and `agent_session`
   in one call — no list-scanning. Prefer its live `tab_id` over the `HERDR_TAB_ID`
   env var, which is a start-time snapshot that goes stale if the pane is moved.
   Fallback (only if `pane current` fails, e.g. invoked outside a herdr pane):
   match `agent_session.value` in `herdr agent list` against your own session id
   (for Claude Code that is the last path segment of your scratchpad directory).
   Do *not* use `focused==true`: it fails whenever terminal focus is elsewhere.
2. **Find the peer** as the agent of the peer kind sharing your `tab_id`.
   (A peer CLI identifies *itself* the same way — `herdr pane current` from its
   own shell; fall back to `herdr agent get "$HERDR_PANE_ID"` when `HERDR_ENV=1`,
   then to matching its own session id — e.g. `CODEX_SESSION_ID` — against
   exactly one `herdr agent list` record.)
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
- **The knock blocks** for up to ~2× `COLLAB_WAIT_MS` (default 10 min each: settle the
  in-flight turn, then wait for ours). That's intended for a review round; don't wrap
  it inside a latency-sensitive user action.
- **herdr pins the pane during the wait** — don't swap the peer agent mid-round.

## Related commands

- `/collab-bus:init [peer]` — scaffold `collab/` + PROTOCOL, wire the peer as a herdr agent.
- `/collab-bus:send <peer> <subject>` — compose and send one message (knock + read + archive).
- `/collab-bus:status` — show inbox state and the peer agent's herdr state/output.

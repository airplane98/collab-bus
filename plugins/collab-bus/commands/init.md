---
description: Scaffold collab/ + PROTOCOL in the current project and wire the peer as a herdr agent
---

Set up the collab-bus in **this** project so Claude Code and a peer AI CLI can
collaborate over herdr. Peer name from `$1` (default `codex`).

The file scaffolding lives in `scripts/bootstrap.sh` (provider-neutral, so the peer can
set a bus up too). **Call it — do not re-implement it here**, or the two paths drift.
What this command adds on top is the part needing judgement: wiring the peer as a herdr
agent, the onboarding message, and the handshake.

1. **Check herdr.** `herdr status` must show `server: status: running`. If herdr is
   missing, tell the user to install it (https://herdr.dev) — collab-bus ≥0.2 needs
   it, and collab-bus ≥0.4 needs **herdr ≥ 0.8** (`agent wait`, `pane current`,
   `agent start`); `herdr --version` if unsure.

2. **Resolve names.**
   - `PEER` = `$1` or `codex`.
   - `KIND` = the herdr agent kind for `PEER` (usually the same word; must be one of
     the kinds `herdr agent start --help` lists).
   - `NAME` = `<KIND>-<your tab_id with the colon dropped>`, e.g. `codex-w3t6`
     (computed in step 4 once you know your tab). herdr live-agent names are
     **workspace-unique**: a bare `codex` collides the moment a second tab runs
     init, so the name must be pair-scoped. Keep it `[a-z][a-z0-9_-]{0,31}`.

3. **Scaffold (or migrate) the bus — one command:**
   ```bash
   COLLAB_BUS_TRUSTED_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
   PROJECT_ROOT="$(pwd -P)"
   "$COLLAB_BUS_TRUSTED_SCRIPTS/bootstrap.sh" <PEER> || exit 1
   BIN=$("$COLLAB_BUS_TRUSTED_SCRIPTS/preflight.sh" --dir "$PROJECT_ROOT") || exit 1
   ```
   Bootstrap and preflight both come from the installed plugin, never from the project
   tree they are creating or vetting. Every later project runtime in this command uses
   the returned `$BIN`.
   **Its output tells you which of two paths you are on — they do not continue the same
   way.** Read it before doing anything else.

   - **`scaffolded …` (fresh project)** → it created `collab/inbox/to/{claude,<PEER>}/`,
     `inbox/archive/`, `reviews/`, `tasks/` (each with `.gitkeep`), vendored
     `collab/bin/{next-id,publish,knock}.sh` (the peer CLI has no `CLAUDE_PLUGIN_ROOT`,
     so both sides must call one copy), and rendered `collab/PROTOCOL.md` stamped with
     the plugin version. **Continue with steps 4–6.**

   - **`migrated …` (the project already had a bus)** → it re-vendored `collab/bin/`
     only, deliberately leaving `PROTOCOL.md` and every message file alone. Now
     **patch that PROTOCOL.md in place** where it disagrees with this version (id
     allocation, both-directions-through-`knock.sh` transport, the version line) —
     never regenerate it wholesale, it usually carries project-specific edits. Then:
     if the peer is not currently wired as a herdr agent in your tab, do step 4 to wire
     it — **and then stop. Always skip steps 5–6.** The pair is already onboarded;
     re-sending an onboarding message and re-running the handshake would duplicate work
     (and there is no new `$DEST` for step 6 to name). Re-onboard only if the human
     explicitly asks.

4. **Wire the peer as a herdr agent.** Note its `pane_id` for *this session only* —
   do **not** bake it into PROTOCOL.md. With more than one pair in the workspace a
   stored pane_id points at somebody else's agent; the template therefore tells
   agents to resolve by `tab_id` every round.
   - **Identify yourself first** with `herdr pane current` — it resolves the calling
     pane live and gives your `pane_id` and `tab_id` in one call (fallback if it
     fails: match your session id against `agent_session.value` in
     `herdr agent list`; never `focused`). Then accept a peer of the right kind
     **only if exactly one shares your `tab_id`**. With several pairs open, "the
     detected kind" is not enough — it can be somebody else's agent.
   - **If no peer is running yet, wire one yourself** (herdr ≥ 0.8):
     ```bash
     herdr pane split --current --direction right --cwd "$PWD"   # note new pane_id in the JSON
     herdr agent start <NAME> --kind <KIND> --pane <new_pane_id>
     ```
     `--current` splits *your own* pane, so the peer lands in your tab and the
     same-tab pairing above holds by construction; `NAME` is the pair-scoped
     unique name from step 2 (a bare kind name fails on the second pair).
     `agent start` waits until the agent is detected and ready for input. If the
     kind isn't supported or start fails, fall back to instructing the human:
     open a new herdr **pane in this same tab** (a new tab would not satisfy the
     same-tab pairing) and run the peer CLI there in this project dir, e.g.
     `cd <project> && codex`; then re-run `herdr agent list` and take the new
     `pane_id`.
   - For a manually-wired peer, optional but recommended for a stable target:
     `herdr agent rename <pane_id> <NAME>` (the pair-scoped name — renaming two
     pairs' peers to the same bare `<PEER>` would defeat the point).

5. **Write the onboarding message** via the allocator (never a hardcoded `0001`):
   `DRAFT=$("$BIN/next-id.sh" <PEER> onboarding <your-tab-id>)` → write the body
   into `$DRAFT` with `pair: <your tab_id>` in the frontmatter → publish it
   `DEST=$("$BIN/publish.sh" "$DRAFT")`. The inbox may not be empty, so do not
   assume any particular number — and do not tell the peer to reply with a specific
   id either; ask it to allocate its own and reply with `reply_to: <your id>`
   (frontmatter per PROTOCOL, `type: task`, `status: open`) instructing the peer to:
   read `collab/PROTOCOL.md` and any project `CLAUDE.md`/`AGENTS.md`; configure
   `COLLAB_BUS_TRUSTED_SCRIPTS` in provider-local state to its own clone/install outside
   the project, run that trusted `preflight.sh --dir <project>`, and confirm the role it
   is taking this round; then reply into `collab/inbox/to/claude/` using **only the
   `$BIN` returned by that preflight** (never a fixed number, and publish so its reply is
   never read half-written) with `reply_to: <the onboarding id you just got>`
   and `pair: <your tab_id>` — its stack summary + whether it can run git/tests —
   and archive the onboarding message.

6. **Kick off the handshake** (only if the peer agent is already detected): knock the
   **pane_id resolved in step 4** and name the **actual file** written in step 5 —
   `"$BIN/knock.sh" <peer-pane-id> "Handshake: process $DEST"` —
   which submits and waits for the peer's turn. Then find the reply by matching
   `pair` + `reply_to`, never by guessing a file number, and archive per PROTOCOL.
   If the peer isn't wired yet, tell the human the one step (run the peer in a herdr pane)
   and stop.

Keep output tight: confirm what was scaffolded and the peer's herdr target, then the
next action (either "peer wired, handshake done" or "run the peer in a herdr pane").

---
description: Scaffold collab/ + PROTOCOL in the current project and wire the peer as a herdr agent
---

Set up the collab-bus in **this** project so Claude Code and a peer AI CLI can
collaborate over herdr. Peer name from `$1` (default `codex`).

1. **Check herdr.** `herdr status` must show `server: status: running`. If herdr is
   missing, tell the user to install it (https://herdr.dev) — collab-bus ≥0.2 needs
   it, and collab-bus ≥0.4 needs **herdr ≥ 0.8** (`agent wait`, `pane current`,
   `agent start`); `herdr --version` if unsure.

2. **Resolve names.**
   - `PEER` = `$1` or `codex`.
   - `KIND` = the herdr agent kind for `PEER` (usually the same word; must be one of
     the kinds `herdr agent start --help` lists).
   - `NAME` = `<KIND>-<your tab_id with the colon dropped>`, e.g. `codex-w3t6`
     (computed in step 5 once you know your tab). herdr live-agent names are
     **workspace-unique**: a bare `codex` collides the moment a second tab runs
     init, so the name must be pair-scoped. Keep it `[a-z][a-z0-9_-]{0,31}`.
   - `PROJECT` = basename of the git toplevel (`git rev-parse --show-toplevel`), else cwd.

3. **Re-run on an existing project = migration, not re-scaffold.** If `collab/`
   already exists: update the vendored scripts
   (`mkdir -p collab/bin && cp "${CLAUDE_PLUGIN_ROOT}/scripts/next-id.sh" "${CLAUDE_PLUGIN_ROOT}/scripts/publish.sh" "${CLAUDE_PLUGIN_ROOT}/scripts/knock.sh" collab/bin/`
   — the `mkdir -p` matters: a v0.2 project has no `collab/bin/` yet; publish.sh is
   new in v0.6, so a v0.3–v0.5 project gains it here),
   then **patch** the existing PROTOCOL.md in place — the id-allocation, pair-routing,
   and transport sections (any line having an agent bare-prompt the other side must
   route through `collab/bin/knock.sh`), plus its recorded plugin version — and skip
   the scaffold/onboarding steps below. Never overwrite a PROTOCOL.md wholesale:
   it usually carries project-specific customizations.

4. **Scaffold** (idempotent — don't clobber existing message files):
   ```
   collab/inbox/to/<PEER>/   collab/inbox/to/claude/   collab/inbox/archive/
   collab/reviews/           collab/tasks/
   ```
   Add a `.gitkeep` in each so the structure survives a clone.

5. **Wire the peer as a herdr agent.** Note its `pane_id` for *this session only* —
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

6. **Write `collab/PROTOCOL.md`** from `${CLAUDE_PLUGIN_ROOT}/templates/PROTOCOL.template.md`,
   substituting `{{PROJECT}}` and `{{PEER}}`. (`{{TARGET}}` is gone — coordinates are
   resolved dynamically, not stored.) Also vendor the allocator, the publish
   script, AND the knock script into the project so the peer CLI — which has no
   `CLAUDE_PLUGIN_ROOT` — calls the same entrypoints (the reverse knock needs the
   same pre-settle guard, and the peer must publish atomically too, or the turn
   race / empty-message race survives in the peer → Claude direction):
   `mkdir -p collab/bin && cp "${CLAUDE_PLUGIN_ROOT}/scripts/next-id.sh" "${CLAUDE_PLUGIN_ROOT}/scripts/publish.sh" "${CLAUDE_PLUGIN_ROOT}/scripts/knock.sh" collab/bin/`
   and record the plugin version they came from in PROTOCOL.md.

7. **Write the onboarding message** via the allocator (never a hardcoded `0001`):
   `DRAFT=$(collab/bin/next-id.sh <PEER> onboarding <your-tab-id>)` → write the body
   into `$DRAFT` with `pair: <your tab_id>` in the frontmatter → publish it
   `DEST=$(collab/bin/publish.sh "$DRAFT")`. The inbox may not be empty, so do not
   assume any particular number — and do not tell the peer to reply with a specific
   id either; ask it to allocate its own and reply with `reply_to: <your id>`
   (frontmatter per PROTOCOL, `type: task`, `status: open`) instructing the peer to:
   read `collab/PROTOCOL.md` and any project `CLAUDE.md`/`AGENTS.md`; confirm its role
   as reviewer; then reply into `collab/inbox/to/claude/` using **its own
   next-id.sh + publish.sh** (never a fixed number, and publish so its reply is
   never read half-written) with `reply_to: <the onboarding id you just got>`
   and `pair: <your tab_id>` — its stack summary + whether it can run git/tests —
   and archive the onboarding message.

8. **Kick off the handshake** (only if the peer agent is already detected): knock the
   **pane_id resolved in step 5** and name the **actual file** written in step 7 —
   `"${CLAUDE_PLUGIN_ROOT}/scripts/knock.sh" <peer-pane-id> "Handshake: process $DEST"` —
   which submits and waits for the peer's turn. Then find the reply by matching
   `pair` + `reply_to`, never by guessing a file number, and archive per PROTOCOL.
   If the peer isn't wired yet, tell the human the one step (run the peer in a herdr pane)
   and stop.

Keep output tight: confirm what was scaffolded and the peer's herdr target, then the
next action (either "peer wired, handshake done" or "run the peer in a herdr pane").

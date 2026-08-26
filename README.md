# collab-bus

**Peer collaboration between two AI coding CLIs** sharing one repo — Claude Code and a
second CLI like **Codex**. Message *content* + audit trail live in a filesystem bus
(`collab/inbox/`); *transport and turn-completion* run over **[herdr](https://herdr.dev)**,
an agent-aware terminal workspace manager.

Use it when you want a genuinely independent agent to **review, debate, and sign off**
on your work in a multi-round loop, with a durable audit trail — not a one-shot verdict.

**Roles are symmetric — either side can be the one asking.** Claude Code can send Codex a
diff to review, and Codex can just as well file a review request back to Claude Code and
wait for *its* sign-off. Nothing privileges one side: `from`/`to` are message fields, the
knock works in both directions, and both agents call the same vendored scripts. The docs
use "one proposes, the other reviews" as the common case, not as a constraint.

**It ships as a Claude Code plugin, but the peer installs nothing.** `/collab-bus:init`
scaffolds the bus, *vendors* the scripts into the project itself (`collab/bin/`), and
writes the shared contract (`collab/PROTOCOL.md`). Those files are what the peer CLI reads
and runs — so Codex (or any CLI that can read a file and run a shell script) participates
fully with nothing installed. Only the bootstrap and the `/collab-bus:*` slash commands
need Claude Code today.

## Why herdr

herdr is agent-aware: it knows each agent's semantic state (`idle`/`working`/`blocked`/
`done`). collab-bus rides that instead of raw tmux, so:

- **Guarded submit + wait** — `knock.sh` settles any in-flight peer turn
  (`agent wait`), then `herdr agent prompt <peer> "..." --wait` returns when the
  peer's turn settles. Nothing to poll. (Two herdr calls, so a small window
  remains between them; the skill documents the recovery.)
- **Clean submission** — no bracketed-paste "Enter got swallowed" problem.
- **Inspectable** — `herdr agent get/read <pane_id>` shows the peer's state/output; no
  need to eyeball a terminal.

> collab-bus **v0.1** used raw tmux `send-keys` + file polling (still in git history).
> **v0.2+ requires herdr; v0.4+ requires herdr ≥ 0.8** (`agent wait`, `pane current`,
> `agent start`).

## Install (any machine)

```
/plugin marketplace add airplane98/collab-bus
/plugin install collab-bus@collab-bus
/reload-plugins
```

Requires **[herdr](https://herdr.dev)** (`curl`/Homebrew/Nix) and a second AI CLI (e.g. `codex`).

### Setting a bus up *without* Claude Code

The plugin format is Claude Code's, but nothing about the bus is. `bootstrap.sh` is plain
bash and does all the file setup, so the peer — or a human — can start a bus:

```
git clone https://github.com/airplane98/collab-bus
cd <your project>
/path/to/collab-bus/plugins/collab-bus/scripts/bootstrap.sh codex
```

That scaffolds `collab/`, vendors `collab/bin/{next-id,publish,knock}.sh`, and renders
`collab/PROTOCOL.md` — everything either agent needs. Re-running it on a project that
already has a bus **migrates** instead: it refreshes `collab/bin/` and leaves your
PROTOCOL.md and messages untouched. `/collab-bus:init` calls this same script and then
adds the parts that need an agent: wiring the peer in herdr, the onboarding message, and
the handshake.

## Use

```
/collab-bus:init [peer]      # scaffold collab/, wire the peer as a herdr agent, handshake
/collab-bus:send <peer> ...  # compose + send one message, wait for the peer, read the reply
/collab-bus:status [peer]    # inbox state + the peer's live herdr agent_status
```

Or just ask Claude in plain language ("get Codex's second opinion on this diff") — the
bundled `collab` skill drives the write → publish → knock → read → archive loop. In the
other direction you tell the peer instead ("file a review request to Claude"); it follows
the same `collab/PROTOCOL.md` and runs the same vendored scripts.

### Wiring the peer

1. `/collab-bus:init codex` — scaffolds `collab/`, wires the peer itself when possible
   (`herdr pane split --current` + `herdr agent start`, so the peer lands in your own
   tab), writes the protocol, and runs the onboarding handshake. Manual alternative:
   open a pane **in the same tab** and run the peer CLI there (`cd <project> && codex`);
   herdr auto-detects ~20 agent kinds.
2. From then on, each round is one knock: `knock.sh` settles any in-flight peer turn
   (`herdr agent wait`), then `herdr agent prompt <peer> --wait` submits and blocks
   until the peer finishes.

## How it works

- **Transport + completion**: `scripts/knock.sh` = `herdr agent wait` (pre-settle:
  `prompt --wait` doesn't track turns, so a busy peer could match the *old* turn) +
  `herdr agent prompt <pane_id> "<nudge>" --wait` — the blessed herdr CLI pattern;
  prefer `prompt` over `send-keys`.
- **Bus**: `collab/inbox/to/{claude,<peer>}` + `archive/`; one markdown message per file.
- **Message ids**: `scripts/next-id.sh` mints a **ULID** (v0.5) — time-ordered,
  collision-resistant, and generated with no coordination. There is no shared
  counter and therefore no lock; two agents (even across a synced folder) allocate
  independently with a negligible collision probability.
- **Atomic publish** (v0.6): `next-id.sh` returns a hidden **draft**
  (`.<ULID>-…md.part`); the sender writes the body and then `scripts/publish.sh`
  renames it to the final `<ULID>-…md`. A same-dir rename is atomic, so a receiver
  scanning the inbox never reads a reserved-but-empty message. publish.sh refuses a
  0-byte draft — the last guard against shipping an empty message.
- **Async knock** (v0.6.1): `knock.sh --submit-only` fires a nudge and returns as
  soon as herdr accepts it (no pre-settle, no `--wait`) — for symmetric / mesh use
  where a synchronous reply would deadlock a peer that is waiting on you. The
  receiver reconciles its inbox at turn start (durable files, at-least-once), so a
  best-effort nudge is enough. The default knock stays synchronous.
- **Protocol**: `collab/PROTOCOL.md` (written by `init`) is the per-project contract.

## When to use this vs a review plugin

- One-shot "review this diff for bugs" → a dedicated review plugin/command is simpler.
- Multi-round debate, design decisions, iterate-to-consensus, audit trail → collab-bus.

## Layout

```
.claude-plugin/marketplace.json     # marketplace listing (this repo is its own marketplace)
plugins/collab-bus/
├── .claude-plugin/plugin.json
├── skills/collab/SKILL.md          # the collaboration workflow (either side may lead)
├── commands/{init,send,status}.md  # /collab-bus:* commands
├── scripts/bootstrap.sh            # provider-neutral setup/migrate (init calls this)
├── scripts/next-id.sh              # allocate a message: mint a ULID, create a .md.part draft
├── scripts/publish.sh              # atomic publish: rename the draft to the final .md
├── scripts/knock.sh                # herdr transport: agent prompt --wait (+ --submit-only)
└── templates/PROTOCOL.template.md  # per-project protocol, rendered by bootstrap.sh
```

## License

MIT

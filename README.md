# collab-bus

A Claude Code plugin for **peer collaboration between two AI CLIs** — Claude Code
(orchestrator) and a second CLI like **Codex** (reviewer / second opinion) — sharing
one repo. Message *content* + audit trail live in a filesystem bus (`collab/inbox/`);
*transport and turn-completion* run over **[herdr](https://herdr.dev)**, an
agent-aware terminal workspace manager.

Use it when you want a genuinely independent agent to **review, debate, and sign off**
on your work in a multi-round loop, with a durable audit trail — not a one-shot verdict.

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

## Use

```
/collab-bus:init [peer]      # scaffold collab/, wire the peer as a herdr agent, handshake
/collab-bus:send <peer> ...  # compose + send one message, wait for the peer, read the reply
/collab-bus:status [peer]    # inbox state + the peer's live herdr agent_status
```

Or just ask Claude in plain language ("get Codex's second opinion on this diff") — the
bundled `collab` skill drives the write → knock → read → archive loop.

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
- **Protocol**: `collab/PROTOCOL.md` (written by `init`) is the per-project contract.

## When to use this vs a review plugin

- One-shot "review this diff for bugs" → a dedicated review plugin/command is simpler.
- Multi-round debate, design decisions, iterate-to-consensus, audit trail → collab-bus.

## Layout

```
.claude-plugin/marketplace.json     # marketplace listing (this repo is its own marketplace)
plugins/collab-bus/
├── .claude-plugin/plugin.json
├── skills/collab/SKILL.md          # the orchestration workflow
├── commands/{init,send,status}.md  # /collab-bus:* commands
├── scripts/next-id.sh              # allocate a message: mint a ULID + create the file
├── scripts/knock.sh                # herdr transport: agent prompt --wait
└── templates/PROTOCOL.template.md  # per-project protocol, filled by init
```

## License

MIT

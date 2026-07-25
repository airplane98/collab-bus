# collab-bus

A Claude Code plugin for **peer collaboration between two AI CLIs** — Claude Code
(orchestrator) and a second CLI like **Codex** (reviewer / second opinion) — running
in a shared tmux session on one repo. They exchange markdown messages over a
filesystem bus (`collab/inbox/`) and knock each other via tmux `send-keys`.

Use it when you want a genuinely independent agent to **review, debate, and sign off**
on your work in a multi-round loop, with a durable audit trail — not a one-shot verdict.

## Install (any machine)

```
/plugin marketplace add airplane98/collab-bus
/plugin install collab-bus@collab-bus
/reload-plugins
```

Requires `tmux` (`brew install tmux`) and a second AI CLI (e.g. `codex`).

## Use

```
/collab-bus:init [peer]      # scaffold collab/ in this project; prints tmux launch + onboarding
/collab-bus:send <peer> ...  # compose + send one message, then poll for the reply
/collab-bus:status [peer]    # show inbox state and the peer's pane
```

Or just ask Claude in plain language ("get Codex's second opinion on this diff") — the
bundled `collab` skill drives the send → knock → poll → archive loop.

### Wiring the peer

1. `/collab-bus:init codex` in your project.
2. Start the shared tmux session and run the peer inside it (init prints the exact command):
   ```
   tmux -S /tmp/collab-bus.sock new-session -s <project> -n codex
   #   then in that pane:  cd <project> && codex
   ```
3. Tell Claude "peer is up." Claude knocks and drives the rounds.

## How it works

- **Transport**: tmux `send-keys` injects a one-line nudge into the peer's prompt.
- **Bus**: `collab/inbox/to/{claude,<peer>}` + `archive/`; one markdown message per file.
- **Protocol**: `collab/PROTOCOL.md` (written by `init`) is the per-project contract.
- **Fixed socket** `/tmp/collab-bus.sock`: a backgrounded agent's `$TMPDIR` differs from
  the terminal's, so a fixed absolute socket guarantees both sides reach the same server.

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
├── scripts/notify.sh               # tmux knock
└── templates/PROTOCOL.template.md  # per-project protocol, filled by init
```

## License

MIT

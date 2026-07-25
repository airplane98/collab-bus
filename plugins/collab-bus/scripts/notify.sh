#!/usr/bin/env bash
# collab-bus notifier — tmux "knock": inject a line into the peer agent's prompt
# so it goes and reads its inbox. Project-agnostic; part of the collab-bus plugin.
#
# Usage:
#   notify.sh <recipient> [note]
#     recipient : the peer's tmux window name (e.g. "codex") or "claude"
#     note      : optional one-line nudge shown to the peer
#
# Env overrides:
#   COLLAB_TMUX_SOCK   tmux socket path    (default /tmp/collab-bus.sock)
#   COLLAB_SESSION     tmux session name   (default: basename of git toplevel, else $PWD)
#
# Why a fixed socket: a backgrounded agent's $TMPDIR can differ from the
# terminal's, so the default per-user tmux socket may be unreachable. A fixed
# absolute socket path guarantees both sides talk to the same tmux server.

set -euo pipefail

SOCK="${COLLAB_TMUX_SOCK:-/tmp/collab-bus.sock}"
TMUX_CMD=(tmux -S "$SOCK")

recipient="${1:-}"
note="${2:-Read the newest open message in collab/inbox and act per PROTOCOL.}"

if [[ -z "$recipient" ]]; then
  echo "usage: notify.sh <recipient> [note]" >&2
  exit 2
fi

# session name: explicit override, else git repo basename, else cwd basename.
if [[ -n "${COLLAB_SESSION:-}" ]]; then
  session="$COLLAB_SESSION"
else
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  session="$(basename "${toplevel:-$PWD}")"
fi
# tmux dislikes '.' and ':' in session names.
session="${session//[.:]/_}"

target="${session}:${recipient}"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found — fall back to human relay: ask the '$recipient' window to read collab/inbox." >&2
  exit 1
fi

if ! "${TMUX_CMD[@]}" has-session -t "$session" 2>/dev/null; then
  echo "tmux session '$session' not found (socket=$SOCK). Start it first:" >&2
  echo "  tmux -S $SOCK new-session -s $session -n $recipient" >&2
  exit 1
fi

msg="[collab] ${note} (read collab/inbox/to/${recipient}/ newest open message; act per PROTOCOL.md)"
# Send the text and Enter separately, with a 0.3s gap: TUIs (Codex, etc.) use
# bracketed-paste; sending the payload and Enter together — or the Enter too
# fast — makes the newline land as literal text and the input never submits.
"${TMUX_CMD[@]}" send-keys -t "$target" -l "$msg"
sleep 0.3
"${TMUX_CMD[@]}" send-keys -t "$target" Enter
echo "notified $recipient @ $target (socket=$SOCK)"

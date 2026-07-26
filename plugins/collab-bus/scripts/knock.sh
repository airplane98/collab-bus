#!/usr/bin/env bash
# collab-bus knock — herdr transport.
#
# Submits a nudge to the peer agent AND blocks until its turn settles, using
# herdr's semantic agent states. This is the blessed `agent prompt --wait`
# pattern (atomic submit+wait, no race) via the herdr CLI wrapper — NOT raw
# socket writes and NOT `send-keys` (which bypasses state tracking).
#
# Replaces the old tmux `notify.sh` (send-keys + manual Enter + file polling):
# herdr tells us exactly when the peer finished, so there is nothing to poll.
#
# Usage: knock.sh <peer> [nudge]
#   <peer>  herdr agent: a pane_id (e.g. w1:p2), a unique agent name, or the
#           detected kind (e.g. "codex"). Best-effort resolved to a pane_id via
#           `agent list` (needs python3); otherwise passed straight to herdr.
#   [nudge] one-line instruction submitted to the peer's prompt.
#
# Env:
#   COLLAB_WAIT_MS   settle timeout in ms (default 600000 = 10 min)
#
# Output: herdr's JSON result on stdout (the settled AgentStatus). Inspect it:
#   idle/done → the peer finished; its reply file should be ready to read.
#   blocked   → the peer is waiting on a permission/approval UI; surface to human.
# Nonzero exit: bad usage (2), herdr missing (1); an unresolved target or a
# stalled/timeout prompt surfaces herdr's own error JSON with its exit code.

set -uo pipefail

peer="${1:-}"
nudge="${2:-Read the newest open message addressed to you under collab/inbox/ and act per collab/PROTOCOL.md; write your reply file and archive the message when your turn is done.}"

[[ -z "$peer" ]] && { echo "usage: knock.sh <peer|pane_id> [nudge]" >&2; exit 2; }
command -v herdr >/dev/null 2>&1 || {
  echo "herdr not found. collab-bus >=0.2 runs on herdr (https://herdr.dev)." >&2
  exit 1
}

# Resolve <peer> to a pane_id (herdr's canonical target). Best-effort: needs
# python3; falls back to passing <peer> through so an explicit pane_id/name still
# works without python. `|| true` keeps `set -e`-style aborts away from the pipe.
target="$peer"
if command -v python3 >/dev/null 2>&1; then
  resolved="$(herdr agent list 2>/dev/null | python3 -c '
import json, sys
peer = sys.argv[1]
try:
    agents = (json.load(sys.stdin).get("result") or {}).get("agents") or []
except Exception:
    agents = []
def match(a):
    return peer in (a.get("pane_id"), a.get("name"), a.get("agent"), a.get("display_agent"))
hits = [a for a in agents if match(a)]
if not hits and len(agents) == 1:
    hits = agents
print(hits[0]["pane_id"] if hits else "")
' "$peer" 2>/dev/null || true)"
  [[ -n "$resolved" ]] && target="$resolved"
fi

echo "knock → $peer (target=$target): submit + wait for turn to settle (idle/done/blocked, timeout ${COLLAB_WAIT_MS:-600000}ms)" >&2
# No --until: `prompt --wait` defaults to idle/done/blocked = "turn settled".
# The JSON result reports which state settled; the caller decides what to do next.
exec herdr agent prompt "$target" "$nudge" --wait --timeout "${COLLAB_WAIT_MS:-600000}"

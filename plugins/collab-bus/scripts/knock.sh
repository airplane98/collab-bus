#!/usr/bin/env bash
# collab-bus knock — herdr transport.
#
# Submits a nudge to the peer agent AND blocks until its turn settles, using
# herdr's semantic agent states: a guarded two-step (`agent wait` pre-settle,
# then `agent prompt --wait`) via the herdr CLI wrapper — NOT raw socket
# writes and NOT `send-keys` (which bypasses state tracking). The two steps
# leave a small window between them (another pair can knock the same peer in
# it); the docs' missing-reply recovery covers that residue — this script
# closes the big race, it does not make the exchange atomic.
#
# Replaces the old tmux `notify.sh` (send-keys + manual Enter + file polling):
# herdr reports when the peer's turn settles, so there is nothing to poll.
#
# Usage: knock.sh [--submit-only] <peer> [nudge]
#   <peer>  herdr agent: a pane_id (e.g. w1:p2), a unique agent name, or the
#           detected kind (e.g. "codex"). Best-effort resolved to a pane_id via
#           `agent list` (needs python3); otherwise passed straight to herdr.
#   [nudge] one-line instruction submitted to the peer's prompt.
#
# Needs herdr >= 0.8 (`agent wait`). Before prompting, the script settles any
# in-flight peer turn with `agent wait`: herdr documents that `prompt --wait`
# does NOT track turns — submitted while the peer is still `working`, the wait
# can match the OLD turn's completion and the caller goes looking for a reply
# that was never written. herdr also rejects a prompt outright (agent_blocked)
# when the peer is already blocked, so a blocked pre-wait stops here instead.
#
# Env:
#   COLLAB_WAIT_MS   settle timeout in ms (default 600000 = 10 min).
#                    Worst case the script blocks ~2x this: once settling the
#                    in-flight turn, once waiting for our own.
#
# Output: herdr's JSON result on stdout (the settled AgentStatus); herdr's own
# errors stay on stderr with their exit code. Inspect the result:
#   idle/done → the peer finished; its reply file should be ready to read.
#   blocked   → the peer is waiting on a permission/approval UI; surface to human.
# Nonzero exit: herdr missing (1), bad usage (2), peer already blocked before
# the prompt (3), unparseable pre-wait result (4); an unresolved target or a
# stalled/timeout prompt surfaces herdr's error JSON with herdr's exit code.
#
# SUBMIT-ONLY (v0.6.1, for symmetric / mesh use): `knock.sh --submit-only <peer>`
# skips the pre-settle AND drops `--wait`. It fires the nudge and returns as soon
# as herdr ACCEPTS the submission — it does NOT wait for the peer to start,
# finish, or write a reply. Use it to break a wait-cycle deadlock: while A is
# synchronously waiting on B, B must not reverse-knock A in the default (blocking)
# mode — both would wait forever. A probe (2026-08-26) confirmed a no-wait prompt
# to a WORKING peer is accepted and QUEUED after its current turn — not dropped,
# not steered. herdr still rejects a blocked peer (agent_blocked) and surfaces
# errors; those pass straight through. The durable inbox file is the source of
# truth — the nudge is a best-effort wakeup, so the receiver must reconcile its
# inbox at turn start rather than rely on this having woken it. On an accepted
# submission stderr carries the grep-able marker `submitted, not settled`.

set -uo pipefail

submit_only=0
if [ "${1:-}" = "--submit-only" ]; then submit_only=1; shift; fi
peer="${1:-}"
# The default deliberately does NOT say "read the newest open message": with more
# than one Claude+peer pair sharing collab/inbox/, the newest open item may belong
# to the other pair. Callers should pass an explicit file path.
nudge="${2:-Act on the message addressed to you under collab/inbox/ whose \`pair\` matches your own herdr tab_id — ignore messages belonging to other pairs. Follow collab/PROTOCOL.md; write your reply file and archive the message when your turn is done. (The caller did not name a file; ask which one if it is ambiguous.)}"

[[ -z "$peer" ]] && { echo "usage: knock.sh [--submit-only] <peer|pane_id> [nudge]" >&2; exit 2; }
command -v herdr >/dev/null 2>&1 || {
  echo "herdr not found. collab-bus >=0.2 runs on herdr (https://herdr.dev)." >&2
  exit 1
}

# Resolve <peer> to a pane_id (herdr's canonical target). Best-effort: needs
# python3; otherwise (or on any failure) <peer> is passed straight to herdr, so an
# explicit pane_id/name still works. Only an UNAMBIGUOUS match resolves — zero or
# multiple matches defer to herdr rather than silently guessing a target. The
# trailing `|| true` swallows a nonzero pipeline exit so `resolved` is cleanly empty
# (the script uses `set -uo pipefail`, not `-e`, so this only affects this capture).
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
# Resolve only a unique match; 0 or >1 -> empty -> caller passes <peer> to herdr.
print(hits[0]["pane_id"] if len(hits) == 1 else "")
' "$peer" 2>/dev/null || true)"
  [[ -n "$resolved" ]] && target="$resolved"
fi

if [ "$submit_only" -eq 1 ]; then
  # Async submit: skip the pre-settle (the wait-cycle's first blocking edge) and
  # drop --wait. Return the moment herdr accepts the submission. The probe
  # confirmed a no-wait prompt to a working peer is accepted and queued, not
  # dropped or steered. herdr's stdout (agent_prompted JSON) and its errors
  # (incl. agent_blocked for a blocked peer) pass through; we keep the exit code.
  # The `submitted, not settled` marker prints ONLY on an accepted submission —
  # a rejected one keeps herdr's nonzero code and no false "submitted".
  echo "knock → $peer (target=$target): submit-only (no pre-settle, no --wait)" >&2
  herdr agent prompt "$target" "$nudge"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "submitted, not settled — herdr accepted the submission; the reply is not settled and lands in the inbox, so reconcile there rather than waiting here." >&2
  fi
  exit "$rc"
fi

wait_ms="${COLLAB_WAIT_MS:-600000}"

# Pre-settle the peer. Without --until, `agent wait` matches idle/done/blocked:
# an idle peer returns immediately, a working one blocks until ITS current turn
# ends — which is exactly the turn `prompt --wait` would otherwise mis-match.
# stderr is NOT captured, so a failure (timeout, agent_not_found, or an unknown
# subcommand on herdr < 0.8) leaves herdr's error JSON on stderr — same stream
# as the prompt step's errors — and stops: prompting an unsettled peer would
# reintroduce the race this guard exists to close.
echo "knock → $peer (target=$target): pre-settle any in-flight turn (timeout ${wait_ms}ms)" >&2
pre="$(herdr agent wait "$target" --timeout "$wait_ms")"; rc=$?
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

# Blocked gate. Parse agent_status when python3 is available — a substring match
# would fail OPEN the day herdr pretty-prints or wraps this output. Unparseable
# success output fails CLOSED (exit 4) rather than prompting blind. Without
# python3, the substring match on herdr 0.8's compact JSON is the fallback.
if command -v python3 >/dev/null 2>&1; then
  status="$(printf '%s' "$pre" | python3 -c '
import json, sys
try:
    a = (json.load(sys.stdin).get("result") or {}).get("agent") or {}
    s = a.get("agent_status")
except Exception:
    sys.exit(1)
if not s:
    sys.exit(1)
print(s)
')" || {
    echo "knock: could not parse the pre-settle result below — not prompting blind." >&2
    printf '%s\n' "$pre" >&2
    exit 4
  }
else
  status=""
  case "$pre" in *'"agent_status":"blocked"'*) status="blocked";; esac
fi
if [ "$status" = "blocked" ]; then
  echo "peer is blocked on an approval/permission UI — herdr would reject the prompt (agent_blocked). Surface to the human; \`herdr agent read $target\` shows what it is stuck on." >&2
  printf '%s\n' "$pre"
  exit 3
fi

echo "knock → $peer (target=$target): submit + wait for turn to settle (idle/done/blocked, timeout ${wait_ms}ms)" >&2
# No --until: `prompt --wait` defaults to idle/done/blocked = "turn settled".
# The JSON result reports which state settled; the caller decides what to do next.
exec herdr agent prompt "$target" "$nudge" --wait --timeout "$wait_ms"

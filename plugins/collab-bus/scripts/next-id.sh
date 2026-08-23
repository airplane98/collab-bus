#!/usr/bin/env bash
# Atomically allocate the next message id.
#
# Why this exists: the naive rule ("next id = highest NNNN + 1") is a
# read-then-write race. When two Claude+peer pairs work in the same repo at the
# same time, both read the same maximum and both write the same number. Observed
# in the wild: one inbox ended up with two different messages numbered 0033.
#
# GUARANTEE AND ITS LIMIT
#   mkdir is atomic within one filesystem namespace, so this serialises
#   concurrent processes ON ONE HOST sharing one local view of the directory.
#   It is NOT a distributed lock. In a synced folder (Dropbox/iCloud/Drive) two
#   machines can each create .idlock in their own local view, read the same MAX
#   and allocate the same id; the sync layer then produces a conflicted copy
#   rather than resolving the race. If you need cross-machine ids, use a central
#   allocator, or switch to UUID/ULID names instead of a monotonic counter.
#
# Usage:  next-id.sh <to> <slug> <tab>
#   e.g.  next-id.sh codex review-auth w3:t3
# Prints: the path of the created (empty) message file.
#
# Env: COLLAB_ROOT (default: ./collab), COLLAB_LOCK_WAIT_SEC (default 60),
#      COLLAB_LOCK_WAIT_SEC (default 60). There is no automatic stale recovery:
#      a stuck lock reports who holds it and stops. See describe_lock().
set -euo pipefail

COLLAB_ROOT="${COLLAB_ROOT:-collab}"
TO="${1:?usage: next-id.sh <to> <slug> <tab>}"
SLUG="${2:?usage: next-id.sh <to> <slug> <tab>}"
TAB="${3:?usage: next-id.sh <to> <slug> <tab>  (tab is required, e.g. w3:t3)}"

# --- validate inputs: these become path components ---------------------------
# Allowlist, not a blocklist. The previous version excluded "/" and ".." but a
# glob like w*:t* still accepted "w1:t1/escape", which reached mkdir -p.
if ! [[ "$TO" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: to '$TO' must match [A-Za-z0-9._-]+" >&2; exit 2
fi
if ! [[ "$SLUG" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: slug '$SLUG' must match [A-Za-z0-9._-]+" >&2; exit 2
fi
if ! [[ "$TAB" =~ ^w[0-9]+:t[0-9]+$ ]]; then
  echo "error: tab '$TAB' must match ^w[0-9]+:t[0-9]+\$ (e.g. w3:t3)" >&2; exit 2
fi
# Absolute, so two agents in different sub-directories lock the same place.
[ -d "$COLLAB_ROOT/inbox" ] || { echo "error: $COLLAB_ROOT/inbox not found — run /collab-bus:init first" >&2; exit 1; }
COLLAB_ROOT="$(cd "$COLLAB_ROOT" && pwd -P)"

LOCK="$COLLAB_ROOT/.idlock"
OWNER_FILE="$LOCK/owner"
WAIT_SEC="${COLLAB_LOCK_WAIT_SEC:-60}"
# Identifies THIS process. Checked before releasing, so we can never remove a
# lock somebody else now holds.
TOKEN="$(hostname -s 2>/dev/null || echo host):$$:${RANDOM}${RANDOM}"
owned=0

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

release() {
  # Only the holder releases, and only if the token still matches. A process
  # that never acquired (e.g. one that timed out waiting) must not touch the
  # lock — the previous version's unconditional rmdir in an EXIT trap deleted
  # locks held by other processes.
  [ "$owned" -eq 1 ] || return 0
  [ "$(cat "$OWNER_FILE" 2>/dev/null || true)" = "$TOKEN" ] || return 0
  rm -f "$OWNER_FILE" 2>/dev/null || true
  rmdir "$LOCK" 2>/dev/null || true
}
trap release EXIT

# Automatic stale takeover was REMOVED in v0.3.2.
#
# Portable shell has no compare-and-rename on a well-known path, so any
# read-check-then-rename sequence has a generation race: the owner we inspected
# can be replaced between the check and the rename, and we would then move (and
# delete) a lock its new owner still holds. There is also a window between
# `mkdir` and writing the owner token where a reaper would see an ownerless lock
# and break a lock that is legitimately being acquired.
#
# Rather than paper over those with more shell, a stuck lock now fails loudly and
# a human decides. If automatic recovery is ever needed, it must come from a
# primitive the OS releases on process death (flock/fcntl) or from a ticket
# scheme that never reuses one pathname — not from this script.
describe_lock() {
  local owner age
  owner="$(cat "$OWNER_FILE" 2>/dev/null || true)"
  age=$(( $(date +%s) - $(mtime "$LOCK") ))
  echo "  lock:  $LOCK" >&2
  echo "  owner: ${owner:-<none recorded>}" >&2
  echo "  age:   ${age}s" >&2
  case "$owner" in
    *:*:*)
      local host pid
      host="${owner%%:*}"; pid="$(printf '%s' "$owner" | cut -d: -f2)"
      if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$host" = "$(hostname -s 2>/dev/null || echo host)" ]; then
        if kill -0 "$pid" 2>/dev/null; then
          echo "  pid $pid is ALIVE on this host — the lock is genuinely held; wait." >&2
        else
          echo "  pid $pid is not running on this host — the holder probably crashed." >&2
          echo "  If you are sure no allocator is running:  rm -rf '$LOCK'" >&2
        fi
      else
        echo "  owner is on another host or unparseable — do not guess; check the other machine." >&2
      fi
      ;;
    *) echo "  If you are sure no allocator is running:  rm -rf '$LOCK'" >&2 ;;
  esac
}

deadline=$(( $(date +%s) + WAIT_SEC ))
while :; do
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' "$TOKEN" > "$OWNER_FILE"
    owned=1
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] || {
    echo "error: timed out after ${WAIT_SEC}s waiting for the id lock." >&2
    describe_lock
    exit 1
  }
  sleep 0.3
done

MAX=$(find "$COLLAB_ROOT/inbox" -name '[0-9][0-9][0-9][0-9]-*.md' -exec basename {} \; 2>/dev/null \
      | sed 's/-.*//' | sort -n | tail -1)
MAX=${MAX:-0}
NEXT=$(( 10#$MAX + 1 ))
# The scan pattern is fixed-width, so ids past 9999 would be invisible to the
# next scan and the same path would be handed out twice. Fail loudly instead.
[ "$NEXT" -le 9999 ] || { echo "error: id space exhausted at 9999 — widen the id format" >&2; exit 1; }
ID=$(printf '%04d' "$NEXT")

DEST="$COLLAB_ROOT/inbox/to/$TO/${ID}-${TAB//:/}-${SLUG}.md"
mkdir -p "$(dirname "$DEST")"
# Exclusive create: never truncate an existing file, even if the lock was
# bypassed or a same-named file arrived via folder sync.
if ! ( set -o noclobber; : > "$DEST" ) 2>/dev/null; then
  echo "error: $DEST already exists — refusing to overwrite" >&2
  exit 1
fi
echo "$DEST"

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
#      COLLAB_LOCK_STALE_SEC (default 120)
set -euo pipefail

COLLAB_ROOT="${COLLAB_ROOT:-collab}"
TO="${1:?usage: next-id.sh <to> <slug> <tab>}"
SLUG="${2:?usage: next-id.sh <to> <slug> <tab>}"
TAB="${3:?usage: next-id.sh <to> <slug> <tab>  (tab is required, e.g. w3:t3)}"

# --- validate inputs: these become path components ---------------------------
for v in "$TO" "$SLUG"; do
  case "$v" in
    */*|*..*|"") echo "error: '$v' must not be empty or contain '/' or '..'" >&2; exit 2 ;;
  esac
done
case "$TAB" in
  w*:t*) : ;;
  *) echo "error: tab '$TAB' must look like wN:tN" >&2; exit 2 ;;
esac

# Absolute, so two agents in different sub-directories lock the same place.
[ -d "$COLLAB_ROOT/inbox" ] || { echo "error: $COLLAB_ROOT/inbox not found — run /collab-bus:init first" >&2; exit 1; }
COLLAB_ROOT="$(cd "$COLLAB_ROOT" && pwd -P)"

LOCK="$COLLAB_ROOT/.idlock"
OWNER_FILE="$LOCK/owner"
WAIT_SEC="${COLLAB_LOCK_WAIT_SEC:-60}"
STALE_SEC="${COLLAB_LOCK_STALE_SEC:-120}"
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

try_break_stale() {
  # Never rmdir the well-known path directly: another process may acquire it
  # between our check and our remove. Rename it aside (atomic) and inspect the
  # quarantined copy instead.
  local owner host pid age
  owner="$(cat "$OWNER_FILE" 2>/dev/null || true)"
  host="${owner%%:*}"; pid="$(printf '%s' "$owner" | cut -d: -f2)"
  # A malformed owner file must NOT read as "dead": kill -0 on a non-numeric
  # string fails, which would let us break a lock its owner still holds.
  case "$pid" in (*[!0-9]*|"") pid="" ;; esac
  if [ -n "$owner" ] && [ -z "$pid" ]; then
    # Owner present but unparseable — refuse to judge liveness; only the age
    # rule below may break it, and only well past the stale threshold.
    age=$(( $(date +%s) - $(mtime "$LOCK") ))
    [ "$age" -gt $(( STALE_SEC * 2 )) ] || return 1
  elif [ -n "$pid" ] && [ "$host" = "$(hostname -s 2>/dev/null || echo host)" ] \
       && kill -0 "$pid" 2>/dev/null; then
    # Same host, pid alive => genuinely held. Never break it, at any age.
    return 1
  fi
  age=$(( $(date +%s) - $(mtime "$LOCK") ))
  [ "$age" -gt "$STALE_SEC" ] || return 1
  local quar="$LOCK.stale.$TOKEN"
  mv "$LOCK" "$quar" 2>/dev/null || return 1
  rm -rf "$quar"
  echo "warn: broke stale lock (age ${age}s, owner '${owner:-unknown}')" >&2
  return 0
}

deadline=$(( $(date +%s) + WAIT_SEC ))
while :; do
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' "$TOKEN" > "$OWNER_FILE"
    owned=1
    break
  fi
  try_break_stale || true
  [ "$(date +%s)" -lt "$deadline" ] || {
    echo "error: timed out after ${WAIT_SEC}s waiting for $LOCK" >&2
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

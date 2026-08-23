#!/usr/bin/env bash
# Atomically allocate the next message id.
#
# Why this exists: the naive rule ("next id = highest NNNN + 1") is a
# read-then-write race. When two Claude+peer pairs work in the same repo at the
# same time, both read the same maximum and both write the same number. This is
# not hypothetical — it happened, producing two different messages both numbered
# 0033 in one inbox.
#
# How: mkdir is atomic on POSIX (it fails if the directory exists), so it serves
# as a mutex. Inside the lock we compute the next id and immediately create an
# empty placeholder file, then release. The placeholder is what makes the id
# taken; content is written afterwards, outside the lock.
#
# The filename also carries the sender's tab id as a second line of defence: even
# if the lock is bypassed, two writers cannot silently overwrite each other, and
# the filename shows which pair produced it.
#
# Usage:  next-id.sh <to> <slug> [tab]
#   e.g.  next-id.sh codex review-auth w3:t3
# Prints: the path of the created (empty) message file.
set -euo pipefail

COLLAB_ROOT="${COLLAB_ROOT:-collab}"
TO="${1:?usage: next-id.sh <to> <slug> [tab]}"
SLUG="${2:?usage: next-id.sh <to> <slug> [tab]}"
TAB="${3:-}"
LOCK="$COLLAB_ROOT/.idlock"
STALE_SEC="${COLLAB_LOCK_STALE_SEC:-120}"

[ -d "$COLLAB_ROOT/inbox" ] || { echo "error: $COLLAB_ROOT/inbox not found — run /collab-bus:init first" >&2; exit 1; }

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

acquire() {
  local waited=0
  until mkdir "$LOCK" 2>/dev/null; do
    if [ -d "$LOCK" ]; then
      local age=$(( $(date +%s) - $(mtime "$LOCK") ))
      if [ "$age" -gt "$STALE_SEC" ]; then
        echo "warn: clearing stale lock (${age}s old)" >&2
        rmdir "$LOCK" 2>/dev/null || true
        continue
      fi
    fi
    sleep 0.3
    waited=$((waited + 1))
    [ "$waited" -le 100 ] || { echo "error: timed out waiting for $LOCK" >&2; exit 1; }
  done
}
release() { rmdir "$LOCK" 2>/dev/null || true; }
trap release EXIT

acquire

MAX=$(find "$COLLAB_ROOT/inbox" -name '[0-9][0-9][0-9][0-9]-*.md' -exec basename {} \; 2>/dev/null \
      | sed 's/-.*//' | sort -n | tail -1)
MAX=${MAX:-0}
ID=$(printf '%04d' $(( 10#$MAX + 1 )))

SUFFIX=""
[ -n "$TAB" ] && SUFFIX="-${TAB//:/}"
DEST="$COLLAB_ROOT/inbox/to/$TO/${ID}${SUFFIX}-${SLUG}.md"

mkdir -p "$(dirname "$DEST")"
: > "$DEST"
echo "$DEST"

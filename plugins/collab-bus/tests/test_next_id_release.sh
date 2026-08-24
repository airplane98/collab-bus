#!/usr/bin/env bash
# Regression tests for next-id.sh's release() — the real function, sourced.
#
# The bug these pin down: release() must delete the owner file (it lives inside
# the lock dir) before rmdir can succeed. If rmdir then fails even once, the
# lock survives with no owner recorded — and because automatic stale takeover
# was deliberately removed, an ownerless lock is unrecoverable without a human
# and blocks every future allocation. This happened for real on 2026-08-24 and
# stalled a review round.
set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/scripts/next-id.sh"
fails=0
ok()   { echo "  ok   - $1"; }
bad()  { echo "  FAIL - $1" >&2; fails=$((fails+1)); }

# --- 1. happy path: the lock goes away ---------------------------------------
t="$(mktemp -d)"; LOCK="$t/.idlock"; TOKEN="tok-1"; owned=1
mkdir "$LOCK"; printf '%s\n' "$TOKEN" > "$LOCK/owner"
COLLAB_NEXT_ID_LIB=1 LOCK="$LOCK" TOKEN="$TOKEN" owned=1 \
  bash -c 'source "$0"; release' "$SCRIPT" 2>/dev/null
[ -d "$LOCK" ] && bad "holder released but the lock dir survived" || ok "holder release removes the lock"
rm -rf "$t"

# --- 2. a non-holder must not touch someone else's lock ----------------------
t="$(mktemp -d)"; LOCK="$t/.idlock"
mkdir "$LOCK"; printf 'somebody-else\n' > "$LOCK/owner"
COLLAB_NEXT_ID_LIB=1 LOCK="$LOCK" TOKEN="tok-mine" owned=1 \
  bash -c 'source "$0"; release' "$SCRIPT" 2>/dev/null
if [ -d "$LOCK" ] && [ "$(cat "$LOCK/owner")" = "somebody-else" ]; then
  ok "a mismatched token leaves the other holder's lock intact"
else
  bad "released a lock held by another process"
fi
rm -rf "$t"

# --- 3. THE REGRESSION: rmdir fails -> the lock must stay attributable -------
# A stray file inside the lock (sync temp file, .DS_Store) makes rmdir fail.
# Before the fix the owner file was already gone, leaving an ownerless lock.
t="$(mktemp -d)"; LOCK="$t/.idlock"; TOKEN="tok-3"
mkdir "$LOCK"; printf '%s\n' "$TOKEN" > "$LOCK/owner"; : > "$LOCK/.DS_Store"
COLLAB_NEXT_ID_LIB=1 LOCK="$LOCK" TOKEN="$TOKEN" owned=1 \
  bash -c 'source "$0"; release' "$SCRIPT" 2>/dev/null
if [ ! -d "$LOCK" ]; then
  bad "rmdir should have failed here — the test no longer exercises the bug"
elif [ "$(cat "$LOCK/owner" 2>/dev/null || true)" = "$TOKEN" ]; then
  ok "an undeletable lock keeps its owner token (stays attributable)"
else
  bad "lock survived with NO owner recorded — unrecoverable without a human"
fi
rm -rf "$t"

# --- 4. the guard itself: sourcing must not allocate or arm the EXIT trap ----
t="$(mktemp -d)"; mkdir -p "$t/collab/inbox"
out="$(cd "$t" && COLLAB_NEXT_ID_LIB=1 bash -c 'source "$0"; echo SOURCED-OK' "$SCRIPT" 2>&1)"
if [ "$out" = "SOURCED-OK" ] && [ ! -d "$t/collab/.idlock" ]; then
  ok "sourcing defines functions without allocating"
else
  bad "sourcing had side effects: $out"
fi
rm -rf "$t"

[ "$fails" -eq 0 ] && { echo "next-id release: all passed"; exit 0; }
echo "next-id release: $fails failed" >&2; exit 1

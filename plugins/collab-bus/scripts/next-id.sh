#!/usr/bin/env bash
# Allocate the destination path for a new collab-bus message.
#
# v0.5.0 — ids are ULIDs, and the lock is GONE.
#   Message ids used to be a shared monotonic counter ("highest NNNN + 1"),
#   which is a read-then-write race: two agents read the same max and write the
#   same number. Defending that counter required a mkdir mutex, owner tokens,
#   stale/ghost-lock recovery, and (v0.4.1) a /tmp lock path with symlink and
#   locale hardening — the entire history of this file was lock bugs.
#
#   A ULID needs NO coordination: 48-bit millisecond timestamp + 80 random bits,
#   Crockford base32, 26 chars. Two agents — even on two machines behind a
#   synced folder — generate independently with a negligible collision
#   probability: 80 random bits per timestamp bucket (normally 1 ms; the
#   last-resort seconds fallback in now_ms coarsens the bucket to 1 s, which
#   raises the ~n²/2⁸¹ birthday odds but leaves them negligible at expected
#   message volumes), because there is no shared mutable state to race on.
#   So the lock is deleted
#   outright. Ids stay sortable (the timestamp is the high-order prefix) and
#   human-readable (the tab + slug still follow in the filename).
#
# Usage:  next-id.sh <to> <slug> <tab>
#   e.g.  next-id.sh codex review-auth w3:t3
# Prints: the path of the created (empty) message file.
#
# Env: COLLAB_ROOT (default: ./collab).
#      Sourcing with COLLAB_NEXT_ID_LIB=1 defines the id functions WITHOUT
#      allocating, so tests can exercise ulid()/b32() directly.
set -euo pipefail

CROCK='0123456789ABCDEFGHJKMNPQRSTVWXYZ'   # Crockford base32 (excludes I L O U)

# Encode a non-negative integer that fits in signed 64-bit shell arithmetic into
# exactly <width> Crockford base32 chars, most-significant first, zero-padded.
b32() { # <value> <width>
  local v="$1" width="$2" out='' i
  for (( i=0; i<width; i++ )); do
    out="${CROCK:$((v % 32)):1}$out"
    v=$((v / 32))
  done
  printf '%s' "$out"
}

# Milliseconds since the epoch, best-effort and portable. GNU date has %N;
# BSD/macOS date does not (it echoes a literal N), so fall back to perl, then to
# whole-second precision. Coarser precision enlarges the timestamp bucket:
# same-second ids share one timestamp and sort by their random tail, and the
# birthday odds within that larger bucket rise accordingly — still negligible at
# expected message volumes, but not literally "no effect".
now_ms() {
  local d
  d="$(date +%s%3N 2>/dev/null || true)"
  case "$d" in
    ''|*[!0-9]*) : ;;                      # empty, or contains the literal N
    *) printf '%s' "$d"; return ;;
  esac
  if command -v perl >/dev/null 2>&1 \
     && d="$(perl -MTime::HiRes=time -e 'printf("%d", time()*1000)' 2>/dev/null)" \
     && [ -n "$d" ]; then
    printf '%s' "$d"; return
  fi
  printf '%s' "$(( $(date +%s) * 1000 ))"
}

ulid() {
  local ms ts a b c d e r0 r1
  ms="$(now_ms)"
  ts="$(b32 "$ms" 10)"                     # 48-bit time -> 10 chars (covers 50 bits)
  # 80 random bits -> 16 chars, in two 40-bit halves (each fits 64-bit arithmetic).
  read -r a b c d e < <(od -An -tu1 -N5 /dev/urandom)
  r0=$(( a*2**32 + b*2**24 + c*2**16 + d*2**8 + e ))
  read -r a b c d e < <(od -An -tu1 -N5 /dev/urandom)
  r1=$(( a*2**32 + b*2**24 + c*2**16 + d*2**8 + e ))
  printf '%s%s%s' "$ts" "$(b32 "$r0" 8)" "$(b32 "$r1" 8)"
}

if [ "${COLLAB_NEXT_ID_LIB:-}" = 1 ]; then
  return 0 2>/dev/null || exit 0
fi

COLLAB_ROOT="${COLLAB_ROOT:-collab}"
TO="${1:?usage: next-id.sh <to> <slug> <tab>}"
SLUG="${2:?usage: next-id.sh <to> <slug> <tab>}"
TAB="${3:?usage: next-id.sh <to> <slug> <tab>  (tab is required, e.g. w3:t3)}"

# --- validate inputs: these become path components ---------------------------
# Allowlist, not a blocklist. The first character must be alphanumeric so TO=".."
# cannot land the message in inbox/ instead of inbox/to/<recipient>/.
if ! [[ "$TO" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "error: to '$TO' must start with a letter or digit and match [A-Za-z0-9._-]*" >&2; exit 2
fi
if ! [[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "error: slug '$SLUG' must start with a letter or digit and match [A-Za-z0-9._-]*" >&2; exit 2
fi
if ! [[ "$TAB" =~ ^w[0-9]+:t[0-9]+$ ]]; then
  echo "error: tab '$TAB' must match ^w[0-9]+:t[0-9]+\$ (e.g. w3:t3)" >&2; exit 2
fi
[ -d "$COLLAB_ROOT/inbox" ] || { echo "error: $COLLAB_ROOT/inbox not found — run /collab-bus:init first" >&2; exit 1; }
COLLAB_ROOT="$(cd "$COLLAB_ROOT" && pwd -P)"

ID="$(ulid)"
DEST="$COLLAB_ROOT/inbox/to/$TO/${ID}-${TAB//:/}-${SLUG}.md"
mkdir -p "$(dirname "$DEST")"
# Exclusive create: a ULID collision has negligible probability, but never
# truncate an existing file — defense in depth WITHIN this filesystem view (it
# cannot make a cross-machine synced create atomic), and it catches a same-named
# file that arrived via folder sync.
if ! ( set -o noclobber; : > "$DEST" ) 2>/dev/null; then
  echo "error: $DEST already exists — refusing to overwrite" >&2
  exit 1
fi
echo "$DEST"

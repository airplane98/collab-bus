#!/usr/bin/env bash
# Tests for next-id.sh. The ULID rewrite (v0.5) deleted the whole lock apparatus;
# v0.6 makes the allocator hand back a DRAFT (`.<ULID>-<tab>-<slug>.md.part`)
# rather than the final message. What has to hold: ids are well-formed ULIDs,
# unique, time-ordered, collision-resistant under concurrency WITHOUT any lock,
# input validation still guards the path components, and exclusive-create still
# refuses to clobber a draft. (The draft->final publish is test_publish.sh.)
set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/scripts/next-id.sh"
CROCK='0123456789ABCDEFGHJKMNPQRSTVWXYZ'
fails=0
ok()  { echo "  ok   - $1"; }
bad() { echo "  FAIL - $1" >&2; fails=$((fails+1)); }

# idof() extracts the ULID from a draft (or final) path's basename: drop the
# leading dot the draft carries, then take everything before the first '-'.
idof() { local b; b="$(basename "$1")"; b="${b#.}"; printf '%s' "${b%%-*}"; }

newroot() { local t; t="$(mktemp -d)"; mkdir -p "$t/collab/inbox"; printf '%s' "$t"; }

# --- 1. format: draft path + 26 Crockford chars ------------------------------
t="$(newroot)"
dest="$(cd "$t" && bash "$SCRIPT" codex fmt w1:t1)"
id="$(idof "$dest")"; dbase="$(basename "$dest")"
if [ "${#id}" = 26 ] && [ -z "${id//[$CROCK]/}" ] && [[ "${id:0:1}" =~ [0-7] ]] \
   && [[ "$dbase" == .*.md.part ]] && [ -f "$dest" ]; then
  ok "allocator returns a .md.part draft with a 26-char Crockford id, first in [0-7] ($id)"
else
  bad "malformed draft/id: '$dbase' id='$id' (len ${#id})"
fi
rm -rf "$t"

# --- 2. uniqueness of two sequential ids -------------------------------------
t="$(newroot)"
a="$(idof "$(cd "$t" && bash "$SCRIPT" codex u1 w1:t1)")"
b="$(idof "$(cd "$t" && bash "$SCRIPT" codex u2 w1:t1)")"
[ "$a" != "$b" ] && ok "two sequential ids differ" || bad "two ids identical: $a"
rm -rf "$t"

# --- 3. deterministic timestamp encoding + ordering (NOT the wall clock) ------
# Do not test ordering against the real clock: NTP steps, manual changes, and VM
# resume can move it backwards, so "later call => larger prefix" is not actually
# guaranteed. Pin two known timestamps instead and assert b32 encodes them
# correctly AND order-preservingly (larger ms -> lexicographically larger).
enc() { COLLAB_NEXT_ID_LIB=1 bash -c 'source "$0"; b32 "$1" 10' "$SCRIPT" "$1"; }
e1="$(enc 1700000000000)"; e2="$(enc 1700000000001)"
if [ "${#e1}" = 10 ] && [ "${#e2}" = 10 ] && [[ "$e1" < "$e2" ]]; then
  ok "known timestamps encode order-preservingly ($e1 < $e2)"
else
  bad "timestamp encoding/order wrong: '$e1' vs '$e2'"
fi

# --- 4. bulk uniqueness: 200 ids, no duplicates ------------------------------
t="$(newroot)"
for i in $(seq 1 200); do (cd "$t" && bash "$SCRIPT" codex "bulk$i" w1:t1 >/dev/null); done
# Drafts are dotfiles, so list with -A. Distinctness of the leading token still
# holds (the leading dot is uniform, so it never merges two distinct ULIDs).
n="$(ls -A "$t/collab/inbox/to/codex" | sed 's/-.*//' | sort | wc -l | tr -d ' ')"
u="$(ls -A "$t/collab/inbox/to/codex" | sed 's/-.*//' | sort -u | wc -l | tr -d ' ')"
[ "$n" = 200 ] && [ "$u" = 200 ] && ok "200 ids are all distinct" || bad "bulk collision (n=$n unique=$u)"
rm -rf "$t"

# --- 5. concurrency WITHOUT a lock: parallel allocations stay distinct --------
# The point of the rewrite: no shared mutable state, so no lock is needed;
# concurrent callers collide only with negligible probability. 24 over 3 waves.
t="$(newroot)"
for wave in 1 2 3; do
  pids=()
  for i in $(seq 1 8); do
    ( cd "$t" && bash "$SCRIPT" codex "c$wave-$i" w1:t1 >/dev/null 2>&1 ) & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
done
n="$(ls -A "$t/collab/inbox/to/codex" | sed 's/-.*//' | wc -l | tr -d ' ')"
u="$(ls -A "$t/collab/inbox/to/codex" | sed 's/-.*//' | sort -u | wc -l | tr -d ' ')"
[ "$n" = 24 ] && [ "$u" = 24 ] && ok "24 concurrent lock-free allocations are all distinct" || bad "concurrent collision (n=$n unique=$u)"
rm -rf "$t"

# --- 6. input validation still rejects bad path components -------------------
t="$(newroot)"
rc_all=0
for args in ".. slug w1:t1" "codex .. w1:t1" "codex slug not-a-tab" "codex/esc slug w1:t1"; do
  # shellcheck disable=SC2086
  ( cd "$t" && bash "$SCRIPT" $args >/dev/null 2>&1 ) && rc_all=1
done
[ "$rc_all" = 0 ] && ok "invalid to/slug/tab are all rejected" || bad "a malformed argument was accepted"
rm -rf "$t"

# --- 7. exclusive-create WIRING: a forced ULID collision is refused ----------
# Pin date + od via a PATH stub so the allocator mints the SAME ulid twice; the
# second run must hit next-id.sh's own noclobber. This exercises the real create
# path — unlike a proxy that tests bash's noclobber in isolation and would still
# pass if the guard were deleted from the script.
t="$(newroot)"; stub="$(mktemp -d)"
cat >"$stub/date" <<'DATE'
#!/usr/bin/env bash
printf '1700000000000'
DATE
cat >"$stub/od" <<'OD'
#!/usr/bin/env bash
printf '  0 0 0 0 0\n'
OD
chmod +x "$stub/date" "$stub/od"
d1="$(cd "$t" && PATH="$stub:$PATH" bash "$SCRIPT" codex clob w1:t1)"; rc1=$?
out2="$(cd "$t" && PATH="$stub:$PATH" bash "$SCRIPT" codex clob w1:t1 2>&1)"; rc2=$?
id1="$(idof "$d1")"
# date=1700000000000, od all-zero => randomness tail is 16 zeros: also verifies
# the two-halves entropy assembly lands where expected.
if [ "$rc1" = 0 ] && [ "$rc2" != 0 ] && printf '%s' "$out2" | grep -q "already exists" \
   && [ "${id1:10}" = "0000000000000000" ]; then
  ok "a forced ULID collision is refused by exclusive create (id=$id1)"
else
  bad "exclusive-create wiring not exercised (rc1=$rc1 rc2=$rc2 id=$id1)"
fi
rm -rf "$t" "$stub"

# --- 8. lib mode defines ulid() without allocating ---------------------------
t="$(newroot)"
out="$(cd "$t" && COLLAB_NEXT_ID_LIB=1 bash -c 'source "$0"; id="$(ulid)"; echo "${#id}:$id"' "$SCRIPT" 2>&1)"
len="${out%%:*}"; val="${out#*:}"
if [ "$len" = 26 ] && [ -z "${val//[$CROCK]/}" ] && [ ! -e "$t/collab/inbox/to" ]; then
  ok "sourcing exposes ulid() and allocates nothing"
else
  bad "lib mode misbehaved: $out"
fi
rm -rf "$t"

# --- 9. b32 boundary vectors: deterministic encoder check --------------------
# Sampling (cases 4/5) catches a stuck-output bug but never the encoder edges.
b32of() { COLLAB_NEXT_ID_LIB=1 bash -c 'source "$0"; b32 "$1" "$2"' "$SCRIPT" "$1" "$2"; }
b9=0
vec() { local g; g="$(b32of "$1" "$2")"; [ "$g" = "$3" ] || { echo "      b32($1,$2)=$g want $3" >&2; b9=1; }; }
vec 0 8 "00000000"
vec 31 8 "0000000Z"                 # last Crockford char
vec 32 8 "00000010"                 # carry into the next position
vec 1099511627775 8 "ZZZZZZZZ"      # 2^40-1: full 40-bit half
vec 281474976710655 10 "7ZZZZZZZZZ" # 2^48-1: full 48-bit timestamp
[ "$b9" = 0 ] && ok "b32 boundary vectors all correct" || bad "b32 boundary vector mismatch"

# --- 10. now_ms tolerates BSD date (literal N) without leaking it -------------
# GNU date has %N; BSD/macOS echoes a literal "N". now_ms must fall through
# (to perl or whole seconds) and never return a value containing that N.
stub="$(mktemp -d)"
cat >"$stub/date" <<'DATE'
#!/usr/bin/env bash
case "$*" in
  *%3N*) printf '1700000000N' ;;   # BSD: %N unsupported -> trailing literal N
  *)     printf '1700000000'  ;;   # plain %s
esac
DATE
chmod +x "$stub/date"
ms="$(PATH="$stub:$PATH" COLLAB_NEXT_ID_LIB=1 bash -c 'source "$0"; now_ms' "$SCRIPT")"
if [ -n "$ms" ] && [ -z "${ms//[0-9]/}" ]; then
  ok "now_ms returns pure digits under BSD-style date, perl path ($ms)"
else
  bad "now_ms leaked a non-digit on the BSD path: '$ms'"
fi

# --- 11. deterministic seconds fallback: BSD date AND no usable perl ----------
# With %N unsupported and perl failing, now_ms must use `date +%s` * 1000. Both
# stubbed, so the expected value is exact — the last fallback branch verified
# without depending on the host clock.
cat >"$stub/perl" <<'PERL'
#!/usr/bin/env bash
exit 1
PERL
chmod +x "$stub/perl"
ms2="$(PATH="$stub:$PATH" COLLAB_NEXT_ID_LIB=1 bash -c 'source "$0"; now_ms' "$SCRIPT")"
[ "$ms2" = "1700000000000" ] && ok "now_ms seconds-fallback is exact when perl is unusable ($ms2)" \
                             || bad "seconds fallback wrong: '$ms2' (want 1700000000000)"
rm -rf "$stub"

[ "$fails" -eq 0 ] && { echo "next-id: all passed"; exit 0; }
echo "next-id: $fails failed" >&2; exit 1

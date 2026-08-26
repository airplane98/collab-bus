#!/usr/bin/env bash
# Tests for participant.sh (v0.8 step 3): logical identity vs live binding.
#
# The property under test is the one the whole split exists for: a message addressed to a
# participant stays claimable when the process holding that participant moves pane, gets
# renamed, or restarts. Transport coordinates may churn; the address may not.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
P="$DIR/scripts/participant.sh"
fails=0
ok()  { echo "  ok   - $1"; }
bad() { echo "  FAIL - $1" >&2; fails=$((fails+1)); }
ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$ROOT"' EXIT

# A herdr stub whose answers come from files, so a test can move the pane or end a
# session between calls — the real thing is not available in CI and we must not depend on
# whatever pane happens to be running here.
STUB="$ROOT/bin"; mkdir -p "$STUB"
cat > "$STUB/herdr" <<'EOF'
#!/usr/bin/env bash
S="${HERDR_STATE:?}"
case "$1 $2" in
  "pane current")
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","agent_session":{"value":"%s"}}}}\n' \
      "$(cat "$S/pane")" "$(cat "$S/tab")" "$(cat "$S/session")" ;;
  "agent list")
    printf '{"result":{"agents":['
    sep=""
    while IFS= read -r s; do [ -n "$s" ] || continue; printf '%s{"agent_session":{"value":"%s"}}' "$sep" "$s"; sep=","; done < "$S/live"
    printf ']}}\n' ;;
esac
EOF
chmod +x "$STUB/herdr"
export PATH="$STUB:$PATH"

newproj() {                 # a project with collab/ and a fresh herdr state
  local t; t="$(mktemp -d "$ROOT/proj.XXXXXX")"; mkdir -p "$t/collab" "$t/state"
  printf 'w3:pD\n' > "$t/state/pane"; printf 'w3:t6\n' > "$t/state/tab"
  printf 'sess-A\n' > "$t/state/session"; printf 'sess-A\n' > "$t/state/live"
  printf '%s' "$t"
}
run() { ( cd "$1" && HERDR_STATE="$1/state" bash "$P" "${@:2}" ); }

# --- 1. register is idempotent and no-replace -------------------------------
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
before="$(cksum < "$t/collab/participants/codex-primary.json")"
out="$(run "$t" register codex-primary --kind codex 2>&1)"; rc=$?
after="$(cksum < "$t/collab/participants/codex-primary.json")"
{ [ "$rc" = 0 ] && [ "$before" = "$after" ] && printf '%s' "$out" | grep -q "already registered"; } \
  && ok "re-registering the same id is a no-op, and the identity file is untouched" \
  || bad "register not idempotent (rc=$rc)"

# --- 2. an identity is immutable: the same id cannot change kind ------------
out="$(run "$t" register codex-primary --kind gemini 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "immutable"; } \
  && ok "an existing id cannot be re-registered under a different kind" \
  || bad "identity kind was mutable (rc=$rc)"

# --- 3. bind records the LIVE coordinates, identity stays byte-identical ----
idbefore="$(cksum < "$t/collab/participants/codex-primary.json")"
run "$t" bind codex-primary >/dev/null 2>&1
idafter="$(cksum < "$t/collab/participants/codex-primary.json")"
b="$t/collab/bindings/codex-primary.json"
{ [ -f "$b" ] && grep -q '"pane_id": "w3:pD"' "$b" && [ "$idbefore" = "$idafter" ]; } \
  && ok "bind writes the binding and never touches the identity" \
  || bad "bind wrong"

# --- 4. ensure is a NO-OP when nothing changed ------------------------------
# It runs at turn start, so it must not rewrite a file every round just to say the same
# thing — and it must never take over silently.
bbefore="$(cksum < "$b")"
out="$(run "$t" ensure codex-primary 2>&1)"; rc=$?
bafter="$(cksum < "$b")"
{ [ "$rc" = 0 ] && [ "$bbefore" = "$bafter" ] && printf '%s' "$out" | grep -q "already current"; } \
  && ok "ensure does not rewrite an unchanged binding" \
  || bad "ensure rewrote an unchanged binding (rc=$rc)"

# --- 5. moving the pane keeps the logical id and refreshes the binding ------
printf 'w3:pZ\n' > "$t/state/pane"; printf 'w9:t9\n' > "$t/state/tab"
out="$(run "$t" ensure codex-primary 2>&1)"; rc=$?
idnow="$(cksum < "$t/collab/participants/codex-primary.json")"
{ [ "$rc" = 0 ] && grep -q '"pane_id": "w3:pZ"' "$b" && grep -q '"tab_id": "w9:t9"' "$b" \
  && [ "$idnow" = "$idbefore" ]; } \
  && ok "a pane move refreshes coordinates and leaves the identity unchanged" \
  || bad "pane move mishandled (rc=$rc)"

# --- 6. THE RESTART ORACLE --------------------------------------------------
# A message addressed to the participant BEFORE the restart must still be claimable
# after it: that is the property `<kind>-<tab>` could not provide.
msgdir="$t/collab/inbox/to/codex"; mkdir -p "$msgdir"
printf -- '---\nto_agent: codex-primary\n---\nwork\n' > "$msgdir/pre-restart.md"
idpre="$(cksum < "$t/collab/participants/codex-primary.json")"
printf 'sess-B\n' > "$t/state/session"      # the process restarted: brand-new session
printf 'sess-B\n' > "$t/state/live"         # and the old session is gone
out="$(run "$t" bind codex-primary 2>&1)"; rc=$?
idpost="$(cksum < "$t/collab/participants/codex-primary.json")"
claim="$(grep -l 'to_agent: codex-primary' "$msgdir"/*.md 2>/dev/null | head -1)"
{ [ "$rc" = 0 ] && grep -q '"agent_session": "sess-B"' "$b" \
  && [ "$idpre" = "$idpost" ] && [ -n "$claim" ]; } \
  && ok "after a restart the id is unchanged and a pre-restart message is still claimable" \
  || bad "restart oracle failed (rc=$rc claim='$claim')"

# --- 7. a stale binding re-binds without ceremony ---------------------------
# The previous holder's session is no longer live, so there is nobody to take it from.
printf 'sess-C\n' > "$t/state/session"; printf 'sess-C\n' > "$t/state/live"
out="$(run "$t" bind codex-primary 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -q '"agent_session": "sess-C"' "$b"; } \
  && ok "a binding whose holder is gone is re-bound without --takeover" \
  || bad "stale re-bind refused (rc=$rc)"

# --- 8. a LIVE holder is never taken silently -------------------------------
# Two processes answering as one endpoint is how a message gets handled twice.
printf 'sess-D\n' > "$t/state/session"
printf 'sess-C\nsess-D\n' > "$t/state/live"        # the old holder is STILL running
bbefore="$(cksum < "$b")"
out="$(run "$t" bind codex-primary 2>&1)"; rc=$?
bafter="$(cksum < "$b")"
{ [ "$rc" != 0 ] && [ "$bbefore" = "$bafter" ] && printf '%s' "$out" | grep -q "takeover"; } \
  && ok "binding over a live holder is refused and the binding is untouched" \
  || bad "silently stole a live binding (rc=$rc)"

# --- 9. --takeover is explicit, and only on bind ----------------------------
out="$(run "$t" bind codex-primary --takeover 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && grep -q '"agent_session": "sess-D"' "$b"; } \
  && ok "--takeover claims a live binding explicitly" || bad "takeover failed (rc=$rc)"
out="$(run "$t" ensure codex-primary --takeover 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "only valid for bind"; } \
  && ok "ensure refuses --takeover (it must never take over on its own)" \
  || bad "ensure accepted --takeover (rc=$rc)"

# --- 10. binding an unregistered id is refused ------------------------------
out="$(run "$t" bind never-registered 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "not registered"; } \
  && ok "binding an id that was never registered is refused" \
  || bad "bound an unregistered id (rc=$rc)"

# --- 11. concurrent registration of one id: exactly one winner -------------
# One artifact per participant, created no-replace, so racing initiators cannot lose an
# update the way a single shared registry file would.
t2="$(newproj)"
o1="$t2/o1"; o2="$t2/o2"
( run "$t2" register shared-id --kind codex > "$o1" 2>&1 ) & p1=$!
( run "$t2" register shared-id --kind codex > "$o2" 2>&1 ) & p2=$!
rc1=0; wait "$p1" || rc1=$?
rc2=0; wait "$p2" || rc2=$?
n="$(ls "$t2/collab/participants" | wc -l | tr -d ' ')"
wins="$(cat "$o1" "$o2" | grep -c '^registered ' || true)"
{ [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$n" = 1 ] && [ "$wins" = 1 ]; } \
  && ok "two concurrent registrations produce exactly one identity and one winner" \
  || bad "concurrent register (rc=$rc1/$rc2 files=$n winners=$wins)"

# --- 12. a corrupt identity or binding fails loud, and NUL is caught --------
t3="$(newproj)"
run "$t3" register codex-primary --kind codex >/dev/null 2>&1
printf 'not json\n' > "$t3/collab/participants/codex-primary.json"
out="$(run "$t3" bind codex-primary 2>&1)"; rc1=$?
run "$t3" register nul-test --kind codex >/dev/null 2>&1
printf '{\000\n' > "$t3/collab/participants/nul-test.json"
out2="$(run "$t3" bind nul-test 2>&1)"; rc2=$?
{ [ "$rc1" != 0 ] && [ "$rc2" != 0 ] && printf '%s' "$out2" | grep -q "NUL"; } \
  && ok "a corrupt identity is refused, and a NUL byte is named specifically" \
  || bad "corrupt identity accepted (rc=$rc1/$rc2)"

# --- 13. an alias needing JSON escaping round-trips ------------------------
t4="$(newproj)"
run "$t4" register q-test --kind codex --alias 'say "hi" \ ok' >/dev/null 2>&1
out="$(run "$t4" show q-test 2>&1)"
printf '%s' "$out" | grep -qF 'say "hi" \ ok' \
  && ok "an alias with quotes and a backslash round-trips through the file" \
  || bad "alias escaping wrong: $out"

# --- 14. herdr being unavailable fails loud, it does not guess -------------
t5="$(newproj)"
run "$t5" register codex-primary --kind codex >/dev/null 2>&1
empty="$ROOT/empty"; mkdir -p "$empty"
out="$( cd "$t5" && HERDR_STATE="$t5/state" PATH="$empty:/usr/bin:/bin" bash "$P" bind codex-primary 2>&1 )"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -qi "herdr"; } \
  && ok "with no herdr available, bind refuses rather than inventing coordinates" \
  || bad "bind proceeded without herdr (rc=$rc)"

# --- 15. a herdr outage must NOT read as a stale binding -------------------
# THE fail-open this closes: "the list says it is gone" and "the list could not be read"
# used to be one nonzero, so a restarting server looked exactly like a finished agent.
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
run "$t" bind codex-primary >/dev/null 2>&1
b="$t/collab/bindings/codex-primary.json"
before="$(cksum < "$b")"
broken="$ROOT/brokenherdr"; mkdir -p "$broken"
cat > "$broken/herdr" <<'EOF'
#!/usr/bin/env bash
S="${HERDR_STATE:?}"
case "$1 $2" in
  "pane current") printf '{"result":{"pane":{"pane_id":"w3:pD","tab_id":"w3:t6","agent_session":{"value":"sess-B"}}}}\n' ;;
  "agent list")   exit 7 ;;          # the server is restarting: cannot answer
esac
EOF
chmod +x "$broken/herdr"
out="$( cd "$t" && HERDR_STATE="$t/state" PATH="$broken:$PATH" bash "$P" bind codex-primary 2>&1 )"; rc=$?
after="$(cksum < "$b")"
{ [ "$rc" != 0 ] && [ "$before" = "$after" ] && printf '%s' "$out" | grep -qi "cannot determine"; } \
  && ok "an unreadable agent list is treated as unknown, not stale (binding untouched)" \
  || bad "herdr outage read as stale (rc=$rc)"
out="$( cd "$t" && HERDR_STATE="$t/state" PATH="$broken:$PATH" bash "$P" bind codex-primary --takeover 2>&1 )"; rc=$?
{ [ "$rc" = 0 ] && grep -q '"claim_mode": "takeover"' "$b"; } \
  && ok "--takeover is the explicit escape hatch when liveness is unknown" \
  || bad "unknown-liveness takeover failed (rc=$rc)"

# --- 16. a takeover is RECORDED in the binding, not just printed -----------
# §3 says an explicit takeover "is recorded in the new binding": after the fact you must
# be able to tell a confirmed-stale rebind from an operator-forced one.
grep -q '"claimed_from": "sess-A"' "$b" \
  && ok "the binding records which session was taken over" \
  || bad "takeover audit missing: $(grep claimed_from "$b" 2>&1)"
# and a same-session pane refresh must PRESERVE that audit rather than wash it away
printf 'w3:pQ\n' > "$t/state/pane"; printf 'sess-B\n' > "$t/state/session"; printf 'sess-B\n' > "$t/state/live"
run "$t" ensure codex-primary >/dev/null 2>&1
{ grep -q '"claim_mode": "takeover"' "$b" && grep -q '"pane_id": "w3:pQ"' "$b"; } \
  && ok "a pane refresh by the same session keeps the takeover record" \
  || bad "pane refresh erased the claim audit"

# --- 17. artifact content must match the id and the filename ---------------
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
sed -i.bak 's/"id": "codex-primary"/"id": "other-id"/' "$t/collab/participants/codex-primary.json"
rm -f "$t/collab/participants/codex-primary.json.bak"
out="$(run "$t" bind codex-primary 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ ! -e "$t/collab/bindings/codex-primary.json" ]; } \
  && ok "an identity whose id disagrees with its filename cannot be bound" \
  || bad "id/filename mismatch accepted (rc=$rc)"

# --- 18. a newer reader_schema is not canonicalized backwards --------------
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
run "$t" bind codex-primary >/dev/null 2>&1
b="$t/collab/bindings/codex-primary.json"
sed -i.bak 's/"reader_schema": 2/"reader_schema": 3/' "$b"; rm -f "$b.bak"
before="$(cksum < "$b")"
out="$(run "$t" ensure codex-primary 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ "$before" = "$(cksum < "$b")" ]; } \
  && ok "a binding claiming a newer reader_schema is left alone" \
  || bad "reader_schema downgraded (rc=$rc)"

# --- 19. symlinked registry dirs and artifacts are refused -----------------
t="$(newproj)"; outside="$ROOT/outside.$$"; mkdir -p "$outside"
ln -s "$outside" "$t/collab/participants"
out="$(run "$t" register escaped --kind codex 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ -z "$(ls -A "$outside")" ]; } \
  && ok "a symlinked participants/ is refused and the external target stays empty" \
  || bad "wrote through a symlinked registry (rc=$rc, outside: $(ls -A "$outside"))"

# --- 20. concurrent claims of one identity: exactly one winner -------------
# The approved contract's condition 1. Without serialization both processes observe the
# binding absent, both pass the liveness check, and both are told they hold it.
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
slow="$ROOT/slowclaim.$$"; mkdir -p "$slow"
cat > "$slow/herdr" <<'EOF'
#!/usr/bin/env bash
S="${HERDR_STATE:?}"
case "$1 $2" in
  "pane current") sleep 1
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w3:t6","agent_session":{"value":"%s"}}}}\n' \
      "$(cat "$S/pane")" "$(cat "$MY_SESSION_FILE")" ;;
  "agent list") printf '{"result":{"agents":[{"agent_session":{"value":"sess-A"}},{"agent_session":{"value":"sess-B"}}]}}\n' ;;
esac
EOF
chmod +x "$slow/herdr"
printf 'sess-A\n' > "$t/state/sA"; printf 'sess-B\n' > "$t/state/sB"
o1="$t/c1"; o2="$t/c2"
( cd "$t" && HERDR_STATE="$t/state" MY_SESSION_FILE="$t/state/sA" PATH="$slow:$PATH" bash "$P" bind codex-primary > "$o1" 2>&1 ) & q1=$!
( cd "$t" && HERDR_STATE="$t/state" MY_SESSION_FILE="$t/state/sB" PATH="$slow:$PATH" bash "$P" bind codex-primary > "$o2" 2>&1 ) & q2=$!
rc1=0; wait "$q1" || rc1=$?
rc2=0; wait "$q2" || rc2=$?
wins=0; [ "$rc1" = 0 ] && wins=$((wins+1)); [ "$rc2" = 0 ] && wins=$((wins+1))
{ [ "$wins" = 1 ] && grep -q '"claim_mode"' "$t/collab/bindings/codex-primary.json"; } \
  && ok "two overlapping claims of one identity produce exactly one winner" \
  || bad "claim not serialized (rc1=$rc1 rc2=$rc2 winners=$wins)"

# --- 21. show reports unknown liveness, and fails on a corrupt registry ----
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
run "$t" bind codex-primary >/dev/null 2>&1
out="$( cd "$t" && HERDR_STATE="$t/state" PATH="$broken:$PATH" bash "$P" show codex-primary 2>&1 )"
printf '%s' "$out" | grep -q "live=unknown" \
  && ok "show reports live=unknown when herdr cannot answer" \
  || bad "show claimed a liveness it does not know: $out"
printf 'garbage\n' > "$t/collab/participants/broken.json"
out="$(run "$t" show 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "codex-primary"; } \
  && ok "show lists the healthy entries but exits nonzero on a corrupt registry" \
  || bad "corrupt registry reported as healthy (rc=$rc)"

# --- 22. a waiter that is killed must NOT delete the holder's lock ---------
# The path was stored in CLAIM_LOCK before the lock was acquired and removed by an
# unconditional EXIT trap, so interrupting a waiter deleted a lock a live holder was
# still inside — worse than no lock at all.
t="$(newproj)"; LB="$ROOT/locks.$$"; mkdir -p "$LB"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
key="$(printf '%s\0%s' "$(cd "$t/collab" && pwd -P)" codex-primary | cksum | tr -d ' \n')"
lockd="$LB/claim-$key.d"; mkdir -p "$lockd"; lock="$lockd/g0"
printf '%s:%s:1\n' "$(hostname -s)" "$$" > "$lock"        # a LIVE holder (our own pid)
# `exec`, so the background job IS participant.sh: without it the TERM lands on the
# subshell and the real waiter keeps running, and the test measures too early.
( cd "$t" && exec env HERDR_STATE="$t/state" COLLAB_LOCK_BASE="$LB" bash "$P" bind codex-primary >/dev/null 2>&1 ) &
w=$!
sleep 1; kill -TERM "$w" 2>/dev/null; wait "$w" 2>/dev/null || true
wrc=0; wait "$w" 2>/dev/null || wrc=$?
strays="$(ls "$LB"/.claim.* 2>/dev/null | wc -l | tr -d ' ')"
# rc must be the signal status, not a 10-second timeout: a handler that only cleans up and
# returns lets the interrupted run continue into its critical section.
{ [ -f "$lock" ] && [ "$strays" = 0 ] && [ "$wrc" = 143 ]; } \
  && ok "a TERMed waiter exits with the signal status, keeps the holder's lock, leaves no litter" \
  || bad "waiter signal handling wrong (lock: $([ -f "$lock" ] && echo yes || echo NO), strays=$strays, rc=$wrc)"

# --- 23. a generation left by a dead local holder is SUPERSEDED ------------
# Moving the lock out of the synced tree fixed resurrection, not a local crash ghost:
# every later claim, --takeover included, could only time out forever. The fix must not be
# "delete the ghost and re-create it" — the next claimant takes the NEXT generation, and
# the dead one is only removed by the process that already holds a higher one.
dead=999999; while kill -0 "$dead" 2>/dev/null; do dead=$((dead+1)); done
printf '%s:%s:1\n' "$(hostname -s)" "$dead" > "$lock"
out="$( cd "$t" && HERDR_STATE="$t/state" COLLAB_LOCK_BASE="$LB" bash "$P" bind codex-primary 2>&1 )"; rc=$?
# g1 is a DIFFERENT pathname from the one a stalled actor could still be about to remove,
# and it is left `released` rather than unlinked so the newest generation cannot go
# backwards and hand two claimants the same next name.
{ [ "$rc" = 0 ] && [ ! -e "$lockd/g0" ] && [ "$(cat "$lockd/g1" 2>/dev/null)" = released ]; } \
  && ok "a dead holder's generation is superseded, not deleted and re-created" \
  || bad "dead-holder generation mishandled (rc=$rc, dir: $(ls "$lockd" 2>/dev/null | tr '\n' ' '))"

# --- 24. a malformed-but-rc-0 agent list is unknown, not absent ------------
# `{"result":{"agents":BROKEN}}` contains the substring "agents"; a substring is not a shape.
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
run "$t" bind codex-primary >/dev/null 2>&1
b="$t/collab/bindings/codex-primary.json"
before="$(cksum < "$b")"
mal="$ROOT/malformed.$$"; mkdir -p "$mal"
cat > "$mal/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pane current") printf '{"result":{"pane":{"pane_id":"w3:pD","tab_id":"w3:t6","agent_session":{"value":"sess-B"}}}}\n' ;;
  "agent list")   printf '{"result":{"agents":BROKEN}}\n' ;;    # rc=0, not an array
esac
EOF
chmod +x "$mal/herdr"
out="$( cd "$t" && HERDR_STATE="$t/state" PATH="$mal:$PATH" bash "$P" bind codex-primary 2>&1 )"; rc=$?
{ [ "$rc" != 0 ] && [ "$before" = "$(cksum < "$b")" ]; } \
  && ok "an rc=0 but unparseable agent list is unknown, and the binding is untouched" \
  || bad "malformed list read as absent (rc=$rc)"

# --- 25. the id invariant holds at EVERY entry point ----------------------
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
sed -i.bak 's/"id": "codex-primary"/"id": "other-id"/' "$t/collab/participants/codex-primary.json"
rm -f "$t/collab/participants/codex-primary.json.bak"
r25=0
for sub in "register codex-primary --kind codex" "show codex-primary" "bind codex-primary" "ensure codex-primary"; do
  # shellcheck disable=SC2086
  out="$(run "$t" $sub 2>&1)"; rc=$?
  [ "$rc" != 0 ] || { echo "        '$sub' accepted a mismatched identity" >&2; r25=1; }
done
[ "$r25" = 0 ] && ok "register/show/bind/ensure all refuse an id that disagrees with its filename" \
               || bad "the id invariant is not enforced everywhere"

# --- 26. a huge reader_schema is not canonicalized backwards -------------
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
run "$t" bind codex-primary >/dev/null 2>&1
b="$t/collab/bindings/codex-primary.json"
sed -i.bak 's/"reader_schema": 2/"reader_schema": 999999999999999999999999999999/' "$b"; rm -f "$b.bak"
before="$(cksum < "$b")"
out="$(run "$t" ensure codex-primary 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ "$before" = "$(cksum < "$b")" ] \
  && ! printf '%s' "$out" | grep -q "integer expression"; } \
  && ok "a reader_schema past the 64-bit range is refused, not reset" \
  || bad "huge reader_schema downgraded (rc=$rc)"

# --- 27. a control byte written into an existing alias is caught on READ --
t="$(newproj)"
run "$t" register codex-primary --kind codex --alias 'ok' >/dev/null 2>&1
perl -i -pe 's/"alias": "ok"/"alias": "o\tk"/' "$t/collab/participants/codex-primary.json" 2>/dev/null \
  || sed -i.bak "s/\"alias\": \"ok\"/\"alias\": \"o$(printf '\t')k\"/" "$t/collab/participants/codex-primary.json"
rm -f "$t/collab/participants/codex-primary.json.bak"
out="$(run "$t" bind codex-primary 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ ! -e "$t/collab/bindings/codex-primary.json" ]; } \
  && ok "a control byte hand-written into an alias is refused by the reader" \
  || bad "reader accepted a control byte (rc=$rc)"

# --- 28. unusable live coordinates never destroy a valid binding ---------
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
run "$t" bind codex-primary >/dev/null 2>&1
b="$t/collab/bindings/codex-primary.json"; before="$(cksum < "$b")"
badco="$ROOT/badcoord.$$"; mkdir -p "$badco"
cat > "$badco/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pane current") printf '{"result":{"pane":{"pane_id":"bad/value","tab_id":"w3:t6","agent_session":{"value":"sess-A"}}}}\n' ;;
  "agent list")   printf '{"result":{"agents":[{"agent_session":{"value":"sess-A"}}]}}\n' ;;
esac
EOF
chmod +x "$badco/herdr"
out="$( cd "$t" && HERDR_STATE="$t/state" PATH="$badco:$PATH" bash "$P" bind codex-primary 2>&1 )"; rc=$?
{ [ "$rc" != 0 ] && [ "$before" = "$(cksum < "$b")" ]; } \
  && ok "coordinates the codec cannot store are rejected before the old binding is touched" \
  || bad "a bad pane_id destroyed the previous binding (rc=$rc)"

# --- 29. re-register with a different alias is a conflict, not a no-op ---
t="$(newproj)"
run "$t" register codex-primary --kind codex --alias 'First' >/dev/null 2>&1
out="$(run "$t" register codex-primary --kind codex --alias 'Second' 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && grep -q '"alias": "First"' "$t/collab/participants/codex-primary.json"; } \
  && ok "re-registering with a different alias conflicts instead of silently ignoring it" \
  || bad "alias change silently ignored (rc=$rc)"

# --- 30. TERM to a holder must stop it before it writes --------------------
# The old handler released the lock and returned, so the interrupted critical section went
# on to write the binding anyway — with another claimant free to enter it.
t="$(newproj)"; LB2="$ROOT/locks2.$$"; mkdir -p "$LB2"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
run "$t" bind codex-primary >/dev/null 2>&1
b="$t/collab/bindings/codex-primary.json"; before="$(cksum < "$b")"
slowlist="$ROOT/slowlist.$$"; mkdir -p "$slowlist"
cat > "$slowlist/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pane current") printf '{"result":{"pane":{"pane_id":"w3:pD","tab_id":"w3:t6","agent_session":{"value":"sess-Z"}}}}\n' ;;
  "agent list")   sleep 3; printf '{"result":{"agents":[]}}\n' ;;
esac
EOF
chmod +x "$slowlist/herdr"
( cd "$t" && exec env HERDR_STATE="$t/state" COLLAB_LOCK_BASE="$LB2" PATH="$slowlist:$PATH" \
    bash "$P" bind codex-primary >/dev/null 2>&1 ) &
h=$!
sleep 1; kill -TERM "$h" 2>/dev/null; hrc=0; wait "$h" 2>/dev/null || hrc=$?
{ [ "$hrc" = 143 ] && [ "$before" = "$(cksum < "$b")" ]; } \
  && ok "a TERMed holder stops before writing; the previous binding is untouched" \
  || bad "interrupted holder still wrote (rc=$hrc)"

# --- 31. a claim directory we did not write is refused, not guessed at -----
# The whole safety argument rests on "the newest generation only moves forward". A name
# the tool never writes breaks that reading, so the claim must fail closed rather than
# derive a next generation from a directory it cannot account for.
t="$(newproj)"; LB3="$ROOT/locks3.$$"; mkdir -p "$LB3"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
key3="$(printf '%s\0%s' "$(cd "$t/collab" && pwd -P)" codex-primary | cksum | tr -d ' \n')"
lockd3="$LB3/claim-$key3.d"; mkdir -p "$lockd3"
printf 'junk\n' > "$lockd3/g0.bak"
out="$( cd "$t" && HERDR_STATE="$t/state" COLLAB_LOCK_BASE="$LB3" bash "$P" bind codex-primary 2>&1 )"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "not a generation file" && [ ! -e "$lockd3/g0" ]; } \
  && ok "an unaccountable claim directory fails closed instead of minting a generation" \
  || bad "claim directory grammar not enforced (rc=$rc)"
rm -f "$lockd3/g0.bak"

# --- 31b. a leading-zero alias must not shadow the generation it duplicates -
# `_mf_digits_cmp` compares by VALUE, so `g02` and `g2` are one generation under two
# names — and the alias can hold different content. A released `g02` beside a live `g2`
# had the scanner report the alias, a second session take `g3`, and its collection then
# delete the generation the first session was still inside.
run "$t" bind codex-primary >/dev/null 2>&1
printf '%s:%s:1\n' "$(hostname -s)" "$$" > "$lockd3/g2"     # a LIVE holder (our own pid)
printf 'released\n' > "$lockd3/g02"                          # the alias, claiming it is free
b="$t/collab/bindings/codex-primary.json"; before="$(cksum < "$b")"
mkdir -p "$t/stateC"; cp "$t/state/pane" "$t/state/tab" "$t/state/live" "$t/stateC/"
printf 'sess-C\n' > "$t/stateC/session"
out="$( cd "$t" && HERDR_STATE="$t/stateC" COLLAB_LOCK_BASE="$LB3" bash "$P" bind codex-primary 2>&1 )"; rc=$?
{ [ "$rc" != 0 ] && [ -f "$lockd3/g2" ] && [ ! -e "$lockd3/g3" ] && [ "$before" = "$(cksum < "$b")" ]; } \
  && ok "a leading-zero generation alias is refused; the live holder's file survives" \
  || bad "generation alias shadowed a live holder (rc=$rc, dir: $(ls "$lockd3" | tr '\n' ' '))"

# --- 31c. a canonical-looking FIFO must be refused, not waited on ----------
# `cat` on a FIFO nobody writes to blocks for as long as it takes, and that is not a wait
# the ten-second claim timeout can end — the timeout counts loop passes, and this never
# finishes one. Without the regular-file check this case does not fail, it HANGS, so the
# test carries its own deadline (`alarm` does not survive into the shell; a watchdog does).
rm -f "$lockd3"/g*        # the FIFO must be the newest, or it is never read at all
mkfifo "$lockd3/g0"
( cd "$t" && exec env HERDR_STATE="$t/state" COLLAB_LOCK_BASE="$LB3" \
    bash "$P" bind codex-primary > "$t/fifo.out" 2>&1 ) & fp=$!
n=0; while kill -0 "$fp" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.2; n=$((n+1)); done
if kill -0 "$fp" 2>/dev/null; then
  kill -KILL "$fp" 2>/dev/null; wait "$fp" 2>/dev/null || true; frc=blocked
else
  frc=0; wait "$fp" || frc=$?
fi
{ [ "$frc" != blocked ] && [ "$frc" != 0 ] && grep -q "not a regular file" "$t/fifo.out"; } \
  && ok "a canonical-looking FIFO is refused instead of blocking the claim" \
  || bad "FIFO generation not refused (rc=$frc)"
rm -f "$lockd3/g0"

# --- 32. an old claimant can never unlink the successor's generation -------
# The residual the review forced: `[ "$priv" -ef "$lock" ]` followed by `rm "$lock"` is a
# check and an unlink, not a compare-and-swap, so two actors that both observed a stale
# lock could have the first remove it, a fresh claimant create its own, and the second
# remove THAT. Two claimants now start from the same stale observation while a sampler
# watches the newest generation: it must never move backwards, and two DIFFERENT sessions
# must not both come away holding the identity.
dead=999999; while kill -0 "$dead" 2>/dev/null; do dead=$((dead+1)); done
printf '%s:%s:1\n' "$(hostname -s)" "$dead" > "$lockd3/g0"
mkdir -p "$t/stateB"; cp "$t/state/pane" "$t/state/tab" "$t/stateB/"
printf 'sess-B\n' > "$t/stateB/session"
printf 'sess-A\nsess-B\n' > "$t/state/live"; cp "$t/state/live" "$t/stateB/live"
samples="$t/gens"; : > "$samples"
( while :; do ls "$lockd3" 2>/dev/null | sed -n 's/^g\([0-9][0-9]*\)$/\1/p' \
    | sort -n | tail -1 >> "$samples"; sleep 0.05; done ) & sampler=$!
o1="$t/r1"; o2="$t/r2"
( cd "$t" && exec env HERDR_STATE="$t/state"  COLLAB_LOCK_BASE="$LB3" bash "$P" bind codex-primary > "$o1" 2>&1 ) & g1=$!
( cd "$t" && exec env HERDR_STATE="$t/stateB" COLLAB_LOCK_BASE="$LB3" bash "$P" bind codex-primary > "$o2" 2>&1 ) & g2=$!
r1=0; wait "$g1" || r1=$?; r2=0; wait "$g2" || r2=$?
kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null || true
# Non-decreasing is the whole claim: a generation that vanished under a live holder is
# exactly the bug, and it shows up here as a sample lower than one already seen.
mono=yes; prev=0
while IFS= read -r g; do [ -n "$g" ] || continue; [ "$g" -lt "$prev" ] && mono=no; prev="$g"; done < "$samples"
winners=0; [ "$r1" = 0 ] && winners=$((winners+1)); [ "$r2" = 0 ] && winners=$((winners+1))
{ [ "$mono" = yes ] && [ "$winners" = 1 ]; } \
  && ok "the newest generation never goes backwards, and two sessions yield one winner" \
  || bad "successor generation unsafe (monotonic=$mono winners=$winners r1=$r1 r2=$r2)"

# --- 32b. a claimant superseded twice must not hold a recycled generation --
# The subtle half of the same bug. X reads the newest generation, then stalls; Y takes the
# next one and releases; Z takes the one after that and — legitimately, as the holder of
# the newest — garbage-collects Y's. X now wakes and creates the generation Z just
# removed, and its create SUCCEEDS. Only re-reading the directory after the create tells
# X that a higher generation exists and it did not win. Without that re-read X enters the
# critical section beside Z, and its release re-creates the collected generation — which
# is what this counts.
t="$(newproj)"; LB4="$ROOT/locks4.$$"; mkdir -p "$LB4"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
key4="$(printf '%s\0%s' "$(cd "$t/collab" && pwd -P)" codex-primary | cksum | tr -d ' \n')"
lockd4="$LB4/claim-$key4.d"; mkdir -p "$lockd4"
printf '%s:%s:1\n' "$(hostname -s)" "$dead" > "$lockd4/g0"     # what X will observe
holdlist="$ROOT/holdlist.$$"; mkdir -p "$holdlist"
cat > "$holdlist/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pane current") printf '{"result":{"pane":{"pane_id":"w3:pD","tab_id":"w3:t6","agent_session":{"value":"sess-A"}}}}\n' ;;
  "agent list")   sleep 4; printf '{"result":{"agents":[]}}\n' ;;   # Z holds while it waits
esac
EOF
chmod +x "$holdlist/herdr"
( cd "$t" && exec env HERDR_STATE="$t/state" COLLAB_LOCK_BASE="$LB4" COLLAB_LOCK_TEST_STALL=3 \
    bash "$P" bind codex-primary >/dev/null 2>&1 ) & x=$!
sleep 0.3
( cd "$t" && HERDR_STATE="$t/state" COLLAB_LOCK_BASE="$LB4" bash "$P" bind codex-primary >/dev/null 2>&1 )   # Y: g1, released
( cd "$t" && exec env HERDR_STATE="$t/state" COLLAB_LOCK_BASE="$LB4" PATH="$holdlist:$PATH" \
    bash "$P" bind codex-primary >/dev/null 2>&1 ) & z=$!          # Z: g2, holds ~4s, collects g1
xrc=0; wait "$x" || xrc=$?; zrc=0; wait "$z" || zrc=$?
gens="$(ls "$lockd4" 2>/dev/null | sed -n 's/^g[0-9][0-9]*$/&/p' | wc -l | tr -d ' ')"
{ [ "$gens" = 1 ] && [ "$xrc" = 0 ] && [ "$zrc" = 0 ]; } \
  && ok "a claimant whose generation was collected under it backs off instead of holding" \
  || bad "stale create was taken as a claim (generations=$gens xrc=$xrc zrc=$zrc: $(ls "$lockd4" | tr '\n' ' '))"

# --- 33. valid JSON whose agents is the WRONG TYPE is unknown -------------
# `{"result":{"agents":"BROKEN","junk":[]}}` is valid JSON and has brackets, just not
# around agents. A bracket heuristic passed it and every session read as absent.
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
run "$t" bind codex-primary >/dev/null 2>&1
b="$t/collab/bindings/codex-primary.json"; before="$(cksum < "$b")"
wt="$ROOT/wrongtype.$$"; mkdir -p "$wt"
cat > "$wt/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pane current") printf '{"result":{"pane":{"pane_id":"w3:pD","tab_id":"w3:t6","agent_session":{"value":"sess-B"}}}}\n' ;;
  "agent list")   printf '{"result":{"agents":"BROKEN","junk":[{"agent_session":{"value":"sess-A"}}]}}\n' ;;
esac
EOF
chmod +x "$wt/herdr"
out="$( cd "$t" && HERDR_STATE="$t/state" PATH="$wt:$PATH" bash "$P" bind codex-primary 2>&1 )"; rc=$?
{ [ "$rc" != 0 ] && [ "$before" = "$(cksum < "$b")" ]; } \
  && ok "valid JSON with a non-array agents is unknown, and a decoy outside it is ignored" \
  || bad "wrong-typed agents read as absent (rc=$rc)"

# --- 34. a symlinked participants/ cannot serve a foreign identity --------
t="$(newproj)"; foreign="$ROOT/foreign.$$"; mkdir -p "$foreign"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
cp "$t/collab/participants/codex-primary.json" "$foreign/"
rm -rf "$t/collab/participants"; ln -s "$foreign" "$t/collab/participants"
out="$(run "$t" bind codex-primary 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ ! -e "$t/collab/bindings/codex-primary.json" ]; } \
  && ok "a symlinked participants/ is refused even when it holds a valid identity" \
  || bad "bound through a symlinked registry (rc=$rc)"

# --- 35. the id grammar applies to file CONTENT too -----------------------
t="$(newproj)"
run "$t" register codex-primary --kind codex >/dev/null 2>&1
longid="$(printf 'a%.0s' $(seq 1 65))"
sed "s/\"id\": \"codex-primary\"/\"id\": \"$longid\"/" \
  "$t/collab/participants/codex-primary.json" > "$t/collab/participants/$longid.json"
out="$(run "$t" show "$longid" 2>&1)"; rc=$?
[ "$rc" != 0 ] \
  && ok "an over-long id is rejected by the same grammar on input and on read" \
  || bad "a 65-character id was accepted (rc=$rc)"

# --- 36. with no usable JSON parser, liveness is unknown — never absent ----
# The dependency-free fallback counted brackets without knowing whether it was inside a
# string, so a live agent listed as {"note":"]", ...} ended the array early and read as
# absent — the one verdict that lets a claim take a live binding with no --takeover.
# `absent` must now be reachable only through a parser that actually parsed.
nop="$ROOT/noparser.$$"; mkdir -p "$nop"
for shim in python3 ruby; do printf '#!/bin/sh\nexit 127\n' > "$nop/$shim"; chmod +x "$nop/$shim"; done
i=0
for payload in \
  '{"result":{"agents":[{"note":"]","agent_session":{"value":"sess-A"}}]}}' \
  '{"result":{"agents":[{"note":"[","agent_session":{"value":"sess-A"}}]}}' \
  '{"result":{"agents":[{"note":"\"]\"","agent_session":{"value":"sess-A"}}]}}' \
  '{"result":{"agents":[BROKEN]}}' \
  '{"result":{"agents":"x"},"decoy":[{"agent_session":{"value":"sess-A"}}]}' ; do
  i=$((i+1))
  t="$(newproj)"
  run "$t" register codex-primary --kind codex >/dev/null 2>&1
  run "$t" bind codex-primary >/dev/null 2>&1        # bound to sess-A, with the real stub
  b="$t/collab/bindings/codex-primary.json"; before="$(cksum < "$b")"
  # The payload goes in a FILE the stub reads: generating a quoted fixture through nested
  # printf is how a hostile-string test quietly stops testing the string it names.
  fb="$ROOT/fallback.$i"; mkdir -p "$fb"
  printf '%s\n' "$payload" > "$fb/payload.json"
  cat > "$fb/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pane current") printf '{"result":{"pane":{"pane_id":"w3:pD","tab_id":"w3:t6","agent_session":{"value":"sess-B"}}}}\n' ;;
  "agent list")   cat "$(dirname "$0")/payload.json" ;;
esac
EOF
  chmod +x "$fb/herdr"
  out="$( cd "$t" && HERDR_STATE="$t/state" PATH="$nop:$fb:$PATH" bash "$P" bind codex-primary 2>&1 )"; rc=$?
  { [ "$rc" != 0 ] && [ "$before" = "$(cksum < "$b")" ]; } \
    && ok "no usable parser: payload $i is unknown, and the live binding is untouched" \
    || bad "fallback authorised a silent takeover on payload $i (rc=$rc)"
done

# --- 37. a parser that cannot RUN is not a verdict; the next one answers ---
# "python3 exists" and "python3 works" are different facts. A broken interpreter must not
# swallow the question — ruby still has to be asked before we settle for unknown.
if command -v ruby >/dev/null 2>&1 && ruby -rjson -e 'exit 0' >/dev/null 2>&1; then
  t="$(newproj)"
  run "$t" register codex-primary --kind codex >/dev/null 2>&1
  run "$t" bind codex-primary >/dev/null 2>&1
  printf 'sess-A\n' > "$t/state/live"                 # sess-A is still live
  brk="$ROOT/brokenpy.$$"; mkdir -p "$brk"
  printf '#!/bin/sh\nexit 1\n' > "$brk/python3"; chmod +x "$brk/python3"
  printf 'sess-B\n' > "$t/state/session"
  out="$( cd "$t" && HERDR_STATE="$t/state" PATH="$brk:$PATH" bash "$P" bind codex-primary 2>&1 )"; rc=$?
  { [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "LIVE session (sess-A)"; } \
    && ok "a broken python3 falls through to ruby, which still reports the live holder" \
    || bad "a broken parser was taken as a verdict (rc=$rc: $out)"
else
  ok "a broken python3 falls through to ruby (skipped: no usable ruby here)"
fi

# --- 38. a parser that PRINTS and then dies is not a verdict ---------------
# "Did it run" was being read off stdout, not the exit status. A python3 that emitted a
# partial `OK` and then exited 1 looked exactly like a complete answer listing nobody —
# `absent` — so ruby was never asked and the live binding was taken with no --takeover.
if command -v ruby >/dev/null 2>&1 && ruby -rjson -e 'exit 0' >/dev/null 2>&1; then
  t="$(newproj)"
  run "$t" register codex-primary --kind codex >/dev/null 2>&1
  run "$t" bind codex-primary >/dev/null 2>&1
  b="$t/collab/bindings/codex-primary.json"; before="$(cksum < "$b")"
  printf 'sess-A\n' > "$t/state/live"                 # sess-A is still live
  printf 'sess-B\n' > "$t/state/session"
  # Heredoc, not printf: a `%s` in the format silently ate the stub's body and the case
  # passed while testing an empty parser instead of a half-finished one.
  half="$ROOT/halfpy.$$"; mkdir -p "$half"
  cat > "$half/python3" <<'EOF'
#!/bin/sh
echo OK
exit 1
EOF
  chmod +x "$half/python3"
  sout="$(PATH="$half:$PATH" python3 -c 'anything' </dev/null 2>/dev/null)"; src=$?
  { [ "$sout" = OK ] && [ "$src" = 1 ]; } \
    || bad "the half-finished python3 stub does not behave as named (out='$sout' rc=$src)"
  out="$( cd "$t" && HERDR_STATE="$t/state" PATH="$half:$PATH" bash "$P" bind codex-primary 2>&1 )"; rc=$?
  { [ "$rc" != 0 ] && [ "$before" = "$(cksum < "$b")" ]; } \
    && ok "a parser that prints then exits nonzero is discarded, and ruby answers instead" \
    || bad "a partial parser answer was taken as absent (rc=$rc: $out)"
else
  ok "a parser that prints then exits nonzero is discarded (skipped: no usable ruby here)"
fi

[ "$fails" -eq 0 ] && { echo "participant: all passed"; exit 0; }
echo "participant: $fails failed" >&2; exit 1

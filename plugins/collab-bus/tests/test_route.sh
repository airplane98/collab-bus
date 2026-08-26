#!/usr/bin/env bash
# Tests for route.sh (v0.8 step 4): which messages in my inbox are addressed to ME.
#
# The property under test is the one that unblocks a mesh: schema 2 addresses a
# PARTICIPANT and the match is exact, while legacy messages — already published, therefore
# unupgradable — still resolve through the tab they were written for. Two participants
# sharing one tab must not both claim the same message.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
R="$DIR/scripts/route.sh"
P="$DIR/scripts/participant.sh"
B="$DIR/scripts/bootstrap.sh"
fails=0
ok()  { echo "  ok   - $1"; }
bad() { echo "  FAIL - $1" >&2; fails=$((fails+1)); }
ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$ROOT"' EXIT

# A herdr stub whose answers come from files, so a test can restart a session between
# calls. Same shape test_participant.sh uses.
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

# One project, bootstrapped exactly as a user would get it, then both participants bound.
newproj() {
  local t; t="$(mktemp -d "$ROOT/proj.XXXXXX")"
  ( cd "$t" && bash "$B" codex --dir . ) >/dev/null 2>&1 || return 1
  mkdir -p "$t/sA" "$t/sB"
  printf 'w3:pC\n' > "$t/sA/pane"; printf 'w3:t6\n' > "$t/sA/tab"; printf 'sess-A\n' > "$t/sA/session"
  printf 'w3:pD\n' > "$t/sB/pane"; printf 'w3:t6\n' > "$t/sB/tab"; printf 'sess-B\n' > "$t/sB/session"
  printf 'sess-A\nsess-B\n' > "$t/sA/live"; cp "$t/sA/live" "$t/sB/live"
  ( cd "$t" && HERDR_STATE="$t/sA" bash "$P" bind claude-primary ) >/dev/null 2>&1 || return 1
  ( cd "$t" && HERDR_STATE="$t/sB" bash "$P" bind codex-primary ) >/dev/null 2>&1 || return 1
  # A SECOND participant of the SAME KIND, in the SAME TAB. This is the configuration the
  # old `pair == my tab` rule cannot express at all, so every mesh claim below is measured
  # against it rather than against two different kinds (which `to`/inbox already separate).
  mkdir -p "$t/sC"
  printf 'w3:pE\n' > "$t/sC/pane"; printf 'w3:t6\n' > "$t/sC/tab"; printf 'sess-C\n' > "$t/sC/session"
  printf 'sess-A\nsess-B\nsess-C\n' > "$t/sA/live"
  cp "$t/sA/live" "$t/sB/live"; cp "$t/sA/live" "$t/sC/live"
  ( cd "$t" && HERDR_STATE="$t/sC" bash "$P" register codex-second --kind codex ) >/dev/null 2>&1 || return 1
  ( cd "$t" && HERDR_STATE="$t/sC" bash "$P" bind codex-second ) >/dev/null 2>&1 || return 1
  printf '%s' "$t"
}

# Fixtures are written as whole files: composing frontmatter with printf is how a test
# stops testing the envelope it names (the step-3 lesson).
# A ULID-shaped id: Crockford base32 has no I, L, O or U, and the first character is
# 0-7. A fixture that does not satisfy the reader's own grammar tests the grammar, not the
# routing — which is exactly how the first version of this file passed for the wrong reason.
mid() { printf '01M0BBBBBBBBBBBBBBBBBBBBB%s' "$1"; }

msg2() { # <path> <to_agent> <pair> <status> <id-suffix> [from_agent]
  local i; i="$(mid "$5")"
  cat > "$1" <<EOF
---
schema: 2
id: $i
thread: $i
from: claude
to: codex
from_agent: ${6:-claude-primary}
to_agent: $2
intent: action
type: task
subject: 'fixture'
status: $4
pair: $3
---
body
EOF
}
msg1() { # <path> <pair-line> <status>
  { echo '---'
    echo 'id: 0001'
    echo 'from: claude'
    echo 'to: codex'
    echo 'type: task'
    echo "subject: 'legacy fixture'"
    echo "status: $3"
    [ -n "$2" ] && echo "pair: $2"
    echo '---'
    echo body
  } > "$1"
}

t="$(newproj)" || { echo "route: could not scaffold" >&2; exit 1; }
IN="$t/collab/inbox/to/codex"
run() { ( cd "$t" && HERDR_STATE="$t/sB" bash "$R" "$@" ); }

# --- 1. schema 2 addresses a participant, and the match is exact ------------
msg2 "$IN/a.md" codex-primary w3:t6 open A
out="$(run list --agent codex-primary 2>/dev/null)"; rc=$?
# Paths come back relative to the directory scanned, which is how they are usable straight
# from the project root the agent already works in.
{ [ "$rc" = 0 ] && [ "$out" = "collab/inbox/to/codex/a.md" ]; } \
  && ok "a schema-2 message addressed to my participant id is mine" \
  || bad "exact routing did not list the message (rc=$rc, out=$out)"

# --- 2. a to_agent for someone else does NOT fall back to the tab ----------
# The whole point. `pair` still matches — it is the same tab — and that must not matter:
# "addressed to someone else, but my tab matches" is the misdelivery exact routing exists
# to prevent, so a present-and-different to_agent is final.
msg2 "$IN/b.md" codex-second w3:t6 open B
out="$(run list --agent codex-primary 2>/dev/null)"; rc=$?
{ [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q 'b\.md'; } \
  && ok "a message addressed to another participant is not claimed via the tab" \
  || bad "tab fallback overrode an explicit to_agent (rc=$rc, out=$out)"

# --- 3. two participants of ONE KIND in ONE TAB, on the DEFAULT inbox ------
# The mesh blocker, stated exactly: same kind, same tab, same directory. Under the old
# rule both matched everything, and only there having been one agent per kind hid it.
# Neither `--dir` nor a different kind is used here — either would let the directory do
# the separating and prove nothing about the address.
outA="$(run list --agent codex-primary 2>/dev/null)"
outC="$( cd "$t" && HERDR_STATE="$t/sC" bash "$R" list --agent codex-second 2>/dev/null )"
{ printf '%s' "$outA" | grep -q 'a\.md' && ! printf '%s' "$outA" | grep -q 'b\.md' \
  && printf '%s' "$outC" | grep -q 'b\.md' && ! printf '%s' "$outC" | grep -q 'a\.md'; } \
  && ok "two same-kind participants in one tab partition one inbox exactly" \
  || bad "same-kind mesh overlap (primary=$outA second=$outC)"

# --- 3b. a to_agent whose kind contradicts the message is BAD -------------
# `to: codex` with a kind=claude recipient is a message the sender could publish and
# nobody could receive: every reader said "not mine", quietly, with rc 0.
msg2 "$IN/wk.md" claude-primary w3:t6 open W
out="$(run list --agent codex-primary 2>"$t/err.3b")"; rc=$?
{ [ "$rc" = 1 ] && ! printf '%s' "$out" | grep -q 'wk\.md' && grep -q 'wk\.md' "$t/err.3b"; } \
  && ok "a recipient whose kind contradicts the message is reported, not ignored" \
  || bad "wrong-kind recipient stayed silent (rc=$rc)"
rm -f "$IN/wk.md"

# --- 3c. an unregistered to_agent is UNROUTED, never a tab fallback -------
msg2 "$IN/gh.md" ghost-primary w3:t6 open G
out="$(run list --agent codex-primary 2>"$t/err.3c")"; rc=$?
{ [ "$rc" = 1 ] && ! printf '%s' "$out" | grep -q 'gh\.md' \
  && grep -q 'not a registered participant' "$t/err.3c"; } \
  && ok "an unregistered recipient is loud and never falls back to the tab" \
  || bad "unknown to_agent mishandled (rc=$rc)"
rm -f "$IN/gh.md"

# --- 3d. a duplicated routing field is BAD, not first-wins ---------------
# fm_get took the first value; Ruby and PyYAML take the last. A message with two
# `to_agent:` lines therefore routed to different participants depending on the reader —
# the exact hazard the whole-file grammar exists to remove.
msg2 "$IN/dup.md" codex-primary w3:t6 open D
sed -i.bak 's/^to_agent: codex-primary$/to_agent: codex-primary\
to_agent: ghost-primary/' "$IN/dup.md"; rm -f "$IN/dup.md.bak"
out="$(run list --agent codex-primary 2>"$t/err.3d")"; rc=$?
{ [ "$rc" = 1 ] && ! printf '%s' "$out" | grep -q 'dup\.md' \
  && grep -q 'more than once' "$t/err.3d"; } \
  && ok "a duplicated to_agent is refused instead of resolved first-wins" \
  || bad "duplicate routing field was claimed (rc=$rc)"
rm -f "$IN/dup.md"

# --- 4. a legacy message with no to_agent still resolves by tab -----------
# Already published, therefore immutable: it cannot be upgraded, so the tab is all there is.
msg1 "$IN/c.md" w3:t6 open
out="$(run list --agent codex-primary 2>/dev/null)"
printf '%s' "$out" | grep -q 'c\.md' \
  && ok "a schema-1 message with no to_agent falls back to the tab" \
  || bad "legacy fallback did not match (out=$out)"

# --- 5. a legacy message for another tab is not mine ----------------------
msg1 "$IN/d.md" w9:t1 open
out="$(run list --agent codex-primary 2>/dev/null)"
! printf '%s' "$out" | grep -q 'd\.md' \
  && ok "a schema-1 message for another tab is not claimed" \
  || bad "legacy fallback matched the wrong tab (out=$out)"

# --- 6. neither an address nor a tab is UNROUTED, never a guess -----------
# 32 of the 126 messages measured on the live bus have no `pair`. Claiming one would mean
# guessing, and a wrong guess hands one pair's work to another.
msg1 "$IN/e.md" "" open
out="$(run list --agent codex-primary 2>"$t/err.6")"; rc=$?
{ [ "$rc" = 1 ] && ! printf '%s' "$out" | grep -q 'e\.md' && grep -q 'e\.md' "$t/err.6"; } \
  && ok "a message with no to_agent and no pair is reported, not claimed" \
  || bad "unrouted message mishandled (rc=$rc)"
rm -f "$IN/e.md"

# --- 7. lifecycle is separate from addressing ----------------------------
msg2 "$IN/f.md" codex-primary w3:t6 done F
out="$(run list --agent codex-primary 2>/dev/null)"
outall="$(run list --agent codex-primary --include-closed 2>/dev/null)"
{ ! printf '%s' "$out" | grep -q 'f\.md' && printf '%s' "$outall" | grep -q 'f\.md'; } \
  && ok "a closed message is mine but not open; --all shows it" \
  || bad "status handling wrong (out=$out all=$outall)"

# --- 8. one unreadable file is loud, and the scan continues --------------
# Contract E: fail loudly for that file and keep scanning. Silence is how a message goes
# missing forever, and stopping is how every message behind it does.
printf 'no frontmatter here\n' > "$IN/g.md"
out="$(run list --agent codex-primary 2>"$t/err.8")"; rc=$?
{ [ "$rc" = 1 ] && grep -q 'g\.md' "$t/err.8" && printf '%s' "$out" | grep -q 'a\.md'; } \
  && ok "an unreadable message is named on stderr and the rest still list" \
  || bad "bad file stopped or silenced the scan (rc=$rc)"
rm -f "$IN/g.md"

# --- 9. explain and list cannot disagree ---------------------------------
# `explain` exists to show the reason for a verdict `list` actually used, so both go
# through one function; a second implementation would drift the first time either changed.
e_a="$(run explain --agent codex-primary "$IN/a.md" 2>/dev/null | sed -n 's/^verdict: //p')"
e_b="$(run explain --agent codex-primary "$IN/b.md" 2>/dev/null | sed -n 's/^verdict: //p')"
{ [ "$e_a" = "MINE" ] && printf '%s' "$e_b" | grep -q 'not mine'; } \
  && ok "explain reports the same verdict list acted on" \
  || bad "explain disagrees with list (a='$e_a' b='$e_b')"

# --- 10. whoami answers from the binding, and list uses it ---------------
who="$( cd "$t" && HERDR_STATE="$t/sB" bash "$P" whoami 2>/dev/null )"
out="$(run list 2>/dev/null)"
{ [ "$who" = codex-primary ] && printf '%s' "$out" | grep -q 'a\.md'; } \
  && ok "whoami resolves this session's participant, and list defaults to it" \
  || bad "whoami/list default wrong (who=$who)"

# --- 11. the inbox directory comes from the identity, not a typed name ---
out="$(run list --agent claude-primary 2>/dev/null)"
{ printf '%s' "$out" | grep -q '/inbox/to/claude' || [ -z "$out" ]; } \
  && ok "the default inbox is derived from the participant's kind" \
  || bad "default dir ignored the identity (out=$out)"

# --- 12. a restarted session keeps its address ---------------------------
# The reason the split exists. herdr hands out a new agent_session on restart and the pane
# may move; a message published yesterday still names the participant, so it must still be
# claimable — and archiving stays LAST, so an interrupted run re-sees it.
printf 'sess-B2\n' > "$t/sB/session"; printf 'w3:pE\n' > "$t/sB/pane"
printf 'sess-A\nsess-B2\n' > "$t/sA/live"; cp "$t/sA/live" "$t/sB/live"
( cd "$t" && HERDR_STATE="$t/sB" bash "$P" bind codex-primary --takeover ) >/dev/null 2>&1
who2="$( cd "$t" && HERDR_STATE="$t/sB" bash "$P" whoami 2>/dev/null )"
out="$(run list 2>/dev/null)"
claimed="$(printf '%s' "$out" | grep 'a\.md' || true)"
if [ -n "$claimed" ]; then
  ( cd "$t" && mv "$claimed" collab/inbox/archive/ )        # archive LAST
  after="$(run list 2>/dev/null)"
else
  after="(never claimed)"
fi
{ [ "$who2" = codex-primary ] && [ -n "$claimed" ] \
  && [ -f "$t/collab/inbox/archive/a.md" ] && ! printf '%s' "$after" | grep -q 'a\.md'; } \
  && ok "a restarted session with a new session id still claims, drains and archives" \
  || bad "restart broke the address (who=$who2 claimed=$claimed after=$after)"

# --- 13. a symlinked message is refused, loudly --------------------------
ln -s "$IN/b.md" "$IN/h.md"
out="$(run list --agent codex-primary 2>"$t/err.13")"; rc=$?
{ [ "$rc" = 1 ] && grep -q 'h\.md' "$t/err.13" && ! printf '%s' "$out" | grep -q 'h\.md'; } \
  && ok "a symlinked message is refused instead of followed" \
  || bad "symlinked message not refused (rc=$rc)"
rm -f "$IN/h.md"

# --- 14. capability answers about LIVE READERS, and says no today --------
out="$(run capability 2>/dev/null)"
{ printf '%s' "$out" | grep -q 'min_reader: 1' \
  && printf '%s' "$out" | grep -q 'REQUIRED'; } \
  && ok "legacy pair + status are REQUIRED while min_reader is 1" \
  || bad "capability verdict wrong (out=$out)"

# --- 15. an unbound participant blocks the drop even at min_reader 2 -----
# A registered participant nobody has bound is an UNKNOWN reader, and unknown cannot
# license dropping the fields it might need. Contract D is about running processes.
t2="$(newproj)" || exit 1
sed -i '' 's/"min_reader": 1/"min_reader": 2/' "$t2/collab/bus.json" 2>/dev/null \
  || sed -i 's/"min_reader": 1/"min_reader": 2/' "$t2/collab/bus.json"
( cd "$t2" && HERDR_STATE="$t2/sA" bash "$P" register third-party --kind gemini ) >/dev/null 2>&1
out="$( cd "$t2" && HERDR_STATE="$t2/sB" bash "$R" capability 2>/dev/null )"
{ printf '%s' "$out" | grep -q 'REQUIRED' && printf '%s' "$out" | grep -q 'third-party'; } \
  && ok "a registered but unbound participant keeps the legacy fields required" \
  || bad "unbound reader did not block the drop (out=$out)"

# --- 16. a manifest from newer tooling is "cannot judge", not "corrupt" ---
# rc 3 out of the codec is a WRITER verdict — do not overwrite this. A reader that
# flattens it into "invalid" reports a broken bus when the truth is a newer peer, and the
# two call for opposite actions.
t3="$(newproj)" || exit 1
sed -i.bak -e 's/"read": \[1, 2\]/"read": [1, 2, 3]/' -e 's/"write": [0-9][0-9]*/"write": 3/' \
           "$t3/collab/bus.json"; rm -f "$t3/collab/bus.json.bak"
out="$( cd "$t3" && HERDR_STATE="$t3/sB" bash "$R" capability 2>&1 )"
{ printf '%s' "$out" | grep -q "newer tooling" && ! printf '%s' "$out" | grep -q "does not validate" \
  && printf '%s' "$out" | grep -q "REQUIRED"; } \
  && ok "a newer manifest is reported as unjudgeable, and legacy stays required" \
  || bad "newer manifest reported as corrupt (out=$out)"

# --- 17. a corrupt manifest is still corrupt ------------------------------
t4="$(newproj)" || exit 1
printf 'not json at all\n' > "$t4/collab/bus.json"
out="$( cd "$t4" && HERDR_STATE="$t4/sB" bash "$R" capability 2>&1 )"
{ printf '%s' "$out" | grep -q "does not validate" && printf '%s' "$out" | grep -q "REQUIRED"; } \
  && ok "a corrupt manifest is named as such, and legacy stays required" \
  || bad "corrupt manifest not reported (out=$out)"

# --- 18. --agent supplies identity only; the tab is the CALLER's -----------
# The docs tell an unbound session to pass --agent, so taking the tab out of that
# identity's binding hands routing the locator of whoever held it last: a previous
# session's tab then decides which legacy messages this one claims.
t5="$(newproj)" || exit 1
mkdir -p "$t5/sOld"; printf 'w1:pA\n' > "$t5/sOld/pane"; printf 'w1:t1\n' > "$t5/sOld/tab"
printf 'sess-old\n' > "$t5/sOld/session"; printf 'sess-old\n' > "$t5/sOld/live"
( cd "$t5" && HERDR_STATE="$t5/sOld" bash "$P" bind codex-primary --takeover ) >/dev/null 2>&1
mkdir -p "$t5/sNew"; printf 'w9:pZ\n' > "$t5/sNew/pane"; printf 'w9:t9\n' > "$t5/sNew/tab"
printf 'sess-new\n' > "$t5/sNew/session"; printf 'sess-old\nsess-new\n' > "$t5/sNew/live"
IN5="$t5/collab/inbox/to/codex"
msg1 "$IN5/old-tab.md" w1:t1 open          # addressed to the tab the BINDING remembers
msg2 "$IN5/exact.md" codex-primary w1:t1 open X
out="$( cd "$t5" && HERDR_STATE="$t5/sNew" bash "$R" list --agent codex-primary 2>/dev/null )"
{ ! printf '%s' "$out" | grep -q 'old-tab\.md' && printf '%s' "$out" | grep -q 'exact\.md'; } \
  && ok "--agent does not borrow the stored tab; exact routing still works" \
  || bad "stale binding tab leaked into routing (out=$out)"

# --- 19. no herdr: exact still routes, legacy goes loud -------------------
# The half that genuinely needs a tab is the only half that may lose.
nohd="$ROOT/noherdr.$$"; mkdir -p "$nohd"
out="$( cd "$t5" && PATH="$nohd:/usr/bin:/bin" HERDR_STATE="$t5/sNew" bash "$R" list --agent codex-primary 2>"$t5/err.19" )"; rc=$?
{ printf '%s' "$out" | grep -q 'exact\.md' && ! printf '%s' "$out" | grep -q 'old-tab\.md' \
  && [ "$rc" = 1 ] && grep -q 'old-tab\.md' "$t5/err.19"; } \
  && ok "with no herdr, exact messages route and legacy ones are reported" \
  || bad "herdr outage handled wrong (rc=$rc out=$out)"

# --- 20. a dangling symlink is reported, not skipped ---------------------
# `[ -f ]` is false for one, so the old loop dropped it in silence — the failure mode the
# whole loud-and-continue rule exists to prevent.
ln -s "$IN/nowhere.md" "$IN/dead.md"
out="$(run list --agent codex-primary 2>"$t/err.20")"; rc=$?
{ [ "$rc" = 1 ] && grep -q 'dead\.md' "$t/err.20"; } \
  && ok "a dangling symlink in the inbox is named, not silently skipped" \
  || bad "dangling symlink skipped silently (rc=$rc)"
rm -f "$IN/dead.md"

# --- 21. explain applies the same artifact gate as list ------------------
# "list and explain share the verdict" was only true of the frontmatter: list refused a
# symlink while explain followed one and answered MINE.
ln -s "$IN/a.md" "$IN/link.md"
run list --agent codex-primary >/dev/null 2>"$t/err.21a"; lrc=$?
run explain --agent codex-primary "$IN/link.md" >/dev/null 2>"$t/err.21b"; erc=$?
{ [ "$lrc" = 1 ] && [ "$erc" != 0 ] && grep -q 'symlink' "$t/err.21b"; } \
  && ok "list and explain refuse a symlinked message the same way" \
  || bad "artifact gate not shared (list=$lrc explain=$erc)"
rm -f "$IN/link.md"

# --- 22. capability counts LIVE readers, not binding files ---------------
# A binding file is the record of the last claim. Two ended sessions must not vouch for a
# capability nobody present could honour.
t6="$(newproj)" || exit 1
sed -i.bak 's/"min_reader": 1/"min_reader": 2/' "$t6/collab/bus.json"; rm -f "$t6/collab/bus.json.bak"
printf 'sess-nobody\n' > "$t6/sB/live"          # none of the recorded sessions is live
out="$( cd "$t6" && HERDR_STATE="$t6/sB" bash "$R" capability 2>/dev/null )"
{ printf '%s' "$out" | grep -q 'REQUIRED' \
  && printf '%s' "$out" | grep -q 'stale claim):.*codex-primary' \
  && printf '%s' "$out" | grep -q 'LIVE bindings at schema >= 2: 0'; } \
  && ok "ended sessions are stale claims, and cannot license dropping the legacy fields" \
  || bad "capability counted dead bindings as live (out=$out)"

# --- 23. liveness unknown fails closed ------------------------------------
out="$( cd "$t6" && PATH="$nohd:/usr/bin:/bin" HERDR_STATE="$t6/sB" bash "$R" capability 2>/dev/null )"
{ printf '%s' "$out" | grep -q 'REQUIRED' && printf '%s' "$out" | grep -q 'liveness unknown:.*codex-primary'; } \
  && ok "liveness this build cannot determine blocks the drop" \
  || bad "unknown liveness did not fail closed (out=$out)"

# --- 24. a live reader below schema 2 is counted below, not above --------
# Three participants are bound; one is a schema-1 reader, so exactly two are at >= 2. The
# counter was incremented for every readable binding before the comparison, so the
# same participant appeared as both "at schema >= 2" and "below schema 2".
t7="$(newproj)" || exit 1
sed -i.bak 's/"reader_schema": 2/"reader_schema": 1/' "$t7/collab/bindings/claude-primary.json"
rm -f "$t7/collab/bindings/claude-primary.json.bak"
out="$( cd "$t7" && HERDR_STATE="$t7/sB" bash "$R" capability 2>/dev/null )"
n2="$(printf '%s' "$out" | sed -n 's/^LIVE bindings at schema >= 2: //p')"
{ [ "$n2" = 2 ] && printf '%s' "$out" | grep -q 'below schema 2:.*claude-primary' \
  && printf '%s' "$out" | grep -q 'REQUIRED'; } \
  && ok "a live reader below schema 2 is counted below it, and blocks the drop" \
  || bad "reader_schema counting wrong (>=2 count=$n2)"

# --- 25. explain describes the scan its verdict came from -----------------
# `v="$(route_verdict "$FILE")"` ran the scan in a subshell, so the decoded fields died
# with it and explain printed a correct verdict beside four blank fields. State a caller
# has to keep cannot be produced behind a fork; the old case only read `verdict:`, which
# is exactly the one line that still worked.
# A fresh fixture: case 12 archived a.md, and asserting against a file that is no longer
# there is how a case passes or fails for a reason it does not name.
msg2 "$IN/ex.md" codex-primary w3:t6 open E
ex="$(run explain --agent codex-primary "$IN/ex.md" 2>/dev/null)"
{ printf '%s' "$ex" | grep -qx 'schema: 2' \
  && printf '%s' "$ex" | grep -qx 'to_agent: codex-primary' \
  && printf '%s' "$ex" | grep -qx 'pair: w3:t6' \
  && printf '%s' "$ex" | grep -qx 'status: open' \
  && printf '%s' "$ex" | grep -qx 'verdict: MINE'; } \
  && ok "explain prints the fields of the scan it judged, not blanks" \
  || bad "explain lost the shared decode ($(printf '%s' "$ex" | tr '\n' '|'))"

# --- 26. a refused envelope leaves no partial decode behind ---------------
printf -- '---\nschema: 2\nto_agent: codex-primary\n---\nbody\n' > "$IN/part.md"
ex="$(run explain --agent codex-primary "$IN/part.md" 2>/dev/null)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$ex" | grep -qx 'to_agent: (absent)'; } \
  && ok "fields accumulated before a scan failed are not reported as a decode" \
  || bad "partial decode surfaced ($(printf '%s' "$ex" | tr '\n' '|'))"
rm -f "$IN/part.md"

# --- 27. schema and liveness must come from ONE binding read --------------
# The deterministic interleaving: the binding is schema 2 but STALE, and is atomically
# replaced with a schema-1 LIVE one between the two reads. Neither state is a schema-2
# live reader, so splicing them produced a reader that existed at no instant — an
# impossible snapshot rather than merely an old one.
#
# The window is BETWEEN TWO PROCESSES, which no herdr stub can reach, so the seam is a
# wrapper around participant.sh in a copied tree: it runs the real accessor and then
# performs the swap. With one snapshot call there is no second read to poison.
t8="$(newproj)" || exit 1
tree="$ROOT/tree.$$"; mkdir -p "$tree"
cp -R "$DIR/scripts" "$tree/scripts"
mv "$tree/scripts/participant.sh" "$tree/scripts/participant.real.sh"
cat > "$tree/scripts/participant.sh" <<'EOF'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")" && pwd -P)"
rc=0; "$d/participant.real.sh" "$@" || rc=$?
[ -n "${SNAP_SWAP:-}" ] && [ -f "$SNAP_SWAP" ] && { sh "$SNAP_SWAP"; rm -f "$SNAP_SWAP"; }
exit $rc
EOF
chmod +x "$tree/scripts/participant.sh"
B8="$t8/collab/bindings/codex-primary.json"
for gone in claude-primary codex-second; do
  rm -f "$t8/collab/bindings/$gone.json" "$t8/collab/participants/$gone.json"
done
sed -e 's/"agent_session": "[^"]*"/"agent_session": "sess-old"/' \
    -e 's/"reader_schema": [0-9]*/"reader_schema": 2/' "$B8" > "$t8/stale.json"
cp "$t8/stale.json" "$B8"
sed -e 's/"agent_session": "sess-old"/"agent_session": "sess-new"/' \
    -e 's/"reader_schema": 2/"reader_schema": 1/' "$t8/stale.json" > "$t8/livelow.json"
printf 'cp "%s" "%s"\n' "$t8/livelow.json" "$B8" > "$t8/swap.sh"
printf 'sess-new\n' > "$t8/sB/live"          # only the NEW holder is live
sed -i.bak 's/"min_reader": 1/"min_reader": 2/' "$t8/collab/bus.json"; rm -f "$t8/collab/bus.json.bak"
out="$( cd "$t8" && HERDR_STATE="$t8/sB" SNAP_SWAP="$t8/swap.sh" bash "$tree/scripts/route.sh" capability 2>/dev/null )"
{ printf '%s' "$out" | grep -q 'REQUIRED' && ! printf '%s' "$out" | grep -q 'MAY BE DROPPED'; } \
  && ok "a rebind between reads cannot splice a schema-2 live reader into existence" \
  || bad "spliced an impossible snapshot ($(printf '%s' "$out" | tr '\n' '|'))"

# --- 28. an id that does not contain its kind still routes end to end ------
# `reviewer-a` is a perfectly good id for a codex agent, so the kind must come from the
# registry. Guessing it from the id (or reusing the kind the user was just told not to
# type) puts the draft in the wrong inbox — where the recipient's default scan never
# looks and nobody reports it.
t9="$(newproj)" || exit 1
( cd "$t9" && HERDR_STATE="$t9/sC" bash "$P" register reviewer-a --kind codex ) >/dev/null 2>&1
( cd "$t9" && HERDR_STATE="$t9/sC" bash "$P" bind reviewer-a --takeover ) >/dev/null 2>&1
kind="$( cd "$t9" && bash "$P" get reviewer-a kind 2>/dev/null )"
d="$( cd "$t9" && collab/bin/next-id.sh "$kind" opaque w3:t6 2>/dev/null )"
i="$(basename "$d")"; i="${i#.}"; i="${i%%-*}"
cat > "$d" <<EOF
---
schema: 2
id: $i
thread: $i
from: claude
to: $kind
from_agent: claude-primary
to_agent: reviewer-a
intent: action
type: task
subject: 'opaque id'
status: open
pair: w3:t6
---
body
EOF
dest="$( cd "$t9" && collab/bin/publish.sh "$d" 2>/dev/null )"; prc=$?
mine="$( cd "$t9" && HERDR_STATE="$t9/sC" bash "$R" list --agent reviewer-a 2>/dev/null )"
{ [ "$kind" = codex ] && [ "$prc" = 0 ] && printf '%s' "$dest" | grep -q '/inbox/to/codex/' \
  && printf '%s' "$mine" | grep -q 'opaque'; } \
  && ok "a kind read from the registry routes an id that does not name its kind" \
  || bad "opaque id mishandled (kind=$kind prc=$prc dest=$dest mine=$mine)"

[ "$fails" -eq 0 ] && { echo "route: all passed"; exit 0; }
echo "route: $fails failed" >&2; exit 1

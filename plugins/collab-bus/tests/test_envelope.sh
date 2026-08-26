#!/usr/bin/env bash
# Tests for the v0.8 envelope foundation: shared parser, canonical quoting, and the
# version-aware validator.
#
# Case 1 is deliberately first and deliberately about BOTH schemas: the release gate for
# this work is "v0.7 and v0.8 messages pass side by side", not "the new format works".
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CHECK="$DIR/scripts/check-envelope.sh"
QUOTE="$DIR/scripts/fm-quote.sh"
. "$DIR/scripts/lib/envelope.sh"
fails=0
ok()  { echo "  ok   - $1"; }
bad() { echo "  FAIL - $1" >&2; fails=$((fails+1)); }
ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$ROOT"' EXIT
mk() { local p="$ROOT/$1"; shift; printf '%s\n' "$@" > "$p"; printf '%s' "$p"; }

V1="$(mk v1.md '---' \
  'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'pair: w3:t6' 'from: claude' 'to: codex' \
  'type: review-request' 'subject: a plain legacy subject' \
  'refs: HEAD 850aa15' 'status: open' '---' '' 'body')"
V2="$(mk v2.md '---' \
  'schema: 2' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'thread: 01M0WG3WJF6AX39B2RGCPVN2CM' \
  'from: claude' 'to: codex' 'from_agent: claude-primary' 'to_agent: codex-primary' \
  'intent: action' 'type: review-request' "subject: 'quoted: with a colon'" \
  "refs: 'it''s fine'" 'status: open' 'pair: w3:t6' '---' '' 'body')"

# --- 1. THE release gate: both schemas validate, side by side ----------------
if bash "$CHECK" "$V1" "$V2" >/dev/null 2>&1; then
  ok "v0.7 (schema 1) and v0.8 (schema 2) messages both pass, side by side"
else
  bad "side-by-side validation failed"; bash "$CHECK" "$V1" "$V2" 2>&1 | sed 's/^/        /'
fi

# --- 2. schema detection -----------------------------------------------------
s1="$(envelope_schema_of "$V1")"; s2="$(envelope_schema_of "$V2")"
[ "$s1" = 1 ] && [ "$s2" = 2 ] && ok "schema is 1 when absent, 2 when declared" \
                               || bad "schema detection wrong (got $s1 / $s2)"

# --- 3. round-trip: quote then read back gives the original ------------------
r3=0
for s in "plain" "has: a colon" "it's got an apostrophe" "both: it's here" \
         'quotes "inside"' 'trailing colon:' '#leading hash' '[bracket'; do
  q="$(bash "$QUOTE" "$s")"
  f="$(mk rt.md '---' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'to: codex' \
       'type: task' "subject: $q" 'status: open' '---')"
  bash "$CHECK" --quiet "$f" || { echo "        gate rejected: $s -> $q" >&2; r3=1; continue; }
  got="$(fm_get "$f" subject)"
  [ "$got" = "$s" ] || { echo "        round-trip: wrote [$s] read [$got]" >&2; r3=1; }
done
[ "$r3" = 0 ] && ok "hostile subjects round-trip through quote → gate → read" \
              || bad "round-trip failure"

# --- 4. a newline in a value is refused, not folded --------------------------
if out="$(bash "$QUOTE" "$(printf 'two\nlines')" 2>&1)"; then
  bad "a newline value was accepted: $out"
else
  printf '%s' "$out" | grep -q newline && ok "a newline in a scalar is refused with a clear message" \
                                       || bad "newline refused but not explained: $out"
fi

# --- 5. the real bug this exists for: unquoted ': ' is rejected --------------
BAD="$(mk bad.md '---' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'to: codex' \
  'type: task' 'subject: Plan review: draft 2' 'status: open' '---')"
if bash "$CHECK" --quiet "$BAD"; then
  bad "an unquoted value containing ': ' was accepted"
else
  ok "an unquoted value containing ': ' is rejected (the live-bus bug)"
fi

# --- 6. schema 2 demands quoting even when the value is harmless -------------
S2P="$(mk s2plain.md '---' 'schema: 2' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' \
  'thread: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'to: codex' \
  'from_agent: claude-primary' 'to_agent: codex-primary' 'intent: action' \
  'type: task' 'subject: harmless but unquoted' 'status: open' '---')"
bash "$CHECK" --quiet "$S2P" && bad "schema 2 accepted an unquoted human scalar" \
                             || ok "schema 2 requires single-quoted human scalars"

# --- 7. unpaired apostrophe inside a quoted value is caught -----------------
UNP="$(mk unpaired.md '---' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'to: codex' \
  'type: task' "subject: 'it's unpaired'" 'status: open' '---')"
bash "$CHECK" --quiet "$UNP" && bad "an unpaired apostrophe was accepted" \
                             || ok "an unpaired apostrophe in a quoted value is caught"

# --- 8. machine tokens are shape-checked ------------------------------------
r8=0
check_rejects() { # <label> <line to substitute>
  local f; f="$(mk mach.md '---' 'schema: 2' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' \
    'thread: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'to: codex' \
    'from_agent: claude-primary' 'to_agent: codex-primary' 'intent: action' \
    'type: task' "subject: 'x'" "$1" '---')"
  bash "$CHECK" --quiet "$f" && { echo "        accepted bad: $1" >&2; r8=1; }
}
check_rejects 'outcome: maybe'
check_rejects 'intent: whenever'
check_rejects 'reply_to: not-a-ulid'
check_rejects 'pair: nonsense'
check_rejects 'unknown_key: x'
[ "$r8" = 0 ] && ok "bad outcome/intent/ULID/pair and unknown keys are all rejected" \
              || bad "a malformed machine token was accepted"

# --- 9. missing required keys are reported ----------------------------------
MISS="$(mk miss.md '---' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'type: task' \
  "subject: 'x'" 'status: open' '---')"
out="$(bash "$CHECK" "$MISS" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "required key 'to'"; } \
  && ok "a missing required key is named in the error" || bad "missing-key report wrong"

# --- 10. structural damage is diagnosed, not guessed at ---------------------
NOD="$(mk nodelim.md 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude')"
UNC="$(mk unclosed.md '---' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude')"
o1="$(bash "$CHECK" "$NOD" 2>&1)"; o2="$(bash "$CHECK" "$UNC" 2>&1)"
{ printf '%s' "$o1" | grep -q "opening ---" && printf '%s' "$o2" | grep -q "never closed"; } \
  && ok "missing and unclosed frontmatter are each diagnosed specifically" \
  || bad "structural diagnosis wrong: [$o1] [$o2]"

# --- 11. a bad file does not stop the others being checked ------------------
BAD2="$(mk bad2.md '---' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'to: codex' \
  'type: task' 'subject: also broken: here' 'status: open' '---')"
# bad, GOOD, bad — asserting BOTH bad files are reported proves the loop did not stop at
# the first one (a version that exits early would still name bad.md and look fine).
out="$(bash "$CHECK" "$BAD" "$V1" "$BAD2" 2>&1)"; rc=$?
{ [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "bad.md" && printf '%s' "$out" | grep -q "bad2.md"; } \
  && ok "a bad file after a good one is still reported (batch does not stop early)" \
  || bad "batch validation stopped early (rc=$rc)"

# --- 12. the live bus: no unknown keys, and the known damage is pinned ------
# Guards against the allowlist being too narrow (which would lock the running bus out of
# its own gate). The broken count is an UPPER BOUND on pre-existing damage, not an exact
# pin — a validator that regressed to reporting nothing would also satisfy it.
# Opt-in: hard-coding one machine's path makes a test that silently skips everywhere
# else. The unit guarantees live in the fixed fixtures above; this is an audit.
BUS="${COLLAB_LIVE_BUS:-}"
if [ -n "$BUS" ] && [ -d "$BUS" ]; then
  unknown=0; broken=0; total=0
  while IFS= read -r f; do
    total=$((total+1))
    err="$(envelope_check "$f" 2>&1)" || true
    printf '%s' "$err" | grep -q "not in the schema" && unknown=$((unknown+1))
    printf '%s' "$err" | grep -q "not valid YAML" && broken=$((broken+1))
  done < <(find "$BUS" -name '*.md' 2>/dev/null)
  if [ "$unknown" = 0 ] && [ "$broken" -le 13 ] && [ "$total" -gt 100 ]; then
    ok "live bus ($total msgs): 0 unknown keys, $broken with the known YAML damage (<=13)"
  else
    bad "live-bus scan: total=$total unknown=$unknown broken=$broken (expected 0 unknown, <=13 broken)"
  fi
else
  echo "  skip - live-bus audit (set COLLAB_LIVE_BUS=<inbox dir> to run it)"
fi

# --- 13. required keys must carry a VALUE, not merely appear ------------------
EMPTY="$(mk empty.md '---' 'id:' 'from:' 'to:' 'type:' 'subject:' 'status:' '---')"
bash "$CHECK" --quiet "$EMPTY" && bad "an envelope of empty required keys was accepted" \
                              || ok "empty required values are rejected (presence is not enough)"

# --- 14. a duplicate key is refused rather than silently resolved ------------
# fm_get takes the first; Ruby and PyYAML take the last. Whoever reads it would route
# differently, so there is no safe winner to pick.
DUP="$(mk dup.md '---' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'to: codex' \
  'to: gemini' 'type: task' "subject: 'x'" 'status: open' '---')"
out="$(bash "$CHECK" "$DUP" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "more than once"; } \
  && ok "a duplicate key is rejected (readers would disagree on the value)" \
  || bad "duplicate key accepted (rc=$rc)"

# --- 15. --quiet validates exactly as much as the loud mode -----------------
# A structure-bearing plain scalar: the zero-dependency lint must catch it, so that the
# result does not depend on whether a YAML parser happens to be installed.
STRUCT="$(mk struct.md '---' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'to: codex' \
  'type: task' 'subject: - this is parsed as a sequence' 'status: open' '---')"
bash "$CHECK" "$STRUCT" >/dev/null 2>&1; loud=$?
bash "$CHECK" --quiet "$STRUCT" >/dev/null 2>&1; quiet=$?
{ [ "$loud" = "$quiet" ] && [ "$loud" != 0 ]; } \
  && ok "--quiet returns the same verdict as loud mode (suppresses output only)" \
  || bad "quiet/loud disagree (loud=$loud quiet=$quiet)"

# --- 16. the gate stands up with NO YAML parser available -------------------
# The optional parser is a strengthening; the dependency-free lint must reject these on
# its own, or a peer without ruby/python would publish what we reject.
STUB="$ROOT/nostub"; mkdir -p "$STUB"
for prog in ruby python3 python; do printf '#!/bin/sh\nexit 127\n' > "$STUB/$prog"; chmod +x "$STUB/$prog"; done
r16=0
for f in "$BAD" "$STRUCT"; do
  PATH="$STUB:$PATH" bash "$CHECK" --quiet "$f" && { echo "        accepted without a parser: $f" >&2; r16=1; }
done
PATH="$STUB:$PATH" bash "$CHECK" --quiet "$V1" "$V2" || { echo "        rejected valid files without a parser" >&2; r16=1; }
[ "$r16" = 0 ] && ok "with no YAML parser on PATH the lint still rejects bad and accepts good" \
               || bad "zero-dependency gate is not fail-closed"

# --- 17. fm-quote reads stdin losslessly and refuses control characters -----
r17=0
got="$(printf 'trailing newline\n' | bash "$QUOTE" - 2>&1)" && { echo "        stdin newline accepted: $got" >&2; r17=1; }
got="$(bash "$QUOTE" "$(printf 'has\ttab')" 2>&1)" && { echo "        tab accepted: $got" >&2; r17=1; }
got="$(bash "$QUOTE" "$(printf 'has\rcr')" 2>&1)" && { echo "        CR accepted: $got" >&2; r17=1; }
got="$(printf 'no trailing newline' | bash "$QUOTE" -)" || { echo "        rejected a clean stdin value" >&2; r17=1; }
[ "$got" = "'no trailing newline'" ] || { echo "        stdin value mangled: [$got]" >&2; r17=1; }
[ "$r17" = 0 ] && ok "fm-quote refuses newline/tab/CR and reads stdin without mangling" \
               || bad "fm-quote control-character handling wrong"

# --- 18. schema 2 round-trips an apostrophe through fm_get ------------------
Q="$(bash "$QUOTE" "it's a schema-2 subject: really")"
S2R="$(mk s2rt.md '---' 'schema: 2' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' \
  'thread: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'to: codex' \
  'from_agent: claude-primary' 'to_agent: codex-primary' 'intent: action' \
  'type: task' "subject: $Q" 'status: open' '---')"
if bash "$CHECK" --quiet "$S2R" && [ "$(fm_get "$S2R" subject)" = "it's a schema-2 subject: really" ]; then
  ok "a schema-2 apostrophe subject round-trips through the gate and back"
else
  bad "schema-2 round-trip failed: [$(fm_get "$S2R" subject)]"
fi

# --- 19. the documented example must pass the gate it documents ------------
# Instructions and executable grammar drift apart silently: the template's own sample
# carried inline comments that the validator reads as part of the value, so anyone
# copying it would have been rejected. Extract the sample and run it.
TPL="$DIR/templates/PROTOCOL.template.md"
SAMPLE="$ROOT/sample.md"
awk '/^```markdown$/{f=1;next} /^```$/{if(f)exit} f' "$TPL" | sed 's/{{PEER}}/codex/g' > "$SAMPLE"
if [ -s "$SAMPLE" ] && bash "$CHECK" "$SAMPLE" >/dev/null 2>&1; then
  ok "the frontmatter sample in PROTOCOL.template.md passes the gate"
else
  bad "the documented sample is rejected by its own validator"
  bash "$CHECK" "$SAMPLE" 2>&1 | sed 's/^/        /'
fi

# --- 20. control bytes are refused by BOTH the generator and the validator --
# fm_quote used to enumerate only LF/CR/TAB, so a BEL passed through it and Ruby then
# refused the message. A hand-written quoted value never goes through fm_quote at all,
# so the validator must catch it independently — and must do so with no parser present,
# since that is exactly when it is the only guard.
r20=0
for ctl in $'\a' $'\v' $'\f' $'\033' $'\001'; do
  bash "$QUOTE" "bell${ctl}inside" >/dev/null 2>&1 && { echo "        fm-quote accepted a control byte" >&2; r20=1; }
done
CTL="$(mk ctl.md '---' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'to: codex' \
  'type: task' "subject: 'has a $(printf '\a') bell'" 'status: open' '---')"
PATH="$STUB:$PATH" bash "$CHECK" --quiet "$CTL" && { echo "        validator accepted a quoted control byte with no parser" >&2; r20=1; }
CTLT="$(mk ctlt.md '---' 'id: 01M0WG3WJF6AX39B2RGCPVN2CM' 'from: claude' 'to: codex' \
  'type: task' "subject: 'has a $(printf '\t') tab'" 'status: open' '---')"
PATH="$STUB:$PATH" bash "$CHECK" --quiet "$CTLT" && { echo "        validator accepted a hand-written quoted tab" >&2; r20=1; }
[ "$r20" = 0 ] && ok "control bytes are refused by fm-quote AND by the validator (no parser needed)" \
               || bad "control-byte handling incomplete"

# --- 21. a NUL byte is caught by a RAW-BYTE scan, before bash swallows it ---
# Bash cannot hold a NUL, so $(...) drops it: the lint and the YAML parser both saw a
# clean string while the file on disk stayed unreadable. Only a check on the file itself
# can see this, so it must run before any command substitution.
NUL="$ROOT/nul.md"
{ printf -- '---\nid: 01M0WG3WJF6AX39B2RGCPVN2CM\nfrom: claude\nto: codex\ntype: task\n'
  printf "subject: 'valid'\000\n"
  printf -- 'status: open\n---\n\nbody\n'; } > "$NUL"
r21=0
bash "$CHECK" --quiet "$NUL" && { echo "        validator accepted a NUL" >&2; r21=1; }
PATH="$STUB:$PATH" bash "$CHECK" --quiet "$NUL" && { echo "        accepted a NUL with no parser" >&2; r21=1; }
printf 'has\000nul' | bash "$QUOTE" - >/dev/null 2>&1 && { echo "        fm-quote accepted a NUL on stdin" >&2; r21=1; }
# and the EOF path must still deliver a clean value untouched
got="$(printf 'clean value' | bash "$QUOTE" -)" || { echo "        rejected a clean stdin value" >&2; r21=1; }
[ "$got" = "'clean value'" ] || { echo "        stdin value mangled: [$got]" >&2; r21=1; }
[ "$r21" = 0 ] && ok "a NUL byte is refused by the file scan and by fm-quote's stdin read" \
               || bad "NUL handling incomplete"

# --- a legacy reply REFERENCE is as unrewritable as a legacy id ------------
# The reader tolerates pre-ULID identifiers because those messages are already published.
# The same is true of what they point AT: a v0.4-era reply legitimately carries
# `reply_to: 0077`, so narrowing the tolerance to `id` alone would make every legacy reply
# chain unreadable while the messages themselves stayed perfectly valid.
t="$(mktemp -d)"
printf -- '---\nid: 0078\nfrom: codex\nto: claude\ntype: reply\nsubject: %s\nreply_to: 0077\nstatus: open\n---\nbody\n' \
  "'legacy reply'" > "$t/legacy.md"
envelope_read "$t/legacy.md" >/dev/null 2>&1 \
  && ok "a schema-1 reply_to pointing at a pre-ULID id is readable" \
  || bad "legacy reply chain unreadable"
envelope_check "$t/legacy.md" >/dev/null 2>&1 \
  && bad "the publish gate accepted a pre-ULID reply_to" \
  || ok "the publish gate still requires ULIDs for anything newly written"
rm -rf "$t"

# --- every failure exit leaves the scan state empty, not just the last one -
# "A failed scan leaves nothing behind" was written as an epilogue, so the EARLY returns —
# which are failures too — walked past it. An unknown schema then left ENV_SCHEMA set, and
# `route explain` printed `schema: 3` beside UNREADABLE: a caller reading state from a
# scan that had been refused.
t="$(mktemp -d)"
for probe in 'schema: 3' 'schema: 0'; do
  printf -- '---\n%s\nid: 01M0WG3WJF6AX39B2RGCPVN2CM\nfrom: claude\nto: codex\ntype: task\nsubject: %s\nstatus: open\n---\nbody\n' \
    "$probe" "'x'" > "$t/unknown.md"
  envelope_read "$t/unknown.md" >/dev/null 2>&1; rc=$?
  { [ "$rc" != 0 ] && [ -z "$ENV_SCHEMA" ] && [ "$_ENV_N" = 0 ]; } \
    && ok "an unknown schema ($probe) fails and leaves no scan state behind" \
    || bad "early failure kept state ($probe: rc=$rc ENV_SCHEMA='$ENV_SCHEMA' n=$_ENV_N)"
done
printf 'no frontmatter\n' > "$t/nofm.md"
envelope_read "$t/nofm.md" >/dev/null 2>&1; rc=$?
{ [ "$rc" != 0 ] && [ -z "$ENV_SCHEMA" ] && [ "$_ENV_N" = 0 ]; } \
  && ok "a file with no frontmatter leaves no scan state behind" \
  || bad "missing-frontmatter failure kept state (rc=$rc)"
rm -rf "$t"

[ "$fails" -eq 0 ] && { echo "envelope: all passed"; exit 0; }
echo "envelope: $fails failed" >&2; exit 1

#!/usr/bin/env bash
# Regression tests for knock.sh's pre-settle state machine (added after peer
# review, collab-bus msgs 0080/0081): the real herdr is replaced by a PATH stub
# so each branch is exercised deterministically and nothing real is knocked.
#
# Covered:
#   1. idle peer            → pre-wait passes, prompt runs, exit 0
#   2. blocked peer         → exit 3 and the prompt is NEVER submitted
#   3. pre-wait herdr error → herdr's exit code passes through (stderr), no prompt
#   4. unparseable pre-wait → exit 4 (fail closed), no prompt (python3 only:
#      without python3 knock deliberately falls back to the substring match,
#      which cannot detect garbage — that trade is documented in knock.sh)
#   5. --submit-only        → NO agent wait, prompt WITHOUT --wait/--timeout,
#      accepted immediately, `submitted, not settled` on stderr (v0.6.1)
#   6. --submit-only blocked → herdr's agent_blocked passes through, no false ok
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOCK="$here/../scripts/knock.sh"
t=0; f=0
ok(){ t=$((t+1)); echo "  ok   - $1"; }
ng(){ t=$((t+1)); f=$((f+1)); echo "  FAIL - $1"; }

tmp="$(mktemp -d)" || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
# knock.sh test stub. Behaviour keyed on HERDR_STUB_MODE; every invocation is
# appended to HERDR_STUB_LOG so the test can assert what was (not) called.
echo "$*" >>"${HERDR_STUB_LOG:?}"
case "$1 $2" in
  "agent list") echo '{"result":{"agents":[]}}' ;;
  "agent wait")
    case "${HERDR_STUB_MODE:?}" in
      idle)    echo '{"id":"t","result":{"agent":{"agent_status":"idle"},"type":"agent_info"}}' ;;
      blocked) echo '{"id":"t","result":{"agent":{"agent_status":"blocked"},"type":"agent_info"}}' ;;
      waiterr) echo '{"error":{"code":"agent_not_found"},"id":"t"}' >&2; exit 1 ;;
      garbage) echo 'not json at all' ;;
    esac ;;
  "agent prompt")
    case "${HERDR_STUB_MODE:?}" in
      promptblocked) echo '{"error":{"code":"agent_blocked"},"id":"t"}' >&2; exit 7 ;;
      *) echo '{"id":"t","result":{"agent":{"agent_status":"working"},"type":"agent_prompted"}}' ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/herdr"
export PATH="$tmp/bin:$PATH"
export HERDR_STUB_LOG="$tmp/calls.log"

run(){ : >"$HERDR_STUB_LOG"; HERDR_STUB_MODE="$1" bash "$KNOCK" w9:p9 "test nudge" >"$tmp/out" 2>"$tmp/err"; echo $?; }
# runk: like run but pass arbitrary knock args (for --submit-only).
runk(){ : >"$HERDR_STUB_LOG"; local m="$1"; shift; HERDR_STUB_MODE="$m" bash "$KNOCK" "$@" >"$tmp/out" 2>"$tmp/err"; echo $?; }

rc="$(run idle)"
if [ "$rc" = 0 ] && grep -q "^agent prompt" "$HERDR_STUB_LOG" && grep -q agent_prompted "$tmp/out"; then
  ok "idle peer: pre-wait passes, prompt submitted, result on stdout"
else ng "idle peer (rc=$rc)"; fi

rc="$(run blocked)"
if [ "$rc" = 3 ] && ! grep -q "^agent prompt" "$HERDR_STUB_LOG"; then
  ok "blocked peer: exit 3 and the prompt is never submitted"
else ng "blocked peer (rc=$rc)"; fi

rc="$(run waiterr)"
if [ "$rc" = 1 ] && ! grep -q "^agent prompt" "$HERDR_STUB_LOG" && grep -q agent_not_found "$tmp/err"; then
  ok "pre-wait error: herdr's rc passes through, error stays on stderr, no prompt"
else ng "pre-wait error (rc=$rc)"; fi

if command -v python3 >/dev/null 2>&1; then
  rc="$(run garbage)"
  if [ "$rc" = 4 ] && ! grep -q "^agent prompt" "$HERDR_STUB_LOG"; then
    ok "unparseable pre-wait result: exit 4, no prompt (fail closed)"
  else ng "unparseable pre-wait (rc=$rc)"; fi
else
  echo "  skip - unparseable case needs python3"
fi

# 5. --submit-only: no pre-settle, prompt carries no --wait/--timeout, accepted.
rc="$(runk idle --submit-only w9:p9 "n")"
if [ "$rc" = 0 ] \
   && ! grep -q "^agent wait" "$HERDR_STUB_LOG" \
   && grep -q "^agent prompt" "$HERDR_STUB_LOG" \
   && ! grep -qE "^agent prompt.*--wait" "$HERDR_STUB_LOG" \
   && ! grep -qE "^agent prompt.*--timeout" "$HERDR_STUB_LOG" \
   && grep -q agent_prompted "$tmp/out" \
   && grep -q "submitted, not settled" "$tmp/err"; then
  ok "submit-only: no agent wait, prompt without --wait/--timeout, accepted + marker"
else ng "submit-only basic (rc=$rc)"; fi

# 6. --submit-only to a peer herdr rejects: agent_blocked passes through, no marker.
rc="$(runk promptblocked --submit-only w9:p9 "n")"
if [ "$rc" = 7 ] \
   && ! grep -q "^agent wait" "$HERDR_STUB_LOG" \
   && grep -q agent_blocked "$tmp/err" \
   && ! grep -q "submitted, not settled" "$tmp/err"; then
  ok "submit-only: herdr's exact rc (7) passes through, no false 'submitted'"
else ng "submit-only blocked passthrough (rc=$rc, want 7)"; fi

echo "knock: $((t-f))/$t passed"
[ "$f" -eq 0 ]

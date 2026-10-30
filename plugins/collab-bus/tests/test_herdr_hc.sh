#!/usr/bin/env bash
# Tests for herdr.sh's backend choice and the Herdr App translation (lib/herdr_hc.py).
# Both the herdr and herdr-core CLIs are replaced by stubs, so nothing real is touched.
#
# Covered:
#   1. auto picks hc inside a Herdr App terminal and herdr outside; overrides win
#   2. pane current is the CALLER ($HC_TERMINAL_ID), with its Herdr App tab
#   3. a terminal started by `hc run` (no tab label) inherits its parent's tab
#   4. agent list skips shells and reports claude-code as claude
#   5. a blocked peer is refused with agent_blocked and nothing is sent
#   6. prompt --wait keeps waiting when hc's wait ended on a message to the caller
#   7. ms timeouts become hc seconds; an unknown terminal is agent_not_found
#   8. knock.sh runs end to end over the hc backend
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$here/../scripts/herdr.sh"
KNOCK="$here/../scripts/knock.sh"
t=0; f=0
ok(){ t=$((t+1)); echo "  ok   - $1"; }
ng(){ t=$((t+1)); f=$((f+1)); echo "  FAIL - $1"; }

tmp="$(mktemp -d)" || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"${STUB_LOG:?}"
echo '{"result":{"pane":{"pane_id":"w9:p9","tab_id":"w9:t9"}}}'
EOF

cat >"$tmp/bin/hc" <<'EOF'
#!/usr/bin/env bash
# herdr-core stub. Terminals: t3 caller (claude, tab label), t4 codex child of t3 (no
# label), t5 zsh. PEER_STATUS sets t4's status; WAIT_REASONS is a queue of reasons that
# successive waits on t4 return.
echo "hc $*" >>"${STUB_LOG:?}"
term() { # addr agent status labels parent
  printf '{"address":"%s","created_ms":100,"cwd":"/w","labels":%s,"parent":%s,"name":null,"status":{"app":"%s","state":"%s"},"title":"x","turn":1}\n' "$1" "$4" "$5" "$2" "$3"
}
case "$1" in
  --version) echo "hc 0.1.14" ;;
  server) echo '{"version":"0.1.14"}' ;;
  ls) echo '{"terminals":[{"address":"t3","agent":"claude-code","state":"live"},{"address":"t4","agent":"codex","state":"live"},{"address":"t5","agent":"zsh","state":"live"}]}' ;;
  get)
    case "$2" in
      t3) term t3 claude-code working '{"herdr.tab":"tbA","herdr.space":"spA"}' null ;;
      t4) term t4 codex "${PEER_STATUS:-idle}" '{}' '"t3"' ;;
      *) echo '{"error":{"kind":"not_found","message":"no terminal"}}' >&2; exit 3 ;;
    esac ;;
  send)
    if [ "${4:-}" = "--wait" ]; then
      r="$(head -1 "$WAIT_REASONS" 2>/dev/null)"; sed -i.b 1d "$WAIT_REASONS" 2>/dev/null
      echo "{\"started\":true,\"status\":\"working\",\"turn\":1,\"wait\":{\"reason\":\"${r:-status}\",\"status\":$([ "${r:-status}" = status ] && echo '"done"' || echo null),\"exit_code\":null,\"signal\":null}}"
    else echo '{"started":true,"status":"working","turn":1}'; fi ;;
  wait)
    r="$(head -1 "$WAIT_REASONS" 2>/dev/null)"; sed -i.b 1d "$WAIT_REASONS" 2>/dev/null
    echo "{\"reason\":\"${r:-status}\",\"status\":$([ "${r:-status}" = status ] && echo '"done"' || echo null),\"exit_code\":null,\"signal\":null}" ;;
  read) echo "screen of $2" ;;
esac
EOF
chmod +x "$tmp/bin/herdr" "$tmp/bin/hc"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" COLLAB_HC_BIN="$tmp/bin/hc" WAIT_REASONS="$tmp/reasons"
unset COLLAB_HERDR_BACKEND
J(){ python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
reset(){ : >"$STUB_LOG"; : >"$WAIT_REASONS"; }

# 1. backend choice
reset
[ "$(HC_TERMINAL_ID=t3 "$H" --backend)" = hc ] && [ "$(env -u HC_TERMINAL_ID "$H" --backend)" = herdr ] \
  && [ "$(HC_TERMINAL_ID=t3 COLLAB_HERDR_BACKEND=herdr "$H" --backend)" = herdr ] \
  && ok "auto: hc inside Herdr App, herdr outside; COLLAB_HERDR_BACKEND overrides" \
  || ng "backend choice"
reset; env -u HC_TERMINAL_ID "$H" pane current --current >/dev/null
grep -q '^herdr pane current' "$STUB_LOG" && ! grep -q '^hc' "$STUB_LOG" \
  && ok "outside Herdr App every call passes straight to herdr" || ng "herdr passthrough"

export HC_TERMINAL_ID=t3
# 2. caller identity
reset; out="$("$H" pane current --current)"
[ "$(printf '%s' "$out" | J 'd["result"]["pane"]["pane_id"]+" "+d["result"]["pane"]["tab_id"]+" "+d["result"]["pane"]["agent"]')" = "t3 tbA claude" ] \
  && ! grep -q '^herdr' "$STUB_LOG" \
  && ok "pane current is the caller's terminal and tab, never the herdr server's focus" \
  || ng "pane current ($out)"

# 3. + 4. list
reset; out="$("$H" agent list)"
v="$(printf '%s' "$out" | J '" ".join(a["pane_id"]+":"+a["agent"]+":"+a["tab_id"]+":"+a["workspace_id"] for a in d["result"]["agents"])')"
[ "$v" = "t3:claude:tbA:spA t4:codex:tbA:spA" ] \
  && ok "agent list: shells skipped, claude-code→claude, hc-run child inherits the tab" \
  || ng "agent list ($v)"

# 5. blocked peer
reset; err="$(PEER_STATUS=blocked "$H" agent prompt t4 hi --wait 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$err" | grep -q agent_blocked && ! grep -q '^hc send' "$STUB_LOG" \
  && ok "blocked peer → agent_blocked, nothing sent" || ng "blocked peer (rc=$rc $err)"

# 6. early wake on a message to the caller
reset; printf 'message\n' >"$WAIT_REASONS"
out="$("$H" agent prompt t4 hi --wait --timeout 60000)"; rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s' "$out" | J 'd["result"]["agent"]["agent_status"]')" = done ] \
  && grep -q '^hc wait t4' "$STUB_LOG" \
  && ok "prompt --wait waits again after a message ended hc's wait" || ng "early wake (rc=$rc $out)"

# 7. units and errors
reset; "$H" agent wait t4 --timeout 1500 >/dev/null
grep -q '^hc wait t4 --timeout 2 --json' "$STUB_LOG" && ok "1500 ms → hc --timeout 2 s" || ng "timeout units ($(cat "$STUB_LOG"))"
reset; err="$("$H" agent get t99 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$err" | grep -q agent_not_found && ok "unknown terminal → agent_not_found" || ng "not found ($err)"

# 8. knock end to end
reset; out="$(bash "$KNOCK" t4 "process x" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && grep -q '^hc send t4 process x --wait' "$STUB_LOG" && ! grep -q '^herdr' "$STUB_LOG" \
  && ok "knock.sh settles and prompts through hc" || ng "knock (rc=$rc $(cat "$STUB_LOG"))"

if [ "$f" -eq 0 ]; then echo "herdr-hc: $t/$t passed"; else echo "herdr-hc: $f failed"; exit 1; fi

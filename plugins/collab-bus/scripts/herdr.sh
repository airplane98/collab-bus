#!/usr/bin/env bash
# collab-bus herdr frontend — the ONE way scripts (and the docs' manual commands) reach
# herdr, so the same bus runs under either of the two herdr products:
#
#   herdr      the terminal multiplexer (TUI) — panes `w1:p2`, `herdr agent …`
#   Herdr App  herdr-core (`hc`) + herdr-app  — terminals `t3`, `hc send/wait/read`
#
# They are separate servers that cannot see each other's terminals. Inside Herdr App the
# plain `herdr` binary still answers — from the OTHER server — so `herdr pane current`
# returns whatever TUI pane is focused and `herdr agent prompt` can knock a stranger.
# That failure is silent, which is why this frontend exists instead of a doc warning.
#
# Backend choice (COLLAB_HERDR_BACKEND):
#   auto (default) — hc when this process runs in a Herdr App terminal ($HC_TERMINAL_ID
#                    set) and herdr-core is installed; herdr otherwise.
#   hc | herdr     — force one.
# The hc backend translates the herdr CLI subset collab-bus uses (lib/herdr_hc.py) and
# prints herdr-shaped JSON, so callers parse one format.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_hc_bin() {
  if [ -n "${COLLAB_HC_BIN:-}" ]; then printf '%s' "$COLLAB_HC_BIN"; return 0; fi
  command -v herdr-core 2>/dev/null && return 0
  return 1
}

backend="${COLLAB_HERDR_BACKEND:-auto}"
if [ "$backend" = auto ]; then
  if [ -n "${HC_TERMINAL_ID:-}" ] && _hc_bin >/dev/null; then backend=hc; else backend=herdr; fi
fi

# `herdr.sh --backend` prints the chosen backend and exits 0 only if it is usable — the
# availability probe callers use instead of `command -v herdr`.
if [ "${1:-}" = "--backend" ]; then
  case "$backend" in
    herdr) command -v herdr >/dev/null 2>&1 || exit 1 ;;
    hc)    _hc_bin >/dev/null && command -v python3 >/dev/null 2>&1 || exit 1 ;;
    *)     exit 2 ;;
  esac
  echo "$backend"; exit 0
fi

case "$backend" in
  herdr)
    command -v herdr >/dev/null 2>&1 || { echo "herdr not found (https://herdr.dev)." >&2; exit 1; }
    exec herdr "$@" ;;
  hc)
    hc="$(_hc_bin)" || { echo "herdr-core (hc) not found — install Herdr App or set COLLAB_HERDR_BACKEND=herdr." >&2; exit 1; }
    command -v python3 >/dev/null 2>&1 || { echo "the Herdr App backend needs python3." >&2; exit 1; }
    COLLAB_HC_BIN="$hc" exec python3 "$here/lib/herdr_hc.py" "$@" ;;
  *)
    echo "COLLAB_HERDR_BACKEND must be auto, hc or herdr (got '$backend')." >&2; exit 2 ;;
esac

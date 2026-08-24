#!/usr/bin/env bash
# Guard against the failure this project kept repeating: correct new guidance is
# added while the contradicting old lines stay on the next page. Greps the docs
# that steer an agent for patterns v0.3.x replaced.
#
# Usage: doclint.sh [plugin-dir]   (default: the directory above this script)
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
fail=0
check() { # <label> <regex> <files...>
  local label="$1" re="$2"; shift 2
  local hits
  # A doc may legitimately NAME a banned pattern in order to forbid it. Lines
  # carrying a negation marker are prohibitions, not instructions.
  local neg='never|not |do not|don.t|instead of|misroute|replaced|predates|rather than|不要|勿|禁止|不得|而非'
  hits="$(grep -rnE "$re" "$@" 2>/dev/null | grep -v 'doclint' | grep -viE "$neg" || true)"
  if [ -n "$hits" ]; then
    echo "FAIL: $label"; printf '%s\n' "$hits" | sed 's/^/      /'; fail=1
  else
    echo "ok:   $label"
  fi
}
DOCS="$ROOT/commands $ROOT/skills $ROOT/templates"
check "no hand-computed ids"        'highest .?NNNN|max\+1|highest \+ 1' $DOCS
check "no fixed onboarding numbers" '000[12]-onboarding' $DOCS
check "no 'newest/latest open' as an instruction" '讀最新 .?open|newest open message|latest open' $DOCS
check "no kind-name knock"          'knock\.sh" <(peer|PEER)>|knock\.sh <對方>' $DOCS
check "no herdr agent list --json"  'agent list --json' $DOCS
exit $fail

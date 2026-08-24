#!/usr/bin/env bash
# Guard against the failure this project kept repeating: correct new guidance is
# added while the contradicting old lines stay on the next page. Greps the docs
# that steer an agent for patterns the current version replaced.
#
# A linter that can pass without having looked at anything is worse than none, so
# every fail-open path is closed: missing or unreadable targets FAIL, grep's
# "error" exit (2) is distinguished from its "no match" exit (1), and the
# linter excludes itself by exact path rather than by matching the string
# "doclint" anywhere in the output.
#
# KNOWN LIMITATION: a line carrying a negation marker is treated as a
# prohibition and skipped. If one line contains BOTH a prohibition and a real
# offending command, that line is a false negative. Closing this would require
# parsing rather than grep; the trade was taken deliberately.
#
# Usage: doclint.sh [plugin-dir]     lint a plugin tree (default: ../ of this file)
#        doclint.sh --self-test      verify the linter itself cannot pass blindly
set -uo pipefail

NEG='never|not |do not|don.t|instead of|misroute|replaced|predates|rather than|不要|勿|禁止|不得|而非'
fail=0

check() { # <label> <regex> <target...>
  local label="$1" re="$2"; shift 2
  local out rc hits
  out="$(grep -rnE -- "$re" "$@" 2>&1)"; rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "FAIL: $label — grep failed (exit $rc), NOT a clean pass"
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=1; return
  fi
  if [ "$rc" -eq 1 ]; then echo "ok:   $label"; return; fi
  # Exclude the linter itself by exact path (field 1 of grep -rn output), never
  # by matching "doclint" anywhere — a plugin dir named .../doclint-test/ would
  # otherwise delete every genuine hit and report all-green.
  hits="$(printf '%s\n' "$out" | awk -F: '$1 !~ /\/doclint\.sh$/' | grep -viE "$NEG" || true)"
  if [ -n "$hits" ]; then
    echo "FAIL: $label"; printf '%s\n' "$hits" | sed 's/^/      /'; fail=1
  else
    echo "ok:   $label"
  fi
}

run_lint() {
  local ROOT="$1"
  local d
  for d in commands skills templates scripts; do
    if [ ! -d "$ROOT/$d" ] || [ ! -r "$ROOT/$d" ]; then
      echo "FAIL: expected directory missing or unreadable: $ROOT/$d"
      return 1
    fi
  done
  local DOCS=("$ROOT/commands" "$ROOT/skills" "$ROOT/templates")
  fail=0
  check "no hand-computed ids"        'highest .?NNNN|max\+1|highest \+ 1' "${DOCS[@]}"
  check "no fixed onboarding numbers" '000[12]-onboarding|archive .?0001|read .?0002' "${DOCS[@]}"
  check "no 'newest/latest open' as an instruction" '讀最新 .?open|newest open message|latest open' "${DOCS[@]}"
  check "no kind-name knock"          'knock\.sh" <(peer|PEER)>|knock\.sh <對方>' "${DOCS[@]}"
  check "no herdr agent list --json"  'agent list --json' "${DOCS[@]}"
  # The PROTOCOL template is copied verbatim into a project, where the peer CLI
  # has no CLAUDE_PLUGIN_ROOT. commands/ and skills/ may reference the plugin
  # path as a fallback, so this rule is scoped to templates only.
  check "template must use the vendored allocator" \
        'CLAUDE_PLUGIN_ROOT./scripts/next-id\.sh' "$ROOT/templates"
  # A suggested cleanup command must target the lock itself. "$LOCK/.." is the
  # collab root — never put a broad parent in a copy-pasteable rm/rmdir.
  check "no rm/rmdir aimed at a parent dir" \
        '(rmdir|rm -rf|rm -f)[^\n]*\$LOCK/\.\.' "$ROOT/scripts"
  return $fail
}

self_test() {
  local here me tmp root rc t=0 f=0
  me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  here="$(dirname "$me")/.."
  ok() { t=$((t+1)); echo "  ✓ $1"; }
  ng() { t=$((t+1)); f=$((f+1)); echo "  ✗ $1"; }

  # 1. A root whose PATH contains "doclint" and a space must still catch a bug.
  tmp="$(mktemp -d)"; root="$tmp/doclint regression/plugin"
  mkdir -p "$root"; cp -R "$here"/{commands,skills,templates,scripts} "$root"/ 2>/dev/null
  printf '\nDEST=$("${CLAUDE_PLUGIN_ROOT}/scripts/next-id.sh" x y w1:t1)\n' \
    >> "$root/templates/PROTOCOL.template.md"
  bash "$me" "$root" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && ok "bug in a path containing 'doclint' and a space is caught" \
                  || ng "FAIL-OPEN: bug hidden by the path name"
  rm -rf "$tmp"

  # 2. A nonexistent root must not report success.
  bash "$me" "/nonexistent/$$-no-such-plugin" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && ok "missing target directory fails" \
                  || ng "FAIL-OPEN: missing target reported as clean"
  rm -rf "$tmp"

  # 3. The real tree must be clean.
  bash "$me" "$here" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "current tree is clean" || ng "current tree has findings"

  echo "self-test: $((t-f))/$t passed"
  [ "$f" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
  self_test; exit $?
fi
run_lint "${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
exit $?

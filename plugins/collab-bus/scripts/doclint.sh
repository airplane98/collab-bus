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
  local d f
  for d in commands skills templates scripts; do
    if [ ! -d "$ROOT/$d" ] || [ ! -r "$ROOT/$d" ]; then
      echo "FAIL: expected directory missing or unreadable: $ROOT/$d"
      return 1
    fi
  done
  # Four empty directories would otherwise satisfy every rule and print all-green.
  # Require the files the rules are actually about.
  for f in commands/init.md commands/send.md commands/status.md \
           skills/collab/SKILL.md templates/PROTOCOL.template.md \
           scripts/next-id.sh scripts/publish.sh scripts/knock.sh; do
    if [ ! -f "$ROOT/$f" ] || [ ! -r "$ROOT/$f" ]; then
      echo "FAIL: expected file missing or unreadable: $ROOT/$f"
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
  # v0.4.0 made the transport a guarded two-step (agent wait, then prompt
  # --wait) with a documented residual window. Claims of atomicity oversell it.
  check "no atomic-transport claims" \
        'atomic submit\+wait|submit \+ wait is atomic|submit \+ wait, atomic|送\+等，原子' \
        "${DOCS[@]}" "$ROOT/scripts"
  # The reverse (peer → Claude) knock must go through the vendored knock.sh —
  # a bare `agent prompt --wait` at the peer reintroduces the turn race there.
  check "no bare reverse agent-prompt knock" \
        'agent prompt <claude_pane_id' "$ROOT/templates"
  # The knock's worst-case block is ~2x COLLAB_WAIT_MS (pre-settle + own wait);
  # a bare 1x claim understates it. {0,2} covers "up to COLLAB_WAIT_MS" with or
  # without a backtick/$ in between while letting "up to ~2x `COLLAB..." pass.
  check "no single-timeout claim for the knock" \
        'up to .{0,2}COLLAB_WAIT_MS' "${DOCS[@]}"
  # v0.4.1 moved the id lock out of the synced tree (sync engines resurrect a
  # released in-tree lock as an ownerless ghost). Docs must not send anyone
  # looking for — or cleaning up — a lock at collab/.idlock again.
  check "no in-tree idlock references" \
        'collab/\.idlock' "${DOCS[@]}"
  return $fail
}

self_test() {
  local me here tmp root out rc t=0 f=0
  me="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  here="$(cd "$(dirname "$me")/.." && pwd)"
  ok() { t=$((t+1)); echo "  ✓ $1"; }
  ng() { t=$((t+1)); f=$((f+1)); echo "  ✗ $1"; }

  tmp="$(mktemp -d)" || { echo "  ✗ fixture setup: mktemp failed"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # --- 1. A bug must be caught even when the ROOT PATH contains "doclint" and a
  #        space. The oracle asserts the SPECIFIC finding, not merely a non-zero
  #        exit: a half-copied fixture also exits non-zero, and counting that as
  #        success is how a self-test passes without testing anything.
  root="$tmp/doclint regression/plugin"
  if ! mkdir -p "$root" \
     || ! cp -R "$here/commands" "$here/skills" "$here/templates" "$here/scripts" "$root/" \
     || ! printf '\nDEST=$("${CLAUDE_PLUGIN_ROOT}/scripts/next-id.sh" x y w1:t1)\n' \
          >> "$root/templates/PROTOCOL.template.md"; then
    ng "fixture setup for case 1 failed — case not exercised"
  else
    out="$(bash "$me" "$root" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "FAIL: template must use the vendored allocator"; then
      ok "bug in a path containing 'doclint' and a space is caught"
    else
      ng "FAIL-OPEN: expected the template-allocator finding (exit=$rc)"
    fi
  fi

  # --- 2. A missing target must fail, and for the stated reason.
  out="$(bash "$me" "$tmp/definitely-not-a-plugin" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "expected directory missing or unreadable"; then
    ok "missing target directory fails with the stated reason"
  else
    ng "FAIL-OPEN: missing target not reported correctly (exit=$rc)"
  fi

  # --- 3. An empty-but-present tree must fail too, or "all rules pass" would be
  #        satisfiable by having nothing to read.
  root="$tmp/empty"
  if ! mkdir -p "$root"/{commands,skills,templates,scripts}; then
    ng "fixture setup for case 3 failed — case not exercised"
  else
    out="$(bash "$me" "$root" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "expected file missing or unreadable"; then
      ok "empty tree fails instead of passing every rule"
    else
      ng "FAIL-OPEN: empty tree reported as clean (exit=$rc)"
    fi
  fi

  # --- 3b. Each v0.4 transport rule must catch its own regression — the rules
  #         were added by peer review precisely because self-test 4/4 said
  #         nothing about them. Same oracle discipline as case 1: assert the
  #         SPECIFIC finding, not merely a non-zero exit.
  local i=0 label rel bad
  while IFS='|' read -r label rel bad; do
    i=$((i+1))
    root="$tmp/v04-rule-$i/plugin"
    if ! mkdir -p "$root" \
       || ! cp -R "$here/commands" "$here/skills" "$here/templates" "$here/scripts" "$root/" \
       || ! printf '\n%s\n' "$bad" >> "$root/$rel"; then
      ng "fixture setup for '$label' failed — case not exercised"
      continue
    fi
    out="$(bash "$me" "$root" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "FAIL: $label"; then
      ok "regression for '$label' is caught"
    else
      ng "FAIL-OPEN: '$label' missed its planted regression (exit=$rc)"
    fi
  done <<'CASES'
no atomic-transport claims|skills/collab/SKILL.md|The transport is an atomic submit+wait, so nothing can interleave.
no bare reverse agent-prompt knock|templates/PROTOCOL.template.md|- {{PEER}} knocks back with `herdr agent prompt <claude_pane_id> "..." --wait`.
no single-timeout claim for the knock|skills/collab/SKILL.md|The knock blocks for up to `COLLAB_WAIT_MS` in total.
no in-tree idlock references|templates/PROTOCOL.template.md|鎖目錄是 collab/.idlock，owner 檔在其中。
CASES

  # --- 4. The real tree must be clean.
  out="$(bash "$me" "$here" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "current tree is clean" \
                  || { ng "current tree has findings"; printf '%s\n' "$out" | sed 's/^/      /'; }

  echo "self-test: $((t-f))/$t passed"
  [ "$f" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
  self_test; exit $?
fi
run_lint "${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
exit $?

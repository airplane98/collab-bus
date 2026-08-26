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

# Every rule above is an ABSENCE rule, and absence rules cannot catch a doc that simply
# never got updated: `commands/send.md` kept telling agents to write schema-1 frontmatter
# and matched none of them, while bus.json declared the endpoint writes schema 2. A
# capability claim is only true if the blessed writer entrypoints actually emit it, so the
# writer docs are checked for PRESENCE instead.
require() { # <label> <regex> <file>
  local label="$1" re="$2" f="$3" rc
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "FAIL: $label — $f missing or unreadable"; fail=1; return
  fi
  grep -qE -- "$re" "$f"; rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "FAIL: $label — grep failed (exit $rc), NOT a clean pass"; fail=1; return
  fi
  if [ "$rc" -eq 1 ]; then
    echo "FAIL: $label — $f never mentions it"; fail=1; return
  fi
  echo "ok:   $label"
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
           scripts/next-id.sh scripts/publish.sh scripts/knock.sh scripts/bootstrap.sh \
           scripts/check-envelope.sh scripts/fm-quote.sh scripts/participant.sh scripts/route.sh \
           scripts/preflight.sh scripts/lib/inventory.sh \
           scripts/lib/envelope.sh scripts/lib/manifest.sh; do
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
  # v0.8 step 4 made routing a tool. A doc that still tells an agent to scan the
  # inbox and match `pair` is telling it to address a TAB, which is ambiguous the
  # moment two participants of one kind share one — the mesh blocker itself.
  check "no glob-and-match-pair drain rule" \
        'inbox/to/[^ ]*/\*\.md|只處理 .?pair. 等於自己|whose .?pair.? matches' "${DOCS[@]}"
  # bus.json says this endpoint WRITES schema 2. That is only honest if the documents an
  # agent actually follows tell it to emit the addressing fields.
  require "send command addresses a participant" 'to_agent' "$ROOT/commands/send.md"
  require "send reads transport as one snapshot"  'participant.sh" snapshot' "$ROOT/commands/send.md"
  # The project's own preflight cannot vet the project: an executable symlink at that path
  # has already run its target before any check inside it speaks. Presence is checked in
  # EVERY writer source, not only /send: omitting preflight entirely is the same bypass as
  # calling the project's copy, and was how SKILL + the fresh PROTOCOL escaped the first fix.
  local TRUSTED_PREFLIGHT_RE
  TRUSTED_PREFLIGHT_RE='BIN=\$\("\$COLLAB_BUS_TRUSTED_SCRIPTS/preflight\.sh"[[:space:]]+--dir[[:space:]]+"\$PROJECT_ROOT"\)'
  require "send establishes trusted preflight"     "$TRUSTED_PREFLIGHT_RE" "$ROOT/commands/send.md"
  require "skill establishes trusted preflight"    "$TRUSTED_PREFLIGHT_RE" "$ROOT/skills/collab/SKILL.md"
  require "template establishes trusted preflight" "$TRUSTED_PREFLIGHT_RE" "$ROOT/templates/PROTOCOL.template.md"
  # Not writers in the ordinary round, but still project-code execution surfaces:
  # status runs route.sh, and init runs the freshly vendored allocator/publisher.
  # Keeping them on the same anchor makes "no third entrypoint" an enforced property.
  require "status establishes trusted preflight"   "$TRUSTED_PREFLIGHT_RE" "$ROOT/commands/status.md"
  require "init establishes trusted preflight"     "$TRUSTED_PREFLIGHT_RE" "$ROOT/commands/init.md"
  # Once BIN is certified, examples use $BIN. A direct project-bin command is either
  # before the anchor or has thrown away the result it just certified. Match invocations,
  # not explanatory mentions, so the docs remain able to explain the rejected form.
  check "no writer executes project bin directly" \
        '\$\([[:space:]]*(\./)?collab/bin/[A-Za-z0-9_.-]+\.sh|^[[:space:]>]*(\./)?collab/bin/[A-Za-z0-9_.-]+\.sh' \
        "$ROOT/commands/send.md" "$ROOT/commands/status.md" "$ROOT/commands/init.md" \
        "$ROOT/skills/collab/SKILL.md" "$ROOT/templates/PROTOCOL.template.md"
  # Presence alone is insufficient: the old SKILL sentinel can be appended AFTER a good
  # anchor and overwrite the certified result. Likewise, pointing the supposed trusted
  # scripts variable back into collab/bin merely renames self-vetting.
  check "no writer overrides certified BIN" \
        'BIN=(\./)?collab/bin([;[:space:]]|$)|BIN="(\./)?collab/bin"' \
        "$ROOT/commands/send.md" "$ROOT/commands/status.md" "$ROOT/commands/init.md" \
        "$ROOT/skills/collab/SKILL.md" "$ROOT/templates/PROTOCOL.template.md"
  check "no project-derived trust anchor" \
        'COLLAB_BUS_TRUSTED_SCRIPTS=.*(\./)?collab/bin' \
        "$ROOT/commands/send.md" "$ROOT/commands/status.md" "$ROOT/commands/init.md" \
        "$ROOT/skills/collab/SKILL.md" "$ROOT/templates/PROTOCOL.template.md"
  # An INVOCATION, not a mention: the doc has to be able to explain why this path must
  # not be the one that runs first, and a rule that forbids naming it forbids the
  # explanation too.
  check "no self-vetting project preflight" \
        '\$\([[:space:]]*collab/bin/preflight\.sh|^[[:space:]]*collab/bin/preflight\.sh' "${DOCS[@]}"
  # Two `get` reads of a MUTABLE binding can join one holder's proven liveness to another
  # holder's pane — a target nothing ever proved was live. The accessor exists so that a
  # document cannot reintroduce the splice the code was just fixed for.
  # Broad on purpose: the first version matched only a bare placeholder and an unquoted
  # capital variable, so `get "$RECIPIENT_ID" pane_id` — the form a real doc would use —
  # walked straight through. Anything that reads a transport field off `get` is the
  # hazard, whatever the id looks like.
  check "no split live/pane binding reads" \
        'participant\.sh"? get [^|]*(live|pane_id|tab_id|agent_session)' "${DOCS[@]}"
  require "skill's envelope names to_agent"      'to_agent' "$ROOT/skills/collab/SKILL.md"
  require "template's envelope names to_agent"   'to_agent' "$ROOT/templates/PROTOCOL.template.md"
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
no split live/pane binding reads|commands/send.md|Check `participant.sh get <their-id> live`, then read `participant.sh get <their-id> pane_id`.
no split live/pane binding reads|commands/send.md|PEER_PANE=$("$BIN/participant.sh" get "$RECIPIENT_ID" pane_id)
no self-vetting project preflight|commands/send.md|BIN=$(collab/bin/preflight.sh) || exit 1
no writer overrides certified BIN|skills/collab/SKILL.md|BIN=collab/bin; [ -x "$BIN/next-id.sh" ] || BIN="${CLAUDE_PLUGIN_ROOT}/scripts"
no project-derived trust anchor|templates/PROTOCOL.template.md|COLLAB_BUS_TRUSTED_SCRIPTS=collab/bin
CASES

  # --- 3b. The PRESENCE rules must fail when a writer doc loses the field. An absence
  #         rule cannot be regression-tested by adding a line; this one is tested by
  #         taking one away, which is the failure that actually happened.
  root="$tmp/missing-writer"
  if ! mkdir -p "$root" \
     || ! cp -R "$here/commands" "$here/skills" "$here/templates" "$here/scripts" "$root/" \
     || ! grep -v 'to_agent' "$here/commands/send.md" > "$root/commands/send.md"; then
    ng "fixture setup for the writer-presence case failed"
  else
    out="$(bash "$me" "$root" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "FAIL: send command addresses a participant"; then
      ok "a writer doc that stops naming to_agent is caught"
    else
      ng "FAIL-OPEN: writer-presence rule missed its regression (exit=$rc)"
    fi
  fi

  # --- 3c. A writer that SKIPS preflight entirely must fail even if it retains a
  #         plausible direct allocator command. This is the exact false-green the
  #         send-only presence rule allowed in SKILL and the generated PROTOCOL.
  #         Each source gets its own destructive fixture, so none can borrow another
  #         source's good anchor and make the suite pass for the wrong reason.
  local anchor_label anchor_rel
  while IFS='|' read -r anchor_label anchor_rel; do
    root="$tmp/missing-anchor-${anchor_rel//\//-}/plugin"
    if ! mkdir -p "$root" \
       || ! cp -R "$here/commands" "$here/skills" "$here/templates" "$here/scripts" "$root/" \
       || ! sed '/BIN=.*COLLAB_BUS_TRUSTED_SCRIPTS.*preflight\.sh/d' \
             "$here/$anchor_rel" > "$root/$anchor_rel" \
       || ! printf '\nDRAFT=$(collab/bin/next-id.sh codex bypass w1:t1)\n' >> "$root/$anchor_rel" \
       || grep -q 'BIN=.*COLLAB_BUS_TRUSTED_SCRIPTS.*preflight\.sh' "$root/$anchor_rel" \
       || ! grep -q 'DRAFT=$(collab/bin/next-id.sh' "$root/$anchor_rel"; then
      ng "fixture setup for '$anchor_label' failed — case not exercised"
      continue
    fi
    out="$(bash "$me" "$root" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] \
       && printf '%s' "$out" | grep -qF "FAIL: $anchor_label" \
       && printf '%s' "$out" | grep -qF "FAIL: no writer executes project bin directly"; then
      ok "$anchor_rel cannot skip trusted preflight and execute project bin"
    else
      ng "FAIL-OPEN: $anchor_rel skipped trusted preflight (exit=$rc)"
    fi
  done <<'ANCHORS'
send establishes trusted preflight|commands/send.md
skill establishes trusted preflight|skills/collab/SKILL.md
template establishes trusted preflight|templates/PROTOCOL.template.md
status establishes trusted preflight|commands/status.md
init establishes trusted preflight|commands/init.md
ANCHORS

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

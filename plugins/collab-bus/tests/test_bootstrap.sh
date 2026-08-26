#!/usr/bin/env bash
# Tests for bootstrap.sh (v0.7 provider-neutral setup). What has to hold: a fresh
# project gets the full tree + executable vendored scripts + a fully rendered
# PROTOCOL; re-running MIGRATES (re-vendors) without ever overwriting PROTOCOL.md or
# touching message files; writes are never redirected through a symlink; and bad
# arguments / an unparseable manifest are refused before anything is created.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BOOT="$DIR/scripts/bootstrap.sh"
MANIFEST="$DIR/.claude-plugin/plugin.json"
fails=0
ok()  { echo "  ok   - $1"; }
bad() { echo "  FAIL - $1" >&2; fails=$((fails+1)); }

# One root for every fixture, removed even if a case aborts before its own cleanup.
ROOT="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$ROOT"' EXIT
# mktemp, not a counter: newdir runs in a command substitution, so a variable
# incremented here would not persist in the caller and every case would share one
# directory (and silently inherit the previous case's collab/).
newdir() { mktemp -d "$ROOT/case.XXXXXX"; }
# A scaffolded bus now validates frontmatter on publish, so a fixture draft has to be a
# real message rather than an arbitrary blob.
write_msg() { # <draft-path>
  local id; id="$(basename "$1")"; id="${id#.}"; id="${id%%-*}"
  printf -- '---\nid: %s\nfrom: claude\nto: codex\ntype: task\nsubject: %s\nstatus: open\n---\n\nbody\n' \
    "$id" "'fixture message'" > "$1"
}

# --- 1. fresh scaffold: tree, executables, fully rendered PROTOCOL -----------
t="$(newdir)"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
missing=""
for p in collab/PROTOCOL.md collab/bin/next-id.sh collab/bin/publish.sh collab/bin/knock.sh \
         collab/inbox/to/codex/.gitkeep collab/inbox/to/claude/.gitkeep \
         collab/inbox/archive/.gitkeep collab/reviews/.gitkeep collab/tasks/.gitkeep; do
  [ -e "$t/$p" ] || missing="$missing $p"
done
# grep -c prints 0 AND exits 1 when there is no match; `|| true` inside the
# substitution swallows the status without adding a second line to the value.
unrendered="$(grep -c '{{' "$t/collab/PROTOCOL.md" 2>/dev/null || true)"
if [ "$rc" = 0 ] && [ -z "$missing" ] && [ "$unrendered" = 0 ] \
   && [ -x "$t/collab/bin/next-id.sh" ] && [ -x "$t/collab/bin/knock.sh" ]; then
  ok "fresh scaffold: full tree, executable scripts, no unrendered {{placeholders}}"
else
  bad "fresh scaffold (rc=$rc missing:$missing unrendered=$unrendered)"
fi

# --- 2. the generated PROTOCOL carries the manifest's version ----------------
want="v$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)"
if grep -q "collab-bus \*\*$want\*\*" "$t/collab/PROTOCOL.md"; then
  ok "PROTOCOL is stamped with the plugin version ($want)"
else
  bad "version stamp missing or wrong (want $want)"
fi

# --- 3. the scaffolded bus actually works end to end -------------------------
d="$(cd "$t" && collab/bin/next-id.sh codex smoke w1:t1 2>/dev/null)"
write_msg "$d"
f="$(cd "$t" && collab/bin/publish.sh "$d" 2>/dev/null)"
if [ -n "$f" ] && [ -f "$f" ] && [[ "$(basename "$f")" == *-w1t1-smoke.md ]]; then
  ok "vendored scripts work in the scaffolded bus (allocate → publish)"
else
  bad "scaffolded bus could not publish a message (draft=$d final=$f)"
fi

# --- 4. re-run = migrate: re-vendor, never overwrite PROTOCOL or messages ----
# Hash every non-bin file, not just one message, so any collateral write shows up.
printf 'CUSTOM PROTOCOL CONTENT\n' > "$t/collab/PROTOCOL.md"
printf 'stale\n' > "$t/collab/bin/next-id.sh"
before="$(find "$t/collab" -type f -not -path "*/bin/*" | sort | xargs cksum | cksum)"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
after="$(find "$t/collab" -type f -not -path "*/bin/*" | sort | xargs cksum | cksum)"
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "migrated" \
   && [ "$before" = "$after" ] \
   && cmp -s "$DIR/scripts/next-id.sh" "$t/collab/bin/next-id.sh"; then
  ok "re-run migrates: scripts refreshed, every non-bin file byte-identical"
else
  bad "migration wrong (rc=$rc, non-bin files changed: $([ "$before" = "$after" ] && echo no || echo yes))"
fi

# --- 5. an invalid peer name is refused before anything is created -----------
t="$(newdir)"
out="$(cd "$t" && bash "$BOOT" "../escape" 2>&1)"; rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "must start with" && [ ! -e "$t/collab" ]; then
  ok "an invalid peer name is refused and nothing is scaffolded"
else
  bad "invalid peer name accepted (rc=$rc)"
fi

# --- 6. 'claude' is refused in ANY case ------------------------------------
# On a case-insensitive filesystem inbox/to/Claude IS inbox/to/claude, which would
# collapse the two addressees into one.
t="$(newdir)"; bad6=""
for variant in claude Claude CLAUDE cLaUdE; do
  out="$(cd "$t" && bash "$BOOT" "$variant" 2>&1)"; rc=$?
  { [ "$rc" = 2 ] && [ ! -e "$t/collab" ]; } || bad6="$bad6 $variant(rc=$rc)"
done
[ -z "$bad6" ] && ok "peer 'claude' is refused in any case (claude/Claude/CLAUDE/cLaUdE)" \
               || bad "case variants of 'claude' accepted:$bad6"

# --- 7. a project name with sed-hostile characters renders literally ---------
# bash parameter expansion is used precisely so '&' cannot corrupt it — and
# patsub_replacement (bash 5.2+) is disabled so '&' is not expanded to the match.
t="$(newdir)/a&b"; mkdir -p "$t"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
if head -1 "$t/collab/PROTOCOL.md" 2>/dev/null | grep -qF 'a&b'; then
  ok "a project name containing '&' renders literally (no sed/patsub corruption)"
else
  bad "project name with '&' was mangled: $(head -1 "$t/collab/PROTOCOL.md" 2>/dev/null)"
fi

# --- 8. a symlinked collab/ must not redirect writes outside the project -----
t="$(newdir)"; outside="$ROOT/outside.$$"; mkdir -p "$outside"
ln -s "$outside" "$t/collab"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "symlink" && [ -z "$(ls -A "$outside")" ]; then
  ok "a symlinked collab/ is refused and the external target stays empty"
else
  bad "symlinked collab/ was followed (rc=$rc, outside: $(ls -A "$outside" | tr '\n' ' '))"
fi

# --- 9. a symlinked collab/bin must not be followed --------------------------
t="$(newdir)"; outside="$ROOT/outsidebin.$$"; mkdir -p "$outside" "$t/collab"
ln -s "$outside" "$t/collab/bin"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "symlink" && [ -z "$(ls -A "$outside")" ]; then
  ok "a symlinked collab/bin is refused and the external target stays empty"
else
  bad "symlinked collab/bin was followed (rc=$rc)"
fi

# --- 10. a symlinked vendored file must not be written through --------------
t="$(newdir)"; victim="$ROOT/victim.$$.sh"; printf 'ORIGINAL\n' > "$victim"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
rm -f "$t/collab/bin/next-id.sh"; ln -s "$victim" "$t/collab/bin/next-id.sh"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "symlink" && [ "$(cat "$victim")" = "ORIGINAL" ]; then
  ok "a symlinked vendored file is refused and its target is not overwritten"
else
  bad "symlinked vendored file was written through (rc=$rc target='$(cat "$victim")')"
fi

# --- 11. argument contract: extra positional / missing --dir value / unknown -
t="$(newdir)"; bad11=""
out="$(cd "$t" && bash "$BOOT" codex gemini 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && [ ! -e "$t/collab" ]; } || bad11="$bad11 extra-positional(rc=$rc)"
out="$(cd "$t" && bash "$BOOT" --dir 2>&1)"; rc=$?
[ "$rc" = 2 ] || bad11="$bad11 missing-dir-value(rc=$rc,want 2)"
out="$(cd "$t" && bash "$BOOT" --bogus 2>&1)"; rc=$?
[ "$rc" = 2 ] || bad11="$bad11 unknown-flag(rc=$rc)"
[ -z "$bad11" ] && ok "argument contract: extra positional, missing --dir value, unknown flag all rc=2" \
                || bad "argument contract wrong:$bad11"

# --- 12. --dir targets another directory (and cwd is untouched) -------------
t="$(newdir)"; target="$(newdir)"
out="$(cd "$t" && bash "$BOOT" codex --dir "$target" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$target/collab/PROTOCOL.md" ] && [ ! -e "$t/collab" ]; then
  ok "--dir scaffolds the named project, not the cwd"
else
  bad "--dir wrong (rc=$rc)"
fi

# --- 13. an unparseable manifest fails loud, before any mutation ------------
# Provenance is the point of the version stamp, so a "vunknown" bus must never exist.
fake="$(newdir)"
mkdir -p "$fake/scripts" "$fake/templates" "$fake/.claude-plugin"
cp "$DIR"/scripts/*.sh "$fake/scripts/"
mkdir -p "$fake/scripts/lib"; cp "$DIR"/scripts/lib/*.sh "$fake/scripts/lib/"
cp "$DIR/templates/PROTOCOL.template.md" "$fake/templates/"
printf '{ "name": "collab-bus" }\n' > "$fake/.claude-plugin/plugin.json"   # no version
t="$(newdir)"
out="$(cd "$t" && bash "$fake/scripts/bootstrap.sh" codex 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -qi "version" && [ ! -e "$t/collab" ]; then
  ok "a manifest with no version fails loud and scaffolds nothing"
else
  bad "unparseable manifest did not fail closed (rc=$rc)"
fi
# A version that only PREFIX-matches must be refused too: unanchored, "0.7.0garbage"
# would be stamped into the PROTOCOL as if it were a real release.
printf '{ "version": "0.7.0garbage" }\n' > "$fake/.claude-plugin/plugin.json"
t="$(newdir)"
out="$(cd "$t" && bash "$fake/scripts/bootstrap.sh" codex 2>&1)"; rc=$?
if [ "$rc" != 0 ] && [ ! -e "$t/collab" ]; then
  ok "a version with trailing garbage is refused (regex anchored at both ends)"
else
  bad "trailing-garbage version accepted (rc=$rc)"
fi
# And a legitimate SemVer prerelease must still be accepted.
printf '{ "version": "1.2.3-beta.1" }\n' > "$fake/.claude-plugin/plugin.json"
t="$(newdir)"
(cd "$t" && bash "$fake/scripts/bootstrap.sh" codex >/dev/null 2>&1)
if grep -q "collab-bus \*\*v1.2.3-beta.1\*\*" "$t/collab/PROTOCOL.md" 2>/dev/null; then
  ok "a SemVer prerelease version is accepted and stamped"
else
  bad "SemVer prerelease rejected or mis-stamped"
fi

rm -f "$fake/.claude-plugin/plugin.json"
t="$(newdir)"
out="$(cd "$t" && bash "$fake/scripts/bootstrap.sh" codex 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -qi "manifest" && [ ! -e "$t/collab" ]; then
  ok "a missing manifest fails with a diagnosis and scaffolds nothing"
else
  bad "missing manifest not diagnosed (rc=$rc: $out)"
fi

# --- 14. project name comes from the git toplevel when there is one ---------
t="$(newdir)"
if command -v git >/dev/null 2>&1; then
  mkdir -p "$t/repo/nested/deep" && git -C "$t/repo" init -q .
  (cd "$t/repo/nested/deep" && bash "$BOOT" codex >/dev/null 2>&1)
  if head -1 "$t/repo/nested/deep/collab/PROTOCOL.md" 2>/dev/null | grep -q "^# repo ⇄"; then
    ok "project name falls back to the git toplevel basename, not the cwd"
  else
    bad "git-toplevel naming wrong: $(head -1 "$t/repo/nested/deep/collab/PROTOCOL.md" 2>/dev/null)"
  fi
else
  echo "  skip - git-toplevel case needs git"
fi

# --- 15. a pre-planted staging path must not be written through -------------
# The first staging implementation used a predictable name (.<f>.tmp.$$), so a symlink
# planted there was followed by `cp` and then installed as the final script by the
# rename. `exec` keeps the child's PID, so the planted name matches exactly what that
# old scheme would have used; mktemp's random directory is what defeats it now.
t="$(newdir)"; victim="$ROOT/stagevictim.$$.txt"; printf 'ORIGINAL\n' > "$victim"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
out="$(bash -c 'ln -s "$2" "$1/collab/bin/.next-id.sh.tmp.$$"; exec bash "$3" codex --dir "$1"' \
     _ "$t" "$victim" "$BOOT" 2>&1)"; rc=$?
final="$t/collab/bin/next-id.sh"
# rc/"migrated" must be asserted: the first bootstrap already left a canonical
# next-id.sh, so if the attacked run failed BEFORE mutating anything, every other
# assertion below would still hold and the case would pass without exercising the fix.
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "migrated" \
   && [ "$(cat "$victim")" = "ORIGINAL" ] && [ ! -L "$final" ] && [ -f "$final" ] \
   && cmp -s "$DIR/scripts/next-id.sh" "$final"; then
  ok "a pre-planted staging symlink is not written through (migration still completed)"
else
  bad "staging symlink case (rc=$rc victim='$(cat "$victim")' final symlink: $([ -L "$final" ] && echo yes || echo no))"
fi

# --- 16. a hard-linked destination is replaced, not written through ---------
# Proof the rename swaps the directory entry: another name for the old inode keeps its
# content instead of being rewritten by the copy.
t="$(newdir)"; twin="$ROOT/twin.$$.sh"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
printf 'OLD VENDORED CONTENT\n' > "$t/collab/bin/next-id.sh"
ln "$t/collab/bin/next-id.sh" "$twin"          # same inode, two names
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$twin")" = "OLD VENDORED CONTENT" ] \
   && cmp -s "$DIR/scripts/next-id.sh" "$t/collab/bin/next-id.sh"; then
  ok "a hard-linked destination is replaced by rename, the other name keeps its content"
else
  bad "hard-linked destination was written through (rc=$rc twin='$(cat "$twin")')"
fi

# --- 17. an unsafe LATER destination must not leave earlier ones replaced ---
# Destinations are preflighted as a set before any rename: validating inside the
# replace loop would already have swapped next-id.sh by the time publish.sh turns out
# to be a directory, leaving a mixed-version collab/bin behind a failed migration.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
printf 'MARKED\n' > "$t/collab/bin/next-id.sh"
printf 'MARKED KNOCK\n' > "$t/collab/bin/knock.sh"
rm -f "$t/collab/bin/publish.sh"; mkdir "$t/collab/bin/publish.sh"   # unsafe #2 of 3
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "not a regular file" \
   && [ "$(cat "$t/collab/bin/next-id.sh")" = "MARKED" ] \
   && [ "$(cat "$t/collab/bin/knock.sh")" = "MARKED KNOCK" ] \
   && [ -d "$t/collab/bin/publish.sh" ]; then
  ok "an unsafe later destination aborts before ANY script is replaced (no mixed bin)"
else
  bad "partial migration left behind (rc=$rc next-id='$(head -1 "$t/collab/bin/next-id.sh")')"
fi

# --- 18. a scaffolded bus carries the envelope gate AND enforces it ---------
# publish.sh requires lib/envelope.sh; vendoring one without the other produced a bus
# that silently accepted anything. Assert the files land, then prove the gate runs.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
missing=""
for p in bin/lib/envelope.sh bin/check-envelope.sh bin/fm-quote.sh; do
  [ -x "$t/collab/$p" ] || missing="$missing $p"
done
d="$(cd "$t" && collab/bin/next-id.sh codex gated w1:t1)"
id="$(basename "$d")"; id="${id#.}"; id="${id%%-*}"
printf -- '---\nid: %s\nfrom: claude\nto: codex\ntype: task\nsubject: broken: value\nstatus: open\n---\n\nbody\n' "$id" > "$d"
(cd "$t" && collab/bin/publish.sh "$d" >/dev/null 2>&1); rej=$?
printf -- '---\nid: %s\nfrom: claude\nto: codex\ntype: task\nsubject: %s\nstatus: open\n---\n\nbody\n' "$id" "'fine now'" > "$d"
good="$(cd "$t" && collab/bin/publish.sh "$d" 2>/dev/null)"; acc=$?
if [ -z "$missing" ] && [ "$rej" != 0 ] && [ "$acc" = 0 ] && [ -f "$good" ]; then
  ok "a scaffolded bus vendors the gate and uses it (bad refused, good published)"
else
  bad "vendored gate wrong (missing:$missing reject_rc=$rej accept_rc=$acc)"
fi

# --- 19. migrate installs the gate into a bus that predates it --------------
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
rm -rf "$t/collab/bin/lib" "$t/collab/bin/check-envelope.sh" "$t/collab/bin/fm-quote.sh"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -x "$t/collab/bin/lib/envelope.sh" ] && [ -x "$t/collab/bin/check-envelope.sh" ]; then
  ok "migrate adds the envelope gate to a bus that was vendored without it"
else
  bad "migrate did not install the gate (rc=$rc)"
fi

# --- 20. a nested vendor parent that is not a directory aborts before ANY swap
# Preflight only rejected a symlinked bin/lib. A regular FILE there passed, and mkdir
# then failed in the replace phase — after the top-level scripts had been swapped.
for kind in file symlink; do
  t="$(newdir)"
  (cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
  marked=""
  for f in next-id.sh publish.sh knock.sh check-envelope.sh fm-quote.sh; do
    printf 'MARKED %s\n' "$f" > "$t/collab/bin/$f"; marked="$marked $f"
  done
  rm -rf "$t/collab/bin/lib"
  if [ "$kind" = file ]; then printf 'not a dir\n' > "$t/collab/bin/lib"
  else ln -s "$ROOT" "$t/collab/bin/lib"; fi
  out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
  intact=1
  for f in $marked; do
    [ "$(cat "$t/collab/bin/$f")" = "MARKED $f" ] || intact=0
  done
  if [ "$rc" != 0 ] && [ "$intact" = 1 ]; then
    ok "a $kind at collab/bin/lib aborts before any script is replaced"
  else
    bad "nested parent ($kind) left a mixed install (rc=$rc intact=$intact)"
  fi
done

[ "$fails" -eq 0 ] && { echo "bootstrap: all passed"; exit 0; }
echo "bootstrap: $fails failed" >&2; exit 1

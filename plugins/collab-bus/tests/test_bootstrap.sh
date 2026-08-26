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

# --- 21. bus.json: minted once, preserved across re-runs, alias kept ---------
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
B="$t/collab/bus.json"
pid1="$(sed -n 's/.*"project_id"[^"]*"\([^"]*\)".*/\1/p' "$B")"
# an alias the human chose must survive a re-run; project_id must never be re-minted
python3 - "$B" <<'PYE' 2>/dev/null || sed -i '' 's/"project_alias": "[^"]*"/"project_alias": "renamed-by-hand"/' "$B"
import re,sys
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(re.sub(r'"project_alias": "[^"]*"', '"project_alias": "renamed-by-hand"', s))
PYE
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
pid2="$(sed -n 's/.*"project_id"[^"]*"\([^"]*\)".*/\1/p' "$B")"
alias2="$(sed -n 's/.*"project_alias"[^"]*"\([^"]*\)".*/\1/p' "$B")"
if [[ "$pid1" =~ ^[0-7][0-9A-HJKMNP-TV-Z]{25}$ ]] && [ "$pid1" = "$pid2" ] \
   && [ "$alias2" = "renamed-by-hand" ] && grep -q '"min_reader"' "$B"; then
  ok "bus.json: opaque project_id minted once and preserved; alias respected"
else
  bad "bus.json wrong (pid1=$pid1 pid2=$pid2 alias=$alias2)"
fi

# --- 21b. a deliberately raised min_reader survives a re-vendor -------------
# Raising min_reader is the migration step that licenses dropping legacy fields; if
# bootstrap reset it on every run, that decision would silently revert.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
sed -i '' 's/"min_reader": 1/"min_reader": 2/' "$t/collab/bus.json"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
grep -q '"min_reader": 2' "$t/collab/bus.json" \
  && ok "a hand-raised min_reader is preserved across a re-vendor" \
  || bad "min_reader was reset to the bootstrap default"

# --- 22. an unreadable bus.json fails loud instead of being re-minted -------
# "It exists" is not success: a manifest we cannot parse would otherwise get a SECOND
# identity minted for the same project.
for damage in 'garbage' '{ "project_id": "not-a-ulid" }'; do
  t="$(newdir)"
  (cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
  printf '%s\n' "$damage" > "$t/collab/bus.json"
  out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
  if [ "$rc" != 0 ] && printf '%s' "$out" | grep -qE "manifest|refusing"; then
    ok "a bus.json with no readable project_id fails loud (${damage:0:18})"
  else
    bad "damaged bus.json was silently rewritten (rc=$rc)"
  fi
done

# --- 23. a symlinked bus.json is refused ------------------------------------
t="$(newdir)"; victim="$ROOT/busvictim.$$"; printf 'ORIGINAL\n' > "$victim"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
rm -f "$t/collab/bus.json"; ln -s "$victim" "$t/collab/bus.json"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ "$(cat "$victim")" = "ORIGINAL" ]; } \
  && ok "a symlinked bus.json is refused and its target is untouched" \
  || bad "symlinked bus.json followed (rc=$rc)"

# --- 24. a manifest is PARSED, not grepped ---------------------------------
# A per-key search finds a valid-looking id inside a corrupt file and launders the
# corruption into clean JSON on the next write.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
pid="$(sed -n 's/.*"project_id"[^"]*"\([^"]*\)".*/\1/p' "$t/collab/bus.json")"
printf 'THIS IS NOT JSON "project_id": "%s", "project_alias": "kept", "min_reader": 2 TRAILING\n' "$pid" > "$t/collab/bus.json"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && grep -q "THIS IS NOT JSON" "$t/collab/bus.json"; } \
  && ok "a file that merely CONTAINS a valid id is rejected, not rewritten" \
  || bad "corrupt manifest was laundered (rc=$rc)"

# --- 25. a project alias needing JSON escaping round-trips ------------------
t="$(newdir)/say "'"'"hi"'"'" & \\stuff"; mkdir -p "$t"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1); rc=$?
if [ "$rc" = 0 ] && bash -c '. '"$DIR"'/scripts/lib/manifest.sh; manifest_json_check "$1"' _ "$t/collab/bus.json"; then
  ok "an alias containing quotes and backslashes produces valid JSON"
else
  bad "alias escaping wrong (rc=$rc): $(sed -n 2,3p "$t/collab/bus.json" 2>/dev/null)"
fi

# --- 26. min_reader must name a schema this endpoint actually reads ---------
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
sed -i.bak 's/"min_reader": 1/"min_reader": 9/' "$t/collab/bus.json"; rm -f "$t/collab/bus.json.bak"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "min_reader"; } \
  && ok "a min_reader outside schemas.read is refused as an unsatisfiable policy" \
  || bad "unsatisfiable min_reader accepted (rc=$rc)"

# --- 27. older tooling must not silently downgrade a newer manifest --------
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
sed -i.bak -e 's/"read": \[1, 2\]/"read": [1, 2, 3]/' -e 's/"write": [0-9][0-9]*/"write": 3/' \
           -e 's/"publisher_version": "[^"]*"/"publisher_version": "9.0.0"/' "$t/collab/bus.json"
rm -f "$t/collab/bus.json.bak"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -qi "newer\|downgrade" \
  && grep -q '"write": 3' "$t/collab/bus.json"; } \
  && ok "a manifest from newer tooling is left alone, not downgraded" \
  || bad "newer manifest was downgraded (rc=$rc)"

# --- 28. a bad manifest aborts BEFORE any vendored script is replaced ------
# Validation used to run after vendor_scripts, reopening the mixed-install hole that
# step 1 closed for the scripts themselves.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
for f in next-id.sh publish.sh knock.sh check-envelope.sh fm-quote.sh; do
  printf 'MARKED %s\n' "$f" > "$t/collab/bin/$f"
done
printf 'garbage\n' > "$t/collab/bus.json"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
intact=1
for f in next-id.sh publish.sh knock.sh check-envelope.sh fm-quote.sh; do
  [ "$(cat "$t/collab/bin/$f")" = "MARKED $f" ] || intact=0
done
{ [ "$rc" != 0 ] && [ "$intact" = 1 ]; } \
  && ok "a bad manifest aborts before any script is replaced (no mixed install)" \
  || bad "manifest failure left a mixed install (rc=$rc intact=$intact)"

# --- 29. two concurrent first bootstraps agree on ONE project_id -----------
# A bare "start both in the background" proves nothing: the scheduler may run them in
# sequence and the case goes green without the windows ever overlapping. An `od` wrapper
# that sleeps forces BOTH to be inside the mint window at once, and the oracle now
# requires both to succeed AND to report the same non-empty id as the file.
t="$(newdir)"
mkdir -p "$t/collab/inbox"          # a v0.7-era bus: no bus.json yet
slow="$ROOT/slowbin.$$"; mkdir -p "$slow"
realod="$(command -v od)"
cat > "$slow/od" <<SLOWOD
#!/usr/bin/env bash
sleep 1
exec "$realod" "\$@"
SLOWOD
chmod +x "$slow/od"
o1="$t/o1"; o2="$t/o2"
( cd "$t" && PATH="$slow:$PATH" bash "$BOOT" codex > "$o1" 2>&1 ) & p1=$!
( cd "$t" && PATH="$slow:$PATH" bash "$BOOT" codex > "$o2" 2>&1 ) & p2=$!
rc1=0; wait "$p1" || rc1=$?
rc2=0; wait "$p2" || rc2=$?
final="$(sed -n 's/.*"project_id"[^"]*"\([^"]*\)".*/\1/p' "$t/collab/bus.json" 2>/dev/null)"
r1="$(grep -o 'project_id [0-9A-Z]\{26\}' "$o1" | head -1 | awk '{print $2}')"
r2="$(grep -o 'project_id [0-9A-Z]\{26\}' "$o2" | head -1 | awk '{print $2}')"
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] \
   && [ -n "$final" ] && [ -n "$r1" ] && [ -n "$r2" ] \
   && [ "$r1" = "$final" ] && [ "$r2" = "$final" ]; then
  ok "a forced concurrent first bootstrap converges: both report $final"
else
  bad "mint-once race (rc1=$rc1 rc2=$rc2 r1='$r1' r2='$r2' final='$final')"
fi

# --- 30. a hostile project path cannot inject shell or corrupt the id ------
# The staging path used to be interpolated into a trap string, so a directory whose name
# closes the quote and appends commands ran arbitrary shell AND pushed text into the id
# this function returns. Built via a variable so the test's own quoting cannot drift.
hostile="x"; hostile="${hostile}'; touch PWNED; echo '"
t="$(newdir)/$hostile"; mkdir -p "$t"
here="$PWD"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
pid="$(printf '%s' "$out" | grep -o 'project_id [0-9A-Z]*' | head -1 | awk '{print $2}')"
if [ "$rc" = 0 ] && [ ! -e "$t/PWNED" ] && [ ! -e "$here/PWNED" ] && [ "${#pid}" = 26 ]; then
  ok "a hostile project path executes nothing and yields a clean 26-char id"
else
  bad "path injection (rc=$rc pwned=$([ -e "$t/PWNED" ] && echo yes || echo no) id='$pid' len=${#pid})"
fi
rm -f "$here/PWNED" 2>/dev/null || true

# --- 31. the manifest is validated as a WHOLE file, not key by key ---------
# Each of these keeps a valid-looking object somewhere in the file; a per-key search
# accepted them all and rewrote the damage away.
mfbad() { # <label> <content>
  local d; d="$(newdir)"
  (cd "$d" && bash "$BOOT" codex >/dev/null 2>&1)
  local pid; pid="$(sed -n 's/.*"project_id"[^"]*"\([^"]*\)".*/\1/p' "$d/collab/bus.json")"
  printf '%s\n' "${2//@PID@/$pid}" > "$d/collab/bus.json"
  local before; before="$(cksum < "$d/collab/bus.json")"
  local o; o="$(cd "$d" && bash "$BOOT" codex 2>&1)"; local r=$?
  local after; after="$(cksum < "$d/collab/bus.json")"
  if [ "$r" != 0 ] && [ "$before" = "$after" ]; then return 0; fi
  echo "        accepted/rewrote: $1 (rc=$r)" >&2; return 1
}
r31=0
mfbad "root array" '[ { "manifest_schema": 1, "project_id": "@PID@", "project_alias": "x", "schemas": { "read": [1, 2], "write": 1, "min_reader": 1 }, "publisher_version": "0.7.0" } ]' || r31=1
mfbad "schema as string" '{
  "manifest_schema": "1",
  "project_id": "@PID@",
  "project_alias": "x",
  "schemas": { "read": [1, 2], "write": 1, "min_reader": 1 },
  "publisher_version": "0.7.0"
}' || r31=1
mfbad "unknown key with a digit" '{
  "manifest_schema": 1,
  "project_id": "@PID@",
  "project_alias": "x",
  "future2": true,
  "schemas": { "read": [1, 2], "write": 1, "min_reader": 1 },
  "publisher_version": "0.7.0"
}' || r31=1
mfbad "unsupported discriminator" '{
  "manifest_schema": 0,
  "project_id": "@PID@",
  "project_alias": "x",
  "schemas": { "read": [1, 2], "write": 1, "min_reader": 1 },
  "publisher_version": "0.7.0"
}' || r31=1
mfbad "version with trailing junk" '{
  "manifest_schema": 1,
  "project_id": "@PID@",
  "project_alias": "x",
  "schemas": { "read": [1, 2], "write": 1, "min_reader": 1 },
  "publisher_version": "0.7.0junk"
}' || r31=1
mfbad "alias escape we do not emit" '{
  "manifest_schema": 1,
  "project_id": "@PID@",
  "project_alias": "\u0061",
  "schemas": { "read": [1, 2], "write": 1, "min_reader": 1 },
  "publisher_version": "0.7.0"
}' || r31=1
[ "$r31" = 0 ] && ok "root array / typed / unknown-key / discriminator / version / alias-escape damage all refused" \
               || bad "whole-file grammar incomplete"

# --- 32. and still refused with no JSON parser on PATH ---------------------
# The optional parser only proves "this is some JSON"; the dependency-free grammar is the
# actual guarantee, so it has to reject prose wrapped around a canonical object alone.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
pid="$(sed -n 's/.*"project_id"[^"]*"\([^"]*\)".*/\1/p' "$t/collab/bus.json")"
nostub="$ROOT/nojson.$$"; mkdir -p "$nostub"
for prog in ruby python3 python; do printf '#!/bin/sh\nexit 127\n' > "$nostub/$prog"; chmod +x "$nostub/$prog"; done
{ printf 'NOT JSON\n'; cat "$t/collab/bus.json"; printf 'TRAILING\n'; } > "$t/collab/bus.json.new"
mv "$t/collab/bus.json.new" "$t/collab/bus.json"
before="$(cksum < "$t/collab/bus.json")"
out="$(cd "$t" && PATH="$nostub:$PATH" bash "$BOOT" codex 2>&1)"; rc=$?
after="$(cksum < "$t/collab/bus.json")"
{ [ "$rc" != 0 ] && [ "$before" = "$after" ]; } \
  && ok "prose around a canonical object is refused even with no JSON parser available" \
  || bad "no-parser grammar accepted wrapped prose (rc=$rc)"

# --- 33. downgrade gate covers write and SemVer build metadata -------------
r33=0
mfbad "write beyond this tooling" '{
  "manifest_schema": 1,
  "project_id": "@PID@",
  "project_alias": "x",
  "schemas": { "read": [1, 2], "write": 3, "min_reader": 1 },
  "publisher_version": "0.7.0"
}' || r33=1
mfbad "newer version with build metadata" '{
  "manifest_schema": 1,
  "project_id": "@PID@",
  "project_alias": "x",
  "schemas": { "read": [1, 2], "write": 1, "min_reader": 1 },
  "publisher_version": "0.7.1+meta"
}' || r33=1
[ "$r33" = 0 ] && ok "a newer schemas.write or a +build version is refused, not reset" \
               || bad "downgrade gate still has holes"

# --- 34. the no-parser grammar rejects three more non-JSON shapes ----------
# All three keep a canonical-looking object; only a whole-file grammar catches them, and
# the NUL one is invisible to every string-level check because bash cannot hold the byte.
nostub2="$ROOT/nojson2.$$"; mkdir -p "$nostub2"
for prog in ruby python3 python; do printf '#!/bin/sh\nexit 127\n' > "$nostub2/$prog"; chmod +x "$nostub2/$prog"; done
r34=0
mfraw() { # <label> <sed-or-perl mutation applied to a fresh manifest>
  local d; d="$(newdir)"; (cd "$d" && bash "$BOOT" codex >/dev/null 2>&1)
  eval "$2"                      # operates on $d/collab/bus.json
  local before; before="$(cksum < "$d/collab/bus.json")"
  local o r; o="$(cd "$d" && PATH="$nostub2:$PATH" bash "$BOOT" codex 2>&1)"; r=$?
  local after; after="$(cksum < "$d/collab/bus.json")"
  { [ "$r" != 0 ] && [ "$before" = "$after" ]; } && return 0
  echo "        accepted/rewrote: $1 (rc=$r)" >&2; return 1
}
mfraw "NUL after the opening brace" \
  'printf "{\000\n" > "$d/collab/tmp.h"; tail -n +2 "$d/collab/bus.json" >> "$d/collab/tmp.h"; mv "$d/collab/tmp.h" "$d/collab/bus.json"' || r34=1
mfraw "alias with a bare quote" \
  'sed -i.bak "s/\"project_alias\": \"/\"project_alias\": \"a\"b/" "$d/collab/bus.json"; rm -f "$d/collab/bus.json.bak"' || r34=1
mfraw "read list with a trailing comma" \
  'sed -i.bak "s/\"read\": \[1, 2\]/\"read\": [1, 2,]/" "$d/collab/bus.json"; rm -f "$d/collab/bus.json.bak"' || r34=1
[ "$r34" = 0 ] && ok "NUL / bare quote / trailing comma are all refused with no JSON parser" \
               || bad "no-parser grammar still launders corruption"

# --- 35. tooling capability comes from the binary, not the environment -----
# A fail-closed policy an inherited env var can switch off is not a policy.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
sed -i.bak -e 's/"read": \[1, 2\]/"read": [1, 2, 3]/' -e 's/"write": [0-9][0-9]*/"write": 3/' "$t/collab/bus.json"
rm -f "$t/collab/bus.json.bak"
before="$(cksum < "$t/collab/bus.json")"
out="$(cd "$t" && MF_TOOLING_READ=1,2,3 MF_TOOLING_WRITE=1,3 bash "$BOOT" codex 2>&1)"; rc=$?
after="$(cksum < "$t/collab/bus.json")"
{ [ "$rc" != 0 ] && [ "$before" = "$after" ]; } \
  && ok "MF_TOOLING_* in the environment cannot unlock a downgrade" \
  || bad "env-supplied capability downgraded the manifest (rc=$rc)"

# --- 36. SemVer precedence: stable outranks its own prerelease -------------
# Dropping the prerelease made 0.7.0 and 0.7.0-alpha compare EQUAL, so prerelease tooling
# would quietly rewrite a stable manifest as prerelease.
vcmp() { bash -c '. "$1"; rc=0; _mf_version_cmp "$2" "$3" || rc=$?; echo $rc' _ "$DIR/scripts/lib/manifest.sh" "$2" "$3"; }
r36=0
[ "$(vcmp x 0.7.0 0.7.0-alpha)" = 1 ] || { echo "        stable !> prerelease" >&2; r36=1; }
[ "$(vcmp x 0.7.0-alpha 0.7.0)" = 2 ] || { echo "        prerelease !< stable" >&2; r36=1; }
[ "$(vcmp x 0.7.0-rc.10 0.7.0-rc.2)" = 1 ] || { echo "        rc.10 !> rc.2" >&2; r36=1; }
[ "$(vcmp x 0.7.1+meta 0.7.0)" = 1 ] || { echo "        build metadata broke the core compare" >&2; r36=1; }
[ "$(vcmp x 0.10.0 0.9.0)" = 1 ] || { echo "        0.10.0 !> 0.9.0" >&2; r36=1; }
[ "$(vcmp x 1.2.3 1.2.3+build)" = 0 ] || { echo "        build metadata affected precedence" >&2; r36=1; }
[ "$r36" = 0 ] && ok "SemVer precedence: stable > prerelease, rc.10 > rc.2, build ignored" \
               || bad "version precedence wrong"

# --- 37. SemVer numeric components must not go through shell arithmetic ----
# `[ "$x" -gt "$y" ]` past the 64-bit range prints "integer expression expected" and
# returns false, which fell through to "equal" — so a hugely newer version compared as
# not-newer and the downgrade gate opened.
huge=999999999999999999999999999999
r37=0
out="$(bash -c '. "$1"; rc=0; _mf_version_cmp "$2" "$3" || rc=$?; echo "rc=$rc"' \
       _ "$DIR/scripts/lib/manifest.sh" "1.0.0-$huge" "1.0.0-2" 2>&1)"
{ printf '%s' "$out" | grep -q "^rc=1$" && ! printf '%s' "$out" | grep -q "integer expression"; } \
  || { echo "        huge prerelease: $out" >&2; r37=1; }
out="$(bash -c '. "$1"; rc=0; _mf_version_cmp "$2" "$3" || rc=$?; echo "rc=$rc"' \
       _ "$DIR/scripts/lib/manifest.sh" "$huge.0.0" "0.7.0" 2>&1)"
{ printf '%s' "$out" | grep -q "^rc=1$" && ! printf '%s' "$out" | grep -q "integer expression"; } \
  || { echo "        huge major: $out" >&2; r37=1; }
# leading zeros must normalise, not change the ordering
out="$(bash -c '. "$1"; rc=0; _mf_version_cmp "$2" "$3" || rc=$?; echo "rc=$rc"' \
       _ "$DIR/scripts/lib/manifest.sh" "1.0.0-007" "1.0.0-7" 2>&1)"
printf '%s' "$out" | grep -q "^rc=0$" || { echo "        leading zeros: $out" >&2; r37=1; }
[ "$r37" = 0 ] && ok "SemVer numeric compare is exact past the 64-bit range" \
               || bad "numeric overflow in version comparison"

# --- 38. a hugely newer publisher_version is refused, not downgraded -------
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
sed -i.bak "s/\"publisher_version\": \"[^\"]*\"/\"publisher_version\": \"$huge.0.0\"/" "$t/collab/bus.json"
rm -f "$t/collab/bus.json.bak"
before="$(cksum < "$t/collab/bus.json")"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
after="$(cksum < "$t/collab/bus.json")"
{ [ "$rc" != 0 ] && [ "$before" = "$after" ] && ! printf '%s' "$out" | grep -q "integer expression"; } \
  && ok "a huge major version is refused with no arithmetic diagnostic" \
  || bad "huge version downgraded (rc=$rc)"

# --- 39. migrate creates a missing registry; existing entries are untouched --
# The migrate branch used to return right after vendoring, so a project that predates the
# registry never got one; and the fresh path hid every declaration failure behind `|| true`.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
idbefore="$(cksum < "$t/collab/participants/claude-primary.json")"
rm -rf "$t/collab/participants" "$t/collab/bindings"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ -d "$t/collab/participants" ] && [ -d "$t/collab/bindings" ] \
  && [ -f "$t/collab/participants/codex-primary.json" ]; } \
  && ok "migrate recreates a missing participants/ and bindings/" \
  || bad "migrate left the registry missing (rc=$rc)"
idafter="$(cksum < "$t/collab/participants/claude-primary.json")"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
{ [ "$idafter" = "$(cksum < "$t/collab/participants/claude-primary.json")" ]; } \
  && ok "an existing identity is validated, never rewritten, on re-run" \
  || bad "re-run rewrote an existing identity"

# --- 40. a peer whose name is not a legal id is canonicalised, not dropped ---
# `Gemini` is a legal inbox name but not a legal participant id; the old catch-all
# reported the silent drop as success.
t="$(newdir)"
out="$(cd "$t" && bash "$BOOT" Gemini 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ -f "$t/collab/participants/gemini-primary.json" ]; } \
  && ok "an uppercase peer yields a canonical lowercase participant id" \
  || bad "peer id declaration lost (rc=$rc): $(ls "$t/collab/participants" 2>&1)"

# --- 41. an illegal peer id aborts BEFORE anything is scaffolded -----------
long="$(printf 'a%.0s' $(seq 1 64))"
t="$(newdir)"
out="$(cd "$t" && bash "$BOOT" "$long" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ ! -e "$t/collab" ]; } \
  && ok "a peer that cannot yield a legal participant id scaffolds nothing at all" \
  || bad "fresh left a partial tree behind (rc=$rc)"

# --- 42. …and on migrate, no vendored file is touched either ---------------
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
for f in next-id.sh publish.sh knock.sh check-envelope.sh fm-quote.sh participant.sh route.sh; do
  printf 'MARKED %s\n' "$f" > "$t/collab/bin/$f"
done
busbefore="$(cksum < "$t/collab/bus.json")"
out="$(cd "$t" && bash "$BOOT" "$long" 2>&1)"; rc=$?
intact=1
for f in next-id.sh publish.sh knock.sh check-envelope.sh fm-quote.sh participant.sh route.sh; do
  [ "$(cat "$t/collab/bin/$f")" = "MARKED $f" ] || intact=0
done
{ [ "$rc" != 0 ] && [ "$intact" = 1 ] && [ "$busbefore" = "$(cksum < "$t/collab/bus.json")" ]; } \
  && ok "an invalid registry plan aborts migrate before any vendored file or manifest changes" \
  || bad "migrate mutated before validating (rc=$rc intact=$intact)"

# --- 43. a hand-set alias on an existing identity is preserved -------------
# bootstrap owns the id and the kind expectation, not the alias.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
rm -f "$t/collab/participants/claude-primary.json"
(cd "$t" && COLLAB_ROOT="$t/collab" bash "$DIR/scripts/participant.sh" register claude-primary --kind claude --alias 'Claude Agent' >/dev/null 2>&1)
before="$(cksum < "$t/collab/participants/claude-primary.json")"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ "$before" = "$(cksum < "$t/collab/participants/claude-primary.json")" ]; } \
  && ok "an existing identity with a custom alias is accepted and left untouched" \
  || bad "bootstrap rejected or rewrote a legitimate custom alias (rc=$rc)"

# --- 44. a wrong kind or a symlinked registry fails before any mutation ----
r44=0
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
sed -i.bak 's/"kind": "claude"/"kind": "wrong-kind"/' "$t/collab/participants/claude-primary.json"
rm -f "$t/collab/participants/claude-primary.json.bak"
printf 'MARKED\n' > "$t/collab/bin/next-id.sh"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ "$(cat "$t/collab/bin/next-id.sh")" = "MARKED" ]; } || r44=1
t="$(newdir)"; outside="$ROOT/regout.$$"; mkdir -p "$outside"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
rm -rf "$t/collab/participants"; ln -s "$outside" "$t/collab/participants"
printf 'MARKED\n' > "$t/collab/bin/next-id.sh"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ "$(cat "$t/collab/bin/next-id.sh")" = "MARKED" ] && [ -z "$(ls -A "$outside")" ]; } || r44=1
[ "$r44" = 0 ] && ok "a wrong kind or a symlinked participants/ fails before any file is replaced" \
               || bad "registry preflight ran too late"

# --- 45. the routing tool is vendored, and the manifest says we write v2 ---
# A capability claim has to match what the vendored bin can actually do: declaring
# `write: 2` while the routing tool is missing from collab/bin would tell a peer this
# endpoint speaks schema 2 when nothing here routes on it.
t="$(newdir)"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ -x "$t/collab/bin/route.sh" ] \
  && grep -q '"write": 2' "$t/collab/bus.json"; } \
  && ok "route.sh is vendored and bus.json declares schema 2 as what we write" \
  || bad "routing capability and vendored bin disagree (rc=$rc)"

# --- 46. migrating a 0.7-era project adds the routing tool -----------------
# The whole point of migrate: an existing bus gets the new bin without its PROTOCOL or its
# messages being rewritten.
rm -f "$t/collab/bin/route.sh"
before="$(cksum < "$t/collab/PROTOCOL.md")"
out="$(cd "$t" && bash "$BOOT" codex 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ -x "$t/collab/bin/route.sh" ] \
  && [ "$before" = "$(cksum < "$t/collab/PROTOCOL.md")" ]; } \
  && ok "migrate re-vendors the routing tool and leaves PROTOCOL.md alone" \
  || bad "migrate did not restore route.sh (rc=$rc)"

# --- 47-50. preflight refuses a half-vendored bin, by REASON -------------
# The check used to be a for-loop in commands/send.md and was wrong three ways: it omitted
# lib/manifest.sh, which participant.sh and route.sh both source; it tested -e, so a
# non-executable script reported healthy and failed at its call site; and it chose the
# whole tree from one sentinel, so a bin holding participant.sh but no next-id.sh silently
# switched every call to the plugin's copies. A rule with fixtures behind it is a rule.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
out="$(cd "$t" && bash "$DIR/scripts/preflight.sh" 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ "$out" = "./collab/bin" ]; } \
  && ok "preflight passes a freshly bootstrapped bin and prints it" \
  || bad "preflight rejected a fresh bin (rc=$rc out=$out)"

rm -f "$t/collab/bin/lib/manifest.sh"
out="$(cd "$t" && bash "$DIR/scripts/preflight.sh" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'manifest.sh is missing'; } \
  && ok "a bin missing lib/manifest.sh fails here, not later at a source error" \
  || bad "missing manifest not caught (rc=$rc)"

# Half a bin, and the plugin tree perfectly complete: the sentinel version passed this.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
rm -f "$t/collab/bin/next-id.sh"
out="$(cd "$t" && bash "$DIR/scripts/preflight.sh" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'next-id.sh is missing' \
  && ! printf '%s' "$out" | grep -q "$DIR/scripts"; } \
  && ok "a half bin never falls back to the plugin tree" \
  || bad "half bin borrowed another version's entrypoints (rc=$rc out=$out)"

t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
chmod -x "$t/collab/bin/route.sh"
out="$(cd "$t" && bash "$DIR/scripts/preflight.sh" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'route.sh is not executable'; } \
  && ok "a non-executable vendored script is caught before its call site" \
  || bad "non-executable script reported healthy (rc=$rc)"

# --- 51. an executable symlinked preflight must never RUN --------------------
# The caller cannot ask the project's own preflight whether the project can be trusted:
# if that path is an executable symlink, the target has already run by the time any check
# inside it says "symlinks are refused". The oracle is not the exit code — it is that the
# TARGET'S MARKER never appears.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
marker="$t/pwned"
cat > "$t/evil.sh" <<EOF
#!/bin/sh
: > "$marker"
exit 7
EOF
chmod +x "$t/evil.sh"
rm -f "$t/collab/bin/preflight.sh"; ln -s "$t/evil.sh" "$t/collab/bin/preflight.sh"
out="$(cd "$t" && bash "$DIR/scripts/preflight.sh" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ ! -e "$marker" ] && printf '%s' "$out" | grep -q 'preflight.sh is a symlink'; } \
  && ok "the plugin's preflight refuses a symlinked vendored preflight without running it" \
  || bad "symlinked preflight executed or was accepted (rc=$rc marker=$([ -e "$marker" ] && echo yes || echo no))"

# --- 52. a symlinked parent hides every leaf check ---------------------------
# `-L` is false for every leaf while the whole tree hangs off a symlinked parent, so
# checking only the leaves proves nothing about where they live.
t="$(newdir)"; ext="$ROOT/extcollab.$$"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
mv "$t/collab" "$ext"; ln -s "$ext" "$t/collab"
out="$(cd "$t" && bash "$DIR/scripts/preflight.sh" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'collab is a symlink'; } \
  && ok "a symlinked collab/ is refused before anything under it is trusted" \
  || bad "symlinked collab/ accepted (rc=$rc)"

t="$(newdir)"; extlib="$ROOT/extlib.$$"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
mv "$t/collab/bin/lib" "$extlib"; ln -s "$extlib" "$t/collab/bin/lib"
out="$(cd "$t" && bash "$DIR/scripts/preflight.sh" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'lib is a symlink'; } \
  && ok "a symlinked collab/bin/lib is refused, not hidden by its leaves passing" \
  || bad "symlinked lib/ accepted — libraries would be sourced from outside (rc=$rc)"

# --- 53. executable is not readable: a shell script needs both --------------
# `chmod 0111` leaves -x true and the script unusable: the interpreter has to READ it, so
# a preflight that passed here is immediately contradicted by rc 126 at the call site.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
chmod a-r "$t/collab/bin/next-id.sh"
out="$(cd "$t" && bash "$DIR/scripts/preflight.sh" 2>&1)"; rc=$?
irc=0; (cd "$t" && collab/bin/next-id.sh codex x w1:t1 >/dev/null 2>&1) || irc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'next-id.sh is not readable' && [ "$irc" = 126 ]; } \
  && ok "an unreadable-but-executable script is refused, matching what the shell does" \
  || bad "unreadable script passed preflight (rc=$rc, running it gave $irc)"
chmod u+r "$t/collab/bin/next-id.sh"

# --- 54. one inventory, so the writer and the checker cannot disagree -------
# The old guard grepped preflight's whole source for each vendored name, so a mention in
# a COMMENT satisfied it. There is now a single machine-readable list; this asserts both
# readers agree with it, and that removing an entry from it really does redden.
INV="$DIR/scripts/lib/inventory.sh"
inv_all="$( . "$INV"; printf '%s %s' "$COLLAB_BINS" "$COLLAB_LIBS" )"
boot_all="$( . "$INV"; printf '%s' "${COLLAB_BINS} ${COLLAB_LIBS}" )"
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
missing=""
for f in $inv_all; do [ -f "$t/collab/bin/$f" ] || missing="$missing $f"; done
extra=""
for f in $(cd "$t/collab/bin" && find . -type f | sed 's|^\./||'); do
  case " $inv_all " in *" $f "*) : ;; *) extra="$extra $f" ;; esac
done
{ [ -z "$missing" ] && [ -z "$extra" ] && [ -n "$boot_all" ]; } \
  && ok "bootstrap vendors exactly the inventory — no more, no less" \
  || bad "bin does not match the inventory (missing:$missing extra:$extra)"

# And the guard must be able to fail: drop one required entry and the bin it produces
# must stop satisfying preflight. A guard nobody has seen go red is a guess.
tree="$ROOT/invtree.$$"; mkdir -p "$tree"
# The whole plugin tree: bootstrap reads the PROTOCOL template and the plugin manifest
# from its siblings, so a partial copy fails for a reason that has nothing to do with what
# this case is testing — and would pass the assertion below for the wrong reason.
cp -R "$DIR/." "$tree/"
sed -i.bak 's/^COLLAB_BINS="next-id.sh /COLLAB_BINS="/' "$tree/scripts/lib/inventory.sh"
rm -f "$tree/scripts/lib/inventory.sh.bak"
t="$(newdir)"
(cd "$t" && bash "$tree/scripts/bootstrap.sh" codex >/dev/null 2>&1)
out="$(cd "$t" && bash "$DIR/scripts/preflight.sh" 2>&1)"; rc=$?
{ [ ! -f "$t/collab/bin/next-id.sh" ] && [ "$rc" != 0 ] \
  && printf '%s' "$out" | grep -q 'next-id.sh is missing'; } \
  && ok "removing an entry from the inventory really does produce an incomplete bin" \
  || bad "the inventory guard cannot go red (rc=$rc)"

# --- 55. every writer recipe must vet next-id before it can execute ---------
# The old SKILL selected collab/bin after checking only `-x next-id.sh`; -x follows an
# executable symlink, so the target ran before any trust decision. Keep the original
# marker experiment as a permanent integration oracle: the trusted, out-of-project
# preflight must reject the leaf and the target's marker must never appear.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
marker="$t/next-id-ran"
cat > "$t/evil-next-id.sh" <<EOF
#!/bin/sh
: > "$marker"
exit 7
EOF
chmod +x "$t/evil-next-id.sh"
rm -f "$t/collab/bin/next-id.sh"; ln -s "$t/evil-next-id.sh" "$t/collab/bin/next-id.sh"
out="$(bash "$DIR/scripts/preflight.sh" --dir "$t" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ ! -e "$marker" ] && printf '%s' "$out" | grep -q 'next-id.sh is a symlink'; } \
  && ok "trusted preflight rejects a symlinked allocator before its marker can run" \
  || bad "writer trust anchor executed or accepted symlinked next-id (rc=$rc marker=$([ -e "$marker" ] && echo yes || echo no))"

# --- 56-57. runtime refuses a genuine preflight that is its own target ------
# Docs and doclint cannot see a peer's provider-local environment. Even while the
# vendored preflight is still genuine, it must not certify the collab root containing
# itself — and it must decide that BEFORE sourcing another project-owned file.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
marker="$t/inventory-ran"
printf '\n: > "%s"\n' "$marker" >> "$t/collab/bin/lib/inventory.sh"
out="$(cd "$t" && collab/bin/preflight.sh 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && [ ! -e "$marker" ] \
  && printf '%s' "$out" | grep -q 'trust-anchor violation' \
  && printf '%s' "$out" | grep -q 'out-of-project trusted clone'; } \
  && ok "the vendored preflight refuses to certify its own collab root before sourcing inventory" \
  || bad "project preflight self-vetted or sourced project inventory (rc=$rc marker=$([ -e "$marker" ] && echo yes || echo no))"

# The realistic configuration error: a peer names collab/bin itself as its supposedly
# provider-local anchor. This is a distinct caller shape even though it reaches the same
# genuine file, and runtime — not doclint — must reject it.
t="$(newdir)"
(cd "$t" && bash "$BOOT" codex >/dev/null 2>&1)
out="$(cd "$t" && COLLAB_BUS_TRUSTED_SCRIPTS=collab/bin \
  && "$COLLAB_BUS_TRUSTED_SCRIPTS/preflight.sh" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'trust-anchor violation' \
  && printf '%s' "$out" | grep -q 'out-of-project trusted clone'; } \
  && ok "a provider-local anchor pointed at collab/bin is rejected at runtime" \
  || bad "COLLAB_BUS_TRUSTED_SCRIPTS=collab/bin silently self-vetted (rc=$rc out=$out)"

# Resolve the executable leaf too, not just its parent directory: an apparently external
# trusted path can itself be a symlink back to the project copy.
trusted_link="$ROOT/trusted-preflight.$$"
ln -s "$t/collab/bin/preflight.sh" "$trusted_link"
out="$("$trusted_link" --dir "$t" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'trust-anchor violation'; } \
  && ok "an out-of-project preflight symlink resolving into collab/bin is rejected" \
  || bad "a trusted-looking symlink hid the project preflight location (rc=$rc out=$out)"

# --- 58. one project's vendored preflight cannot certify another project ---
# Comparing only against the inspected root leaves the same persistent config mistake
# open across projects: a provider-local anchor aimed at project A's collab/bin would
# silently certify project B. A trusted clone lives under scripts/; any resolved
# preflight living directly under collab/bin is vendored and must refuse every target.
project_a="$(newdir)"; project_b="$(newdir)"
(cd "$project_a" && bash "$BOOT" codex >/dev/null 2>&1)
(cd "$project_b" && bash "$BOOT" codex >/dev/null 2>&1)
out="$("$project_a/collab/bin/preflight.sh" --dir "$project_b" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'trust-anchor violation' \
  && ! printf '%s\n' "$out" | grep -Fxq "$project_b/collab/bin"; } \
  && ok "a vendored preflight from one project cannot certify another project" \
  || bad "project A's vendored preflight certified project B (rc=$rc out=$out)"

[ "$fails" -eq 0 ] && { echo "bootstrap: all passed"; exit 0; }
echo "bootstrap: $fails failed" >&2; exit 1

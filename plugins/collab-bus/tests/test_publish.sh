#!/usr/bin/env bash
# Tests for publish.sh (v0.6 atomic publish). next-id.sh hands back a draft
# (.<ULID>-<tab>-<slug>.md.part); publish.sh publishes it to the final <ULID>-…md
# via an atomic no-replace hard-link (the `link` utility) + unlink of the draft.
# What has to hold: the final .md appears only via that atomic link (a receiver
# scanning *.md never sees a reserved-but-empty message), a 0-byte draft is
# refused, an existing final — regular file, dir, or symlink — is never clobbered,
# and non-drafts are rejected.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/scripts"
NEXTID="$DIR/next-id.sh"
PUBLISH="$DIR/publish.sh"
fails=0
ok()  { echo "  ok   - $1"; }
bad() { echo "  FAIL - $1" >&2; fails=$((fails+1)); }
newroot() { local t; t="$(mktemp -d)"; mkdir -p "$t/collab/inbox"; printf '%s' "$t"; }

# The publish gate validates frontmatter (v0.8), so a fixture draft must be a real
# message, not an arbitrary blob. Body text is passed through so assertions can still
# check that content survived the publish.
write_msg() { # <draft-path> [body]
  local id; id="$(basename "$1")"; id="${id#.}"; id="${id%%-*}"
  printf -- '---\nid: %s\nfrom: claude\nto: codex\ntype: task\nsubject: %s\nstatus: open\n---\n\n%s\n' \
    "$id" "'fixture message'" "${2:-body}" > "$1"
}
# messages visible to a receiver = final .md files only (ls hides dot drafts).
mds() { ls "$1"/*.md 2>/dev/null | wc -l | tr -d ' '; }

# --- 1. happy path: draft -> published final, content intact, draft gone ------
t="$(newroot)"; box="$t/collab/inbox/to/codex"
draft="$(cd "$t" && bash "$NEXTID" codex happy w1:t1)"
before="$(mds "$box")"                 # while only the draft exists
write_msg "$draft" "hello body"
final="$(cd "$t" && bash "$PUBLISH" "$draft")"; rc=$?
if [ "$rc" = 0 ] && [ "$before" = 0 ] && [ -f "$final" ] && [ ! -e "$draft" ] \
   && grep -q "^hello body$" "$final" && [[ "$(basename "$final")" == *.md ]]; then
  ok "draft publishes to a final .md (invisible as a message until published)"
else
  bad "happy-path publish wrong (rc=$rc before=$before final=$final)"
fi
rm -rf "$t"

# --- 2. THE CORE GUARD: an empty draft is refused ----------------------------
# next-id.sh reserves an empty draft; publishing it without writing a body would
# ship a 0-byte message. This is the failure the whole feature exists to prevent.
t="$(newroot)"; box="$t/collab/inbox/to/codex"
draft="$(cd "$t" && bash "$NEXTID" codex empty w1:t1)"   # left empty on purpose
out="$(cd "$t" && bash "$PUBLISH" "$draft" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "empty" && [ -e "$draft" ] && [ "$(mds "$box")" = 0 ]; then
  ok "an empty draft is refused (no 0-byte message is ever published)"
else
  bad "empty draft was not refused (rc=$rc, mds=$(mds "$box"))"
fi
rm -rf "$t"

# --- 3. an existing final is never clobbered ---------------------------------
t="$(newroot)"; box="$t/collab/inbox/to/codex"
draft="$(cd "$t" && bash "$NEXTID" codex clob w1:t1)"
write_msg "$draft"
final_name="$(basename "$draft")"; final_name="${final_name#.}"; final_name="${final_name%.part}"
: > "$box/$final_name"                                    # a final already sits there
printf 'IMPORTANT\n' > "$box/$final_name"
out="$(cd "$t" && bash "$PUBLISH" "$draft" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "already exists" \
   && [ "$(cat "$box/$final_name")" = "IMPORTANT" ] && [ -e "$draft" ]; then
  ok "an existing final is not overwritten (draft kept for inspection)"
else
  bad "existing final was clobbered or draft lost (rc=$rc)"
fi
rm -rf "$t"

# --- 4. a non-draft path is rejected -----------------------------------------
t="$(newroot)"
: > "$t/notadraft.md"
out="$(bash "$PUBLISH" "$t/notadraft.md" 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q "not a collab draft" \
  && ok "a path that isn't a .md.part draft is rejected (exit 2)" \
  || bad "non-draft path not rejected correctly (rc=$rc)"
rm -rf "$t"

# --- 5. a missing draft is reported, not published ---------------------------
t="$(newroot)"
out="$(bash "$PUBLISH" "$t/collab/inbox/to/codex/.01MISSING-w1t1-x.md.part" 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -q "not found" \
  && ok "a missing draft is reported" \
  || bad "missing draft not handled (rc=$rc)"
rm -rf "$t"

# --- 6. a symlink draft is refused (never publish a symlink as the message) ---
# -f and -s follow symlinks, so without an explicit -L guard a symlink draft
# would publish as a symlink final whose target could later change the content.
t="$(newroot)"; box="$t/collab/inbox/to/codex"; mkdir -p "$box"
printf 'real body\n' > "$t/target.md"
draft="$box/.01M0XGF1R1V99XDE7VHGE5BYEF-w1t1-sym.md.part"
ln -s "$t/target.md" "$draft"
out="$(bash "$PUBLISH" "$draft" 2>&1)"; rc=$?
final="$box/01M0XGF1R1V99XDE7VHGE5BYEF-w1t1-sym.md"
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "symlink" && [ -L "$draft" ] && [ ! -e "$final" ]; then
  ok "a symlink draft is refused (symlink kept, no final published)"
else
  bad "symlink draft not refused (rc=$rc)"
fi
rm -rf "$t"

# --- 7. a shape-valid but non-canonical draft name is refused ----------------
# `.<anything>.md.part` used to pass; the name must be a real allocator output
# (26-char ULID, w<n>t<n> tab, allowlisted slug), else any file could be renamed.
t="$(newroot)"; box="$t/collab/inbox/to/codex"; mkdir -p "$box"
draft="$box/.badulid-w1t1-x.md.part"     # not a 26-char Crockford ULID
write_msg "$draft"
out="$(bash "$PUBLISH" "$draft" 2>&1)"; rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "canonical" && [ -e "$draft" ] && [ ! -e "$box/badulid-w1t1-x.md" ]; then
  ok "a non-canonical draft name is refused (real ULID/tab/slug required)"
else
  bad "non-canonical draft accepted (rc=$rc)"
fi
rm -rf "$t"

# --- 8. a slug containing a dot still publishes (canonical regex allows it) ---
t="$(newroot)"; box="$t/collab/inbox/to/codex"
draft="$(cd "$t" && bash "$NEXTID" codex foo.bar w1:t1)"
write_msg "$draft" dotted
final="$(cd "$t" && bash "$PUBLISH" "$draft")"; rc=$?
if [ "$rc" = 0 ] && [ -f "$final" ] && [[ "$(basename "$final")" == *-foo.bar.md ]]; then
  ok "a dotted slug publishes correctly ($(basename "$final"))"
else
  bad "dotted slug mishandled (rc=$rc final=$final)"
fi
rm -rf "$t"

# --- 9. a directory with a canonical draft name is refused (not a regular file)
t="$(newroot)"; box="$t/collab/inbox/to/codex"; mkdir -p "$box"
draft="$box/.01M0XGF1R1V99XDE7VHGE5BYEF-w1t1-dir.md.part"
mkdir "$draft"
out="$(bash "$PUBLISH" "$draft" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "not a regular file" && [ -d "$draft" ]; then
  ok "a directory draft is refused (regular file required)"
else
  bad "directory draft not refused (rc=$rc)"
fi
rm -rf "$t"

# --- 10. exactly one argument is required ------------------------------------
t="$(newroot)"
draft="$(cd "$t" && bash "$NEXTID" codex args w1:t1)"; write_msg "$draft"
out="$(bash "$PUBLISH" "$draft" extra 2>&1)"; rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q "usage" && [ -e "$draft" ] \
  && ok "extra arguments are rejected (draft untouched)" \
  || bad "extra arguments not rejected (rc=$rc)"
rm -rf "$t"

# --- 11. a dangling symlink at the final path is not clobbered ---------------
# This is exactly where a `[ -e "$FINAL" ]` precheck fails ([ -e ] is false for a
# dangling symlink) but the atomic `link` does not: link() sees the name exists
# and fails with EEXIST. Proof the publish is no-replace, not check-then-move.
t="$(newroot)"; box="$t/collab/inbox/to/codex"
draft="$(cd "$t" && bash "$NEXTID" codex dang w1:t1)"; write_msg "$draft"
fn="$(basename "$draft")"; fn="${fn#.}"; fn="${fn%.part}"
ln -s "$t/nonexistent-target" "$box/$fn"     # dangling symlink where the final would land
out="$(cd "$t" && bash "$PUBLISH" "$draft" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && [ -L "$box/$fn" ] && [ -e "$draft" ]; then
  ok "a dangling symlink at the final path is not clobbered (link fails atomically)"
else
  bad "dangling symlink final was clobbered (rc=$rc)"
fi
rm -rf "$t"

# --- 12. a DIRECTORY at the final path is not linked into --------------------
# `ln SOURCE DIR` would create a link INSIDE the directory and report success,
# swallowing the message and losing the draft. The `link` utility fails instead.
t="$(newroot)"; box="$t/collab/inbox/to/codex"
draft="$(cd "$t" && bash "$NEXTID" codex intodir w1:t1)"; write_msg "$draft"
fn="$(basename "$draft")"; fn="${fn#.}"; fn="${fn%.part}"
mkdir "$box/$fn"                              # a directory sits where the final would go
out="$(cd "$t" && bash "$PUBLISH" "$draft" 2>&1)"; rc=$?
inside="$(ls -A "$box/$fn")"
if [ "$rc" != 0 ] && [ -d "$box/$fn" ] && [ -e "$draft" ] && [ -z "$inside" ]; then
  ok "a directory at the final path is refused, not linked into (draft kept)"
else
  bad "directory final was linked into or draft lost (rc=$rc inside='$inside')"
fi
rm -rf "$t"

# --- 13. a symlink-to-directory at the final path is not followed ------------
t="$(newroot)"; box="$t/collab/inbox/to/codex"
draft="$(cd "$t" && bash "$NEXTID" codex symdir w1:t1)"; write_msg "$draft"
fn="$(basename "$draft")"; fn="${fn#.}"; fn="${fn%.part}"
mkdir "$t/realdir"; ln -s "$t/realdir" "$box/$fn"
out="$(cd "$t" && bash "$PUBLISH" "$draft" 2>&1)"; rc=$?
inside="$(ls -A "$t/realdir")"
if [ "$rc" != 0 ] && [ -L "$box/$fn" ] && [ -e "$draft" ] && [ -z "$inside" ]; then
  ok "a symlink-to-directory final is refused, its target untouched (draft kept)"
else
  bad "symlink-to-dir final mishandled (rc=$rc inside='$inside')"
fi
rm -rf "$t"

# --- 14. a cleanup (unlink-draft) failure still succeeds, but warns ----------
# The final is already fully visible once link() succeeds, so a failed draft
# unlink must not report failure (that would make the caller re-send) — but it
# must not be silent either. Stub rm to fail; expect rc=0, a stderr warning, and
# both names present (same inode).
t="$(newroot)"; box="$t/collab/inbox/to/codex"; stub="$(mktemp -d)"
draft="$(cd "$t" && bash "$NEXTID" codex cleanup w1:t1)"; write_msg "$draft"
printf '#!/usr/bin/env bash\nexit 1\n' > "$stub/rm"; chmod +x "$stub/rm"
out="$(cd "$t" && PATH="$stub:$PATH" bash "$PUBLISH" "$draft" 2>&1 >/dev/null)"; rc=$?
final="$(cd "$t" && PATH="$PATH" ls "$box"/*.md 2>/dev/null | head -1)"
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qi "warning" && [ -e "$draft" ] && [ -n "$final" ]; then
  ok "a failed draft-cleanup still publishes but warns on stderr"
else
  bad "cleanup-failure path wrong (rc=$rc final=$final)"
fi
rm -rf "$t" "$stub"

# --- 18. the frontmatter id must match the filename ULID --------------------
# Two records of one fact. A message whose id disagrees with its own name breaks every
# reply_to lookup that follows it.
t="$(newroot)"
draft="$(cd "$t" && bash "$NEXTID" codex idmatch w1:t1)"
printf -- '---\nid: %s\nfrom: claude\nto: codex\ntype: task\nsubject: %s\nstatus: open\n---\n\nbody\n' \
  "01M0WG3WJF6AX39B2RGCPVN2CM" "'mismatched'" > "$draft"
out="$(cd "$t" && bash "$PUBLISH" "$draft" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "does not match the filename" && [ -e "$draft" ]; } \
  && ok "a frontmatter id that disagrees with the filename is refused" \
  || bad "id/filename mismatch accepted (rc=$rc)"
rm -rf "$t"

# --- 19. a bad envelope is refused; the draft survives for repair -----------
t="$(newroot)"
draft="$(cd "$t" && bash "$NEXTID" codex badenv w1:t1)"
id="$(basename "$draft")"; id="${id#.}"; id="${id%%-*}"
printf -- '---\nid: %s\nfrom: claude\nto: codex\ntype: task\nsubject: broken: here\nstatus: open\n---\n\nbody\n' "$id" > "$draft"
out="$(cd "$t" && bash "$PUBLISH" "$draft" 2>&1)"; rc=$?
{ [ "$rc" = 2 ] && [ -e "$draft" ] && [ -z "$(ls "$t/collab/inbox/to/codex"/*.md 2>/dev/null)" ]; } \
  && ok "an unparseable envelope is refused and the draft is kept" \
  || bad "bad envelope published (rc=$rc)"
rm -rf "$t"

# --- 20. publish FAILS LOUD when the envelope library is missing ------------
# Vendoring publish.sh without lib/ used to disable the gate silently — every draft,
# including ones with no frontmatter at all, published cleanly.
t="$(newroot)"
nolib="$(mktemp -d)"; cp "$NEXTID" "$PUBLISH" "$nolib/"
draft="$(cd "$t" && bash "$nolib/next-id.sh" codex nolib w1:t1)"
printf 'no frontmatter at all\n' > "$draft"
out="$(cd "$t" && bash "$nolib/publish.sh" "$draft" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "envelope gate is missing" && [ -e "$draft" ]; } \
  && ok "publish refuses to run without its envelope library (no silent skip)" \
  || bad "publish ran without the gate (rc=$rc)"
rm -rf "$t" "$nolib"

# --- 21. transport facts in the frontmatter must match the path ------------
t="$(newroot)"
draft="$(cd "$t" && bash "$NEXTID" codex xbind w1:t1)"
id="$(basename "$draft")"; id="${id#.}"; id="${id%%-*}"
# published into inbox/to/codex/ but addressed to claude
printf -- '---\nid: %s\nfrom: claude\nto: claude\ntype: task\nsubject: %s\nstatus: open\n---\n\nbody\n' "$id" "'x'" > "$draft"
out="$(cd "$t" && bash "$PUBLISH" "$draft" 2>&1)"; rc1=$?
# pair disagreeing with the tab encoded in the filename
printf -- '---\nid: %s\nfrom: claude\nto: codex\npair: w9:t9\ntype: task\nsubject: %s\nstatus: open\n---\n\nbody\n' "$id" "'x'" > "$draft"
out2="$(cd "$t" && bash "$PUBLISH" "$draft" 2>&1)"; rc2=$?
{ [ "$rc1" != 0 ] && printf '%s' "$out" | grep -q "disagrees with the inbox" \
  && [ "$rc2" != 0 ] && printf '%s' "$out2" | grep -q "disagrees with the filename tab"; } \
  && ok "a 'to' or 'pair' that contradicts the path is refused" \
  || bad "cross-field binding not enforced (rc1=$rc1 rc2=$rc2)"
rm -rf "$t"

# --- 22. a draft carrying a NUL is refused at the boundary -----------------
# The full oracle: matching filename/id, correct to/pair — only the NUL is wrong, and it
# used to publish cleanly because bash dropped the byte before any check saw it.
t="$(newroot)"
draft="$(cd "$t" && bash "$NEXTID" codex nulmsg w1:t1)"
id="$(basename "$draft")"; id="${id#.}"; id="${id%%-*}"
{ printf -- '---\nid: %s\nfrom: claude\nto: codex\npair: w1:t1\ntype: task\n' "$id"
  printf "subject: 'valid'\000\n"
  printf -- 'status: open\n---\n\nbody\n'; } > "$draft"
out="$(cd "$t" && bash "$PUBLISH" "$draft" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "NUL" \
  && [ -e "$draft" ] && [ -z "$(ls "$t/collab/inbox/to/codex"/*.md 2>/dev/null)" ]; } \
  && ok "a draft containing a NUL byte is refused and never published" \
  || bad "NUL draft published (rc=$rc)"
rm -rf "$t"

# --- 23-25. schema-2 addressees must exist, and be of the kind claimed -----
# `to_agent` used to be a bare string, so a perfectly legal publish could name a
# participant nobody registered, or one whose kind did not match the inbox it landed in.
# Every reader then said "not mine", quietly, with rc 0 — undeliverable and unreported.
# The gate is the last place such a message can still be refused.
BOOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/scripts/bootstrap.sh"
t="$(mktemp -d)"
( cd "$t" && bash "$BOOT" codex --dir . ) >/dev/null 2>&1
write_msg2() { # <draft> <to_agent>
  local id; id="$(basename "$1")"; id="${id#.}"; id="${id%%-*}"
  cat > "$1" <<EOF
---
schema: 2
id: $id
thread: $id
from: claude
to: codex
from_agent: claude-primary
to_agent: $2
intent: action
type: task
subject: 'addressee fixture'
status: open
pair: w3:t6
---
body
EOF
}
# next-id.sh returns an ABSOLUTE draft path here; prefixing $t to it would silently write
# the fixture somewhere that does not exist and leave the real draft empty.
d="$( cd "$t" && collab/bin/next-id.sh codex wrongkind w3:t6 )"
write_msg2 "$d" claude-primary             # kind claude, published into the codex inbox
out="$( cd "$t" && collab/bin/publish.sh "$d" 2>&1 )"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "is kind 'claude'" && [ -f "$d" ]; } \
  && ok "a recipient whose kind contradicts the inbox is refused, draft kept" \
  || bad "wrong-kind recipient published (rc=$rc)"

write_msg2 "$d" ghost-primary
out="$( cd "$t" && collab/bin/publish.sh "$d" 2>&1 )"; rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "not a registered participant"; } \
  && ok "an unregistered recipient is refused before it can become undeliverable" \
  || bad "unregistered recipient published (rc=$rc)"

write_msg2 "$d" codex-primary
out="$( cd "$t" && collab/bin/publish.sh "$d" 2>&1 )"; rc=$?
{ [ "$rc" = 0 ] && [ -f "$out" ]; } \
  && ok "a registered recipient of the right kind publishes normally" \
  || bad "valid schema-2 message refused (rc=$rc out=$out)"
rm -rf "$t"

[ "$fails" -eq 0 ] && { echo "publish: all passed"; exit 0; }
echo "publish: $fails failed" >&2; exit 1

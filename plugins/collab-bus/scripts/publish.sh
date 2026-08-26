#!/usr/bin/env bash
# Atomically publish a collab-bus draft into the inbox (v0.6; envelope gate v0.8).
#
# next-id.sh allocates a DRAFT — `.<ULID>-<tab>-<slug>.md.part` — instead of the
# final message. The sender writes content into that draft, then calls this to
# publish it as `<ULID>-<tab>-<slug>.md`. The final .md appears complete-or-not-
# at-all, so a receiver scanning the inbox never reads a reserved-but-empty
# message (the failure this project hit repeatedly).
#
# Publish is a no-replace hard-link + unlink, NOT check-then-mv and NOT `ln`:
# the POSIX `link` utility is an exact two-path link(2) wrapper that fails with
# EEXIST if the final already exists — a regular file, a directory, or a symlink
# — closing the TOCTOU window and never mis-linking INSIDE a directory the way
# `ln SOURCE DIR` does (which would swallow the message and lose the draft). It
# falls back to perl's link() where the utility is absent.
#
# Guards, in order, before anything is linked:
#   - exactly one argument, and a canonical draft basename (real ULID/tab/slug);
#   - the draft is not a symlink and is a regular file (never publish a symlink
#     or a dir/FIFO as if it were a self-contained message);
#   - the draft is non-empty (the last guard against shipping a 0-byte message);
#   - a valid envelope (v0.8): the frontmatter must parse and match its schema, and the
#     `id` field must equal the filename's ULID. The envelope library is REQUIRED — if
#     it is missing the publish FAILS rather than skipping the check.
# On any failure the draft is left in place for inspection.
#
# Usage:  publish.sh <draft-path from next-id.sh>
# Prints: the final message path on success.
#
# Exit:   0 published; 2 bad usage / not a canonical draft / symlink / bad envelope;
#         1 missing, non-regular, empty, missing gate library, or final already exists.
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: publish.sh <draft-path>" >&2; exit 2; }
DRAFT="$1"
base="$(basename "$DRAFT")"

# Shape gate: a dotfile ending in .md.part. Needed before we can strip it apart.
case "$base" in
  .?*.md.part) : ;;
  *) echo "error: '$DRAFT' is not a collab draft (expected .<ULID>-<tab>-<slug>.md.part)" >&2; exit 2 ;;
esac

# Reject a symlink BEFORE the -f/-s content checks, which both follow symlinks:
# otherwise a symlink draft would publish as a symlink final, and its target
# could change what the receiver later reads.
if [ -L "$DRAFT" ]; then
  echo "error: draft is a symlink — refusing to publish: $DRAFT" >&2; exit 2
fi
[ -e "$DRAFT" ] || { echo "error: draft not found: $DRAFT" >&2; exit 1; }
[ -f "$DRAFT" ] || { echo "error: draft is not a regular file: $DRAFT" >&2; exit 1; }
[ -s "$DRAFT" ] || { echo "error: draft is empty — refusing to publish a 0-byte message: $DRAFT" >&2; exit 1; }

dir="$(dirname "$DRAFT")"
final="${base#.}"        # strip leading dot
final="${final%.part}"   # strip trailing .part  -> <ULID>-<tab>-<slug>.md

# Validate the derived name is a real allocator output, not just any
# `.something.md.part`: a 26-char Crockford ULID (first char 0-7, the 48-bit
# timestamp bound), a w<n>t<n> tab, and a slug from next-id.sh's own allowlist.
ULID='[0-7][0-9A-HJKMNP-TV-Z]{25}'
if ! [[ "$final" =~ ^${ULID}-w[0-9]+t[0-9]+-[A-Za-z0-9][A-Za-z0-9._-]*\.md$ ]]; then
  echo "error: '$base' is not a canonical collab draft name (bad ULID/tab/slug)" >&2; exit 2
fi

# Envelope gate (v0.8): frontmatter is validated HERE, at the boundary, so a message a
# reader cannot parse never enters the bus. Discovering it later — which is how 13
# messages with an unquoted ": " got published — leaves the damage permanent, because a
# published message is immutable by design. Version-aware: legacy (schema 1) drafts keep
# passing, schema 2 is held to the strict field set and quoting rules.
# The library is REQUIRED. Skipping the gate when it is missing would turn a deployment
# mistake into silent acceptance of anything — which is exactly what happened when
# bootstrap vendored publish.sh without lib/: unvalidated drafts published cleanly.
_pub_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/envelope.sh"
if [ ! -r "$_pub_lib" ]; then
  echo "error: cannot read $_pub_lib — the envelope gate is missing, refusing to publish" >&2
  echo "       re-run bootstrap.sh to re-vendor collab/bin/ (draft kept: $DRAFT)" >&2
  exit 1
fi
. "$_pub_lib"
if ! envelope_check "$DRAFT"; then
  echo "error: draft frontmatter is not valid — refusing to publish (draft kept: $DRAFT)" >&2
  echo "       quote agent-authored values with fm-quote.sh; see PROTOCOL." >&2
  exit 2
fi
envelope_yaml_check "$DRAFT" || {
  echo "error: a YAML parser rejected the frontmatter — refusing to publish (draft kept)" >&2
  exit 2
}
# The filename ULID and the `id` field must agree. They are two records of the same fact,
# and a message whose id disagrees with its own name breaks every reply_to lookup.
_pub_fid="$(fm_get "$DRAFT" id 2>/dev/null || true)"
if [ "$_pub_fid" != "${final%%-*}" ]; then
  echo "error: frontmatter id '$_pub_fid' does not match the filename ULID '${final%%-*}' (draft kept)" >&2
  exit 2
fi

# Redundant transport facts must agree, the same way id and filename must. A draft sitting
# in inbox/to/codex/ whose frontmatter says `to: claude`, or whose `pair` disagrees with
# the tab encoded in its own name, would route one way and read another.
_pub_box="$(basename "$dir")"
case "$dir" in
  */inbox/to/"$_pub_box")
    _pub_to="$(fm_get "$DRAFT" to 2>/dev/null || true)"
    if [ -n "$_pub_to" ] && [ "$_pub_to" != "$_pub_box" ]; then
      echo "error: frontmatter 'to: $_pub_to' disagrees with the inbox it is being published into ($_pub_box) (draft kept)" >&2
      exit 2
    fi ;;
esac
# The addressees must be participants that EXIST, of the kind the message claims. Without
# this a perfectly legal publish could name a recipient nobody has registered, or a
# recipient whose kind does not match the inbox it lands in — and every reader would then
# say "not mine", quietly, with rc 0. A message nobody claims and nobody reports is worse
# than a refused one, and the gate is the last place it can still be refused.
_pub_reg="$(cd "$dir/../../.." 2>/dev/null && pwd -P)" || _pub_reg=""
_pub_part="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/participant.sh"
_pub_check_agent() { # <field> <participant-id> <declared-kind>
  local k
  [ -n "$2" ] || return 0
  if [ -z "$_pub_reg" ] || [ ! -d "$_pub_reg/participants" ]; then
    echo "error: $1: $2 cannot be verified — no participant registry found (draft kept)" >&2
    return 1
  fi
  k="$(COLLAB_ROOT="$_pub_reg" "$_pub_part" get "$2" kind 2>/dev/null)" || {
    echo "error: $1: '$2' is not a registered participant (draft kept)" >&2
    echo "       register it first: participant.sh register $2 --kind $3" >&2
    return 1; }
  [ "$k" = "$3" ] || {
    echo "error: $1: '$2' is kind '$k', but the message says '$3' (draft kept)" >&2
    return 1; }
  return 0
}
_pub_fa="$(fm_get "$DRAFT" from_agent 2>/dev/null || true)"
_pub_ta="$(fm_get "$DRAFT" to_agent 2>/dev/null || true)"
_pub_from="$(fm_get "$DRAFT" from 2>/dev/null || true)"
_pub_check_agent from_agent "$_pub_fa" "$_pub_from" || exit 2
_pub_check_agent to_agent   "$_pub_ta" "$_pub_box"  || exit 2

_pub_pair="$(fm_get "$DRAFT" pair 2>/dev/null || true)"
if [ -n "$_pub_pair" ]; then
  _pub_ftab="${final#*-}"; _pub_ftab="${_pub_ftab%%-*}"      # <ULID>-w1t1-slug.md -> w1t1
  if [ "${_pub_pair/:/}" != "$_pub_ftab" ]; then
    echo "error: frontmatter 'pair: $_pub_pair' disagrees with the filename tab '$_pub_ftab' (draft kept)" >&2
    exit 2
  fi
fi

FINAL="$dir/$final"

# Exact two-path link (see header): the utility if present, else perl's link().
do_link() { # <src> <dst>  -> 0 if dst created, non-zero if dst exists or error
  if command -v link >/dev/null 2>&1; then link "$1" "$2"
  else perl -e 'link($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"; fi
}

if do_link "$DRAFT" "$FINAL" 2>/dev/null; then
  # Defense: FINAL must now be the draft's twin — a regular file at the same
  # inode. If a `link` variant ever mis-placed it, this fails closed rather than
  # reporting a publish that did not happen.
  if [ -f "$FINAL" ] && [ "$FINAL" -ef "$DRAFT" ]; then
    rm -f "$DRAFT" 2>/dev/null \
      || echo "warning: published $FINAL but could not remove the hidden draft alias $DRAFT — it points at the same file; do not write to it again" >&2
    echo "$FINAL"
  else
    echo "error: post-publish check failed — $FINAL is not the expected file; draft kept" >&2
    exit 1
  fi
else
  # -e is false for a dangling symlink, so also test -L to report it correctly.
  if [ -e "$FINAL" ] || [ -L "$FINAL" ]; then
    echo "error: $FINAL already exists — refusing to overwrite (draft kept)" >&2
  else
    echo "error: could not publish $DRAFT -> $FINAL (link failed; draft kept)" >&2
  fi
  exit 1
fi

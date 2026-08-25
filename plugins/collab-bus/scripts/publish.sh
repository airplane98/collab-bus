#!/usr/bin/env bash
# Atomically publish a collab-bus draft into the inbox (v0.6).
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
#   - the draft is non-empty (the last guard against shipping a 0-byte message).
# On any failure the draft is left in place for inspection.
#
# Usage:  publish.sh <draft-path from next-id.sh>
# Prints: the final message path on success.
# Exit:   0 published; 2 bad usage / not a canonical draft / symlink; 1 missing,
#         non-regular, empty, or final already exists.
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

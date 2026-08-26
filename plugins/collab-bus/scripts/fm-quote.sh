#!/usr/bin/env bash
# Emit a canonical single-quoted YAML scalar for agent-authored text.
#
# Use it for every human string in frontmatter (subject, refs, note, alias) rather than
# splicing the value in by hand — `subject: $SUBJECT` is how 13 messages in this bus ended
# up with frontmatter no YAML parser will read.
#
# Usage:  fm-quote.sh 'some text'          → 'some text'
#         fm-quote.sh "it's here: really"  → 'it''s here: really'
#         printf %s "$s" | fm-quote.sh -   (read the value from stdin instead)
# Exit:   0 ok; 2 bad usage, or a newline / control byte / NUL in the value.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/envelope.sh"

[ "$#" -eq 1 ] || { echo "usage: fm-quote.sh <string>|-" >&2; exit 2; }
# Read stdin WITHOUT command substitution: $(...) both strips trailing newlines and
# silently drops NUL bytes, so a value carrying either would look clean by the time it
# reached fm_quote. `read -d ''` makes NUL the delimiter, which separates the two cases:
#   returns 0  -> a NUL was actually found, so reject it;
#   returns !0 -> EOF with no NUL, and `value` still holds everything read, trailing
#                 newline included, which fm_quote then refuses on its own.
if [ "$1" = "-" ]; then
  if IFS= read -r -d '' value; then
    echo "envelope: input contains a NUL byte, which frontmatter forbids" >&2
    exit 2
  fi
else
  value="$1"
fi
fm_quote "$value" || exit 2
echo

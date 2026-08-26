#!/usr/bin/env bash
# Validate collab-bus message frontmatter, version-aware.
#
# schema 1 (legacy, no `schema:` key) — the nine fields the bus already uses; unquoted
#   human values are tolerated but must still be parseable YAML.
# schema 2 (v0.8) — the strict field set; human values MUST be single-quoted.
#
# `publish.sh` calls this so a malformed message can never enter the bus, instead of being
# discovered later by whichever reader happens to parse it.
#
# Usage:  check-envelope.sh <file>...        validate
#         check-envelope.sh --quiet <file>   exit status only
# Exit:   0 all valid; 1 at least one invalid; 2 bad usage.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/envelope.sh"

quiet=0
[ "${1:-}" = "--quiet" ] && { quiet=1; shift; }
[ "$#" -ge 1 ] || { echo "usage: check-envelope.sh [--quiet] <file>..." >&2; exit 2; }

rc=0
for f in "$@"; do
  # Report every bad file rather than stopping at the first: a drain scanning an inbox
  # needs to know which message is broken and still process the others.
  # --quiet suppresses OUTPUT ONLY. It must never skip a check: a mode that validates
  # less would let a draft the loud mode rejects slip into the bus.
  if [ "$quiet" -eq 1 ]; then
    { envelope_check "$f" && envelope_yaml_check "$f"; } >/dev/null 2>&1 || rc=1
  else
    if envelope_check "$f"; then
      envelope_yaml_check "$f" || rc=1
    else
      rc=1
    fi
  fi
done
exit "$rc"

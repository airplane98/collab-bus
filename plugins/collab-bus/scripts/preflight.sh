#!/usr/bin/env bash
# collab-bus preflight — is this project's vendored bin complete and usable?
#
#   preflight.sh [--dir <project>]
#
# Prints the bin directory on success; on failure names what is wrong and tells the user
# to re-run bootstrap.
#
# RUN THE PLUGIN'S COPY, NOT THE PROJECT'S. This inspects a project's vendored bin, so
# running the project's own copy to decide whether the project's copies are trustworthy
# is circular — and not only in theory: an executable symlink at collab/bin/preflight.sh
# has already run its target by the time any check inside it says "symlinks are refused".
# The caller must start from code it already trusts (the installed plugin, or the peer's
# own clone) and let it vet the project. If the project copy is still genuine and is
# invoked by mistake, the runtime self-location checks below fail loud; that cannot stop
# a replaced executable, but it prevents a real vendored preflight from certifying any
# project — including a different project selected by a stale provider-local anchor.
#
# WHY THIS IS A SCRIPT AND NOT A CHECKLIST IN A DOCUMENT. The check used to live in
# `commands/send.md` as a for-loop over six names, and it was wrong in three ways at once:
# it omitted `lib/manifest.sh`, which `participant.sh` and `route.sh` both source (so the
# run died later at a shell source error instead of here, with a reason); it tested `-e`,
# so a non-executable script reported healthy and failed at its call site; and it decided
# the whole tree from ONE sentinel, so a project holding a half-vendored `collab/bin/`
# containing `participant.sh` but no `next-id.sh` silently switched every call to the
# plugin's own copies — the precise "half a bin quietly borrowing another version's
# entrypoints" the document itself said must never happen.
#
# A rule with fixtures behind it is a rule; the same rule written as prose is a hope.
#
# Exit: 0 usable (path on stdout); 1 incomplete or malformed; 2 bad usage.
set -euo pipefail

_pf_err() { echo "preflight: $1" >&2; }

# Resolve the file itself, not only its parent: an out-of-project symlink pointing at
# collab/bin/preflight.sh is still the project copy. `pwd -P` resolves symlinked parent
# directories; the loop resolves the leaf with a finite bound so a cycle fails loud.
_pf_self="${BASH_SOURCE[0]}"; _pf_links=0
while [ -L "$_pf_self" ]; do
  _pf_links=$((_pf_links+1))
  [ "$_pf_links" -le 40 ] || { _pf_err "cannot resolve preflight location (symlink cycle)"; exit 1; }
  _pf_target="$(readlink "$_pf_self")" \
    || { _pf_err "cannot resolve preflight symlink: $_pf_self"; exit 1; }
  case "$_pf_target" in
    /*) _pf_self="$_pf_target" ;;
    *)  _pf_self="$(dirname "$_pf_self")/$_pf_target" ;;
  esac
done
PREFLIGHT_SELF_DIR="$(cd "$(dirname "$_pf_self")" && pwd -P)" \
  || { _pf_err "cannot resolve preflight directory: $_pf_self"; exit 1; }
PREFLIGHT_SELF="$PREFLIGHT_SELF_DIR/$(basename "$_pf_self")"

# A trusted clone/install runs this file from its scripts/ directory. A bootstrapped
# project puts the same file directly under collab/bin. Reject that resolved shape
# independently of the target root: otherwise project A's genuine vendored copy can
# certify project B when a provider-local anchor is accidentally left pointing at A.
if [ "$(basename "$PREFLIGHT_SELF_DIR")" = bin ] \
  && [ "$(basename "$(dirname "$PREFLIGHT_SELF_DIR")")" = collab ]; then
  _pf_err "trust-anchor violation: preflight resolves inside a vendored collab/bin ($PREFLIGHT_SELF_DIR)"
  _pf_err "run preflight.sh from the installed plugin or an out-of-project trusted clone"
  exit 1
fi

DIR="."
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || { _pf_err "--dir needs a value"; exit 2; }; DIR="$2"; shift 2 ;;
    -h|--help) echo "usage: preflight.sh [--dir <project>]" >&2; exit 0 ;;
    *) _pf_err "unexpected argument '$1'"; exit 2 ;;
  esac
done

ROOT="${COLLAB_ROOT:-$DIR/collab}"
# Every DIRECTORY on the way down, not just the leaves. Checking only leaf files leaves
# `-L` false for all of them while the whole tree hangs off a symlinked parent: a
# symlinked collab/bin/lib passed cleanly, and participant.sh and route.sh then sourced
# their libraries from wherever it pointed.
[ -L "$ROOT" ] && { _pf_err "$ROOT is a symlink — refusing"; exit 1; }
if [ ! -d "$ROOT" ]; then
  _pf_err "$ROOT does not exist — run /collab-bus:init (or bootstrap.sh) first"
  exit 1
fi

# Runtime trust-anchor enforcement, before sourcing even our inventory. Documentation
# and doclint cannot see what a peer put in its provider-local environment; a genuine
# project-owned preflight must therefore refuse to certify the tree that contains itself.
# This does not save an executable symlink whose attacker target replaced this code —
# nothing inside the real preflight runs in that case — but it closes accidental or
# persistent self-vetting while project-owned code is still genuine. The earlier
# collab/bin shape check separately closes one project's vendored copy certifying another.
ROOT_REAL="$(cd "$ROOT" && pwd -P)" \
  || { _pf_err "cannot resolve inspected collab root: $ROOT"; exit 1; }
case "$PREFLIGHT_SELF" in
  "$ROOT_REAL"/*)
    _pf_err "trust-anchor violation: preflight resolves inside the collab root it was asked to inspect ($ROOT_REAL)"
    _pf_err "run preflight.sh from the installed plugin or an out-of-project trusted clone"
    exit 1 ;;
esac

# The inventory is sourced, not restated. It is deliberately loaded only AFTER the
# self-location check: a project copy must not execute its vendored inventory before it
# has refused to certify that project.
. "$PREFLIGHT_SELF_DIR/lib/inventory.sh"

# Never fall back to the plugin's own scripts once a project exists: that is how two
# entrypoints end up enforcing different contracts in the same bus.
BIN="$ROOT/bin"
[ -L "$BIN" ] && { _pf_err "$BIN is a symlink — refusing"; exit 1; }
[ -d "$BIN" ] || { _pf_err "$BIN does not exist — re-run bootstrap.sh"; exit 1; }
[ -L "$BIN/lib" ] && { _pf_err "$BIN/lib is a symlink — refusing"; exit 1; }
[ -d "$BIN/lib" ] || { _pf_err "$BIN/lib does not exist — re-run bootstrap.sh"; exit 1; }

bad=0
for t in $COLLAB_BINS; do
  if   [ -L "$BIN/$t" ]; then _pf_err "$BIN/$t is a symlink"; bad=1
  elif [ ! -f "$BIN/$t" ]; then _pf_err "$BIN/$t is missing"; bad=1
  elif [ ! -r "$BIN/$t" ]; then _pf_err "$BIN/$t is not readable"; bad=1
  elif [ ! -x "$BIN/$t" ]; then _pf_err "$BIN/$t is not executable"; bad=1
  fi
done
for l in $COLLAB_LIBS; do
  if   [ -L "$BIN/$l" ]; then _pf_err "$BIN/$l is a symlink"; bad=1
  elif [ ! -f "$BIN/$l" ]; then _pf_err "$BIN/$l is missing"; bad=1
  elif [ ! -r "$BIN/$l" ]; then _pf_err "$BIN/$l is not readable"; bad=1
  fi
done
if [ "$bad" != 0 ]; then
  _pf_err "this bin is incomplete — re-run bootstrap.sh to re-vendor it"
  exit 1
fi
printf '%s\n' "$BIN"

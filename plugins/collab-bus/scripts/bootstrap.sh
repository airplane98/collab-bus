#!/usr/bin/env bash
# collab-bus bootstrap — set up (or update) the bus in a project. PROVIDER-NEUTRAL.
#
# WHY THIS EXISTS (v0.7): collab-bus ships as a Claude Code plugin, so until now the
# only way to create a bus was `/collab-bus:init` — i.e. only Claude Code could start
# one. But the collaboration is symmetric: the peer can just as well be the side that
# sets things up. This is the provider-neutral runtime entrypoint — plain bash, run it
# from a clone of the repo and any CLI (or a human) can scaffold a bus:
#
#   /path/to/collab-bus/plugins/collab-bus/scripts/bootstrap.sh [peer] [--dir <project>]
#
# (It still lives inside the plugin tree and reads the plugin manifest for the version
# stamp, so it needs the repo — what it does not need is Claude Code itself.)
#
# `/collab-bus:init` now CALLS this script rather than re-describing the same steps in
# prose — one implementation, so the two paths cannot drift apart. What init still does
# on top is the part that needs an agent's judgement: wiring the peer as a herdr agent,
# writing the onboarding message, and running the handshake.
#
# What it does:
#   fresh project  — scaffold collab/, vendor collab/bin/{next-id,publish,knock,
#                    check-envelope,fm-quote}.sh plus collab/bin/lib/envelope.sh,
#                    render collab/PROTOCOL.md from the template (stamped with the
#                    plugin version).
#   existing bus   — MIGRATE: re-vendor collab/bin/ only. It never overwrites
#                    PROTOCOL.md (it usually carries project-specific edits) and never
#                    touches message files; it reports what to patch by hand.
#
# Safety: it refuses to write through a symlink (a symlinked collab/, collab/bin/, or
# vendored file could redirect the write outside the project), and re-vendors via a
# staging file + rename so an existing destination's inode is never written through.
#
# Scope limit: the generated PROTOCOL describes a **Claude Code + <peer>** pair, so
# either of those two may run this. A bus between two non-Claude agents would need the
# template's role names generalised — not done here.
#
# Exit: 0 scaffolded or migrated; 2 bad usage; 1 unsafe/missing source or target.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SELF/.." && pwd -P)"
TEMPLATE="$PLUGIN_ROOT/templates/PROTOCOL.template.md"
MANIFEST="$PLUGIN_ROOT/.claude-plugin/plugin.json"
# publish.sh REQUIRES lib/envelope.sh — vendoring the script without its gate would
# leave a bus that silently accepts unvalidated messages, so the library and the two
# envelope CLIs ship together with the rest. Entries may contain a directory component.
VENDOR=(next-id.sh publish.sh knock.sh check-envelope.sh fm-quote.sh lib/envelope.sh)

usage() { echo "usage: bootstrap.sh [peer] [--dir <project>]   (peer defaults to codex)" >&2; }

PEER=codex
DIR="$PWD"
peer_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      # Explicit arity check: `${2:?}` would exit 1, but the contract says bad usage is 2.
      [ $# -ge 2 ] || { echo "error: --dir needs a path" >&2; usage; exit 2; }
      DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "error: unknown option '$1'" >&2; usage; exit 2 ;;
    *)
      # One peer only: silently taking the last of `codex gemini` would scaffold a bus
      # the caller did not ask for.
      [ "$peer_set" -eq 0 ] || { echo "error: unexpected extra argument '$1' — exactly one peer name" >&2; usage; exit 2; }
      PEER="$1"; peer_set=1; shift ;;
  esac
done

# The peer name becomes a directory (inbox/to/<peer>/), so hold it to the same
# allowlist next-id.sh applies to a recipient.
if ! [[ "$PEER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "error: peer '$PEER' must start with a letter or digit and match [A-Za-z0-9._-]*" >&2; exit 2
fi
# Case-insensitively: 'Claude' would pass a literal check and then, on a
# case-insensitive filesystem (macOS default), inbox/to/Claude and inbox/to/claude are
# the SAME directory — one addressee where the bus needs two. Pattern form works on the
# bash 3.2 that ships with macOS.
case "$PEER" in
  [Cc][Ll][Aa][Uu][Dd][Ee])
    echo "error: the peer cannot be '$PEER' — that is the other side of the bus" >&2; exit 2 ;;
esac

[ -f "$TEMPLATE" ] || { echo "error: template not found: $TEMPLATE" >&2; exit 1; }
[ -d "$DIR" ] || { echo "error: target directory not found: $DIR" >&2; exit 1; }
DIR="$(cd "$DIR" && pwd -P)"

for f in "${VENDOR[@]}"; do
  [ -f "$SELF/$f" ] || { echo "error: missing source script: $SELF/$f" >&2; exit 1; }
done

# Version stamp for the generated PROTOCOL, resolved BEFORE any mutation. This is the
# provenance contract ("this PROTOCOL and this collab/bin/ are the same version"), so a
# manifest we cannot parse is a hard error — never scaffold a "vunknown" bus.
[ -r "$MANIFEST" ] || { echo "error: cannot read the plugin manifest: $MANIFEST" >&2; exit 1; }
VERSION_RAW="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)"
# Anchored at both ends: three numeric parts, then an optional prerelease (-…) and an
# optional build (+…) suffix, in that order. Unanchored, "0.7.0garbage" would pass and
# get stamped into the PROTOCOL. This is an approximation of SemVer sufficient for our
# own manifest — it does not reject every malformed identifier (e.g. "1.2.3-.").
if ! [[ "$VERSION_RAW" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "error: no usable \"version\" in $MANIFEST (got '${VERSION_RAW}') — refusing to stamp an unknown version" >&2
  exit 1
fi
VERSION="v$VERSION_RAW"

COLLAB="$DIR/collab"

# Refuse to write through a symlink: `cp` follows one, so a symlinked collab/, bin/, or
# vendored file would silently redirect writes outside the project.
reject_symlink() { # <path> <label>
  [ -L "$1" ] && { echo "error: $2 is a symlink — refusing to write through it: $1" >&2; exit 1; }
  return 0
}

STAGE=""
cleanup() { [ -n "$STAGE" ] && rm -rf "$STAGE"; return 0; }
trap cleanup EXIT

vendor_scripts() {
  reject_symlink "$COLLAB/bin" "collab/bin"
  mkdir -p "$COLLAB/bin"
  [ -d "$COLLAB/bin" ] || { echo "error: $COLLAB/bin is not a directory" >&2; exit 1; }

  # Stage into a PRIVATE, RANDOM directory created by mktemp -d, not a predictable
  # name like ".$f.tmp.$$": a guessable staging path can be pre-created as a symlink,
  # and `cp` would then write straight through it (and the later rename would install
  # that symlink as the final script). mktemp creates the directory exclusively, so
  # there is nothing to pre-plant. It sits inside collab/bin so the rename below stays
  # within one filesystem.
  STAGE="$(mktemp -d "$COLLAB/bin/.stage.XXXXXX")" || {
    echo "error: could not create a staging directory under $COLLAB/bin" >&2; exit 1; }

  # Three phases, in this order, so no destination is touched until EVERY source and
  # EVERY destination has been checked. Validating a destination inside the replace
  # loop would already have swapped script #1 by the time script #2 turns out to be
  # unsafe — a failed migration must not leave a mixed-version collab/bin.
  local f dest

  # 1. stage all
  for f in "${VENDOR[@]}"; do
    mkdir -p "$STAGE/$(dirname "$f")"
    cp "$SELF/$f" "$STAGE/$f"
    chmod +x "$STAGE/$f"
    if [ -L "$STAGE/$f" ] || [ ! -f "$STAGE/$f" ]; then
      echo "error: staged $f is not a regular file — aborting" >&2; exit 1
    fi
  done

  # 2. preflight all destinations
  for f in "${VENDOR[@]}"; do
    dest="$COLLAB/bin/$f"
    # A vendored path may sit in a subdirectory (lib/); that directory must be a real
    # directory we own, not a symlink pointing out of the project.
    if [ "$f" != "$(basename "$f")" ]; then
      local pdir="$(dirname "$dest")"
      reject_symlink "$pdir" "collab/bin/$(dirname "$f")"
      # It must also not be an existing REGULAR FILE. Checking only for a symlink let
      # such a parent pass preflight, and `mkdir -p` then failed in phase 3 — after the
      # top-level scripts had already been replaced, leaving exactly the half-migrated
      # bin the three-phase split exists to prevent.
      if [ -e "$pdir" ] && [ ! -d "$pdir" ]; then
        echo "error: $pdir exists and is not a directory — refusing to install $f" >&2; exit 1
      fi
    fi
    reject_symlink "$dest" "collab/bin/$f"
    if [ -e "$dest" ] && [ ! -f "$dest" ]; then
      echo "error: $dest exists and is not a regular file — refusing to replace it" >&2; exit 1
    fi
  done

  # 2.5 create every missing parent directory now, while nothing has been replaced yet.
  # Doing it inside the replace loop means a mkdir failure lands mid-way through.
  for f in "${VENDOR[@]}"; do
    if [ "$f" != "$(basename "$f")" ]; then
      mkdir -p "$COLLAB/bin/$(dirname "$f")" || {
        echo "error: could not create collab/bin/$(dirname "$f")" >&2; exit 1; }
    fi
  done

  # 3. replace all. rename(2) swaps the directory ENTRY, so an existing inode is never
  # written through — a hard link elsewhere keeps its old content. (A rename failing on
  # I/O mid-way is still not transactional across the three files; this closes every
  # partial state that can be detected up front, not that one.)
  for f in "${VENDOR[@]}"; do
    mv -f "$STAGE/$f" "$COLLAB/bin/$f"
  done
  rm -rf "$STAGE"; STAGE=""
}

# herdr carries the transport; the files are still worth scaffolding without it, so
# warn rather than fail — but say so plainly, since knock.sh will not work until then.
if ! command -v herdr >/dev/null 2>&1; then
  echo "warning: herdr not found — collab/bin/knock.sh cannot run until you install it (https://herdr.dev)." >&2
fi

if [ -e "$COLLAB" ] || [ -L "$COLLAB" ]; then
  # --- migrate ---------------------------------------------------------------
  reject_symlink "$COLLAB" "collab"
  [ -d "$COLLAB" ] || { echo "error: $COLLAB exists but is not a directory" >&2; exit 1; }
  vendor_scripts
  echo "migrated: re-vendored ${#VENDOR[@]} scripts into collab/bin/ at $VERSION (${VENDOR[*]})"
  if [ -f "$COLLAB/PROTOCOL.md" ]; then
    echo "kept: collab/PROTOCOL.md was NOT overwritten (it may carry project-specific edits)."
    echo "      Patch it by hand where it disagrees with $VERSION — the id-allocation,"
    echo "      transport (both directions go through collab/bin/knock.sh), and version lines."
  else
    echo "note: no collab/PROTOCOL.md found — write one from"
    echo "      $TEMPLATE (substitute {{PROJECT}}, {{PEER}}, {{VERSION}})."
  fi
  exit 0
fi

# --- fresh scaffold ----------------------------------------------------------
if command -v git >/dev/null 2>&1 && top="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  PROJECT="$(basename "$top")"
else
  PROJECT="$(basename "$DIR")"
fi

for d in "inbox/to/$PEER" "inbox/to/claude" "inbox/archive" "reviews" "tasks"; do
  mkdir -p "$COLLAB/$d"
  : > "$COLLAB/$d/.gitkeep"
done
# Defense in depth for the case-folding hazard above: the two inboxes must be two
# distinct directories, whatever the filesystem does with case.
if [ "$COLLAB/inbox/to/$PEER" -ef "$COLLAB/inbox/to/claude" ]; then
  echo "error: inbox/to/$PEER and inbox/to/claude are the same directory on this filesystem — pick another peer name" >&2
  exit 1
fi
vendor_scripts

# Substitute with bash parameter expansion, not sed: a project name containing / or &
# would corrupt a sed replacement. Bash 5.2+ then adds its own trap — with
# patsub_replacement (on by default there) an unescaped & in the REPLACEMENT expands to
# the matched text, so "a&b" would render as "a{{PROJECT}}b". Turn it off; older bash
# has no such option, hence the tolerated failure.
shopt -u patsub_replacement 2>/dev/null || true
content="$(cat "$TEMPLATE")"
content="${content//\{\{PROJECT\}\}/$PROJECT}"
content="${content//\{\{PEER\}\}/$PEER}"
content="${content//\{\{VERSION\}\}/$VERSION}"
if ! ( set -o noclobber; printf '%s\n' "$content" > "$COLLAB/PROTOCOL.md" ) 2>/dev/null; then
  echo "error: $COLLAB/PROTOCOL.md already exists — refusing to overwrite" >&2; exit 1
fi

cat <<EOF
scaffolded collab-bus $VERSION in $DIR
  collab/PROTOCOL.md              the shared contract (Claude Code ⇄ $PEER) — read it first
  collab/bin/                     next-id.sh, publish.sh, knock.sh (both sides call these)
  collab/inbox/to/{claude,$PEER}/ message boxes; collab/inbox/archive/ for processed ones

next:
  1. run both agents as herdr agents in the SAME herdr tab (that tab is the pair).
  2. send the first message: DRAFT=\$(collab/bin/next-id.sh <recipient> <slug> <your-tab-id>)
     → write the body into \$DRAFT → DEST=\$(collab/bin/publish.sh "\$DRAFT")
     → collab/bin/knock.sh <peer-pane-id> "process \$DEST"
  3. either side may initiate; see PROTOCOL.md for pair routing and the async mode.
EOF

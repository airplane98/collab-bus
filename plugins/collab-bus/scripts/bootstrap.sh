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
#                    render the protocol files from the templates (stamped with the
#                    plugin version) and record what it wrote in collab/.protocol-vendored.
#   existing bus   — MIGRATE: re-vendor collab/bin/, never touch message files, and:
#                    · v0.9 layout (collab/.protocol-vendored present): update each
#                      collab-bus-owned protocol file (PROTOCOL.md, PROTOCOL-modes.md,
#                      DESIGN-DECISIONS.md) whose hash still matches what was recorded;
#                      a file a human edited is KEPT and reported, never overwritten.
#                      collab/PROJECT.md belongs to the project and is never overwritten.
#                    · older bus (no .protocol-vendored): protocol files are left alone,
#                      as before; `--adopt` opts in to the v0.9 layout, backing the
#                      current files up as *.pre-<version> first.
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
#
# Options: --dir <project>  target another directory (default: cwd)
#          --adopt          (older bus only) switch to the v0.9 protocol layout
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SELF/.." && pwd -P)"
TPL_DIR="$PLUGIN_ROOT/templates"
TEMPLATE="$TPL_DIR/PROTOCOL.template.md"
# collab-bus OWNS these and may replace them on a re-run; the project owns PROJECT.md.
PROTO_GENERIC="PROTOCOL.md PROTOCOL-modes.md DESIGN-DECISIONS.md"
PROTO_MF_NAME=".protocol-vendored"
MANIFEST="$PLUGIN_ROOT/.claude-plugin/plugin.json"
# publish.sh REQUIRES lib/envelope.sh — vendoring the script without its gate would
# leave a bus that silently accepts unvalidated messages, so the library and the two
# envelope CLIs ship together with the rest. Entries may contain a directory component.
# What gets vendored comes from the shared inventory, so the writer and the checker
# cannot disagree about what a complete bin is (lib/inventory.sh).
. "$SELF/lib/inventory.sh"
# shellcheck disable=SC2206
VENDOR=($COLLAB_BINS $COLLAB_LIBS)

usage() { echo "usage: bootstrap.sh [peer] [--dir <project>] [--adopt]   (peer defaults to codex)" >&2; }

PEER=codex
DIR="$PWD"
ADOPT=0
peer_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      # Explicit arity check: `${2:?}` would exit 1, but the contract says bad usage is 2.
      [ $# -ge 2 ] || { echo "error: --dir needs a path" >&2; usage; exit 2; }
      DIR="$2"; shift 2 ;;
    --adopt) ADOPT=1; shift ;;
    -h|--help) sed -n '2,46p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

# Exists, is readable, is non-empty: an unreadable or empty template must stop us HERE,
# before anything is touched — rendering one would replace a working protocol with an
# empty file (seen in review: rc=0, "updated:", 5 KB of rules gone).
for _t in PROTOCOL PROTOCOL-modes DESIGN-DECISIONS PROJECT; do
  _tf="$TPL_DIR/$_t.template.md"
  [ -f "$_tf" ] || { echo "error: template not found: $_tf" >&2; exit 1; }
  [ -r "$_tf" ] || { echo "error: template not readable: $_tf" >&2; exit 1; }
  [ -s "$_tf" ] || { echo "error: template is empty: $_tf" >&2; exit 1; }
done
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
BUSJSON="$COLLAB/bus.json"

# bus.json is the MACHINE-READABLE capability manifest and is tooling-owned: unlike
# PROTOCOL.md (prose a human maintains, which bootstrap never rewrites) this file must be
# authoritative, so peers negotiate on facts rather than on a version somebody typed.
# The codec lives in lib/manifest.sh — it is parsed, never grepped, because a per-key
# search happily finds a valid-looking id inside a corrupt file and launders it.
. "$SELF/lib/manifest.sh"
. "$SELF/lib/envelope.sh"          # _env_has_control, for rejecting a control byte in the alias
BUS_SCHEMAS_READ='1, 2'
BUS_SCHEMAS_WRITE=2                # step 4: writers emit schema 2, legacy pair + status kept
BUS_SCHEMAS_MIN_READER=1
# Bind the codec's notion of "what this tooling supports" to THIS binary, unconditionally.
# manifest.sh keeps an env-overridable default so the library stays testable, but a
# fail-closed capability policy that an inherited environment variable can switch off is
# not a policy: `MF_TOOLING_READ=1,2,3 bootstrap.sh` downgraded a newer manifest.
MF_TOOLING_READ="$(printf '%s' "$BUS_SCHEMAS_READ" | tr -d ' ')"
MF_TOOLING_WRITE="$BUS_SCHEMAS_WRITE"

# Refuse to write through a symlink: `cp` follows one, so a symlinked collab/, bin/, or
# vendored file would silently redirect writes outside the project.
reject_symlink() { # <path> <label>
  [ -L "$1" ] && { echo "error: $2 is a symlink — refusing to write through it: $1" >&2; exit 1; }
  return 0
}

STAGE=""
BUS_TMP=""
PROTO_TMP=""   # a protocol-file temp between mktemp and its rename (v0.9)
cleanup() {
  [ -n "$STAGE" ] && rm -rf -- "$STAGE"
  [ -n "$BUS_TMP" ] && rm -f -- "$BUS_TMP"
  [ -n "$PROTO_TMP" ] && rm -f -- "$PROTO_TMP"
  return 0
}
trap cleanup EXIT

# plan_bus_json — decide the manifest content WITHOUT touching anything. Runs before
# vendor_scripts so a bad manifest cannot leave half-replaced scripts behind (the failure
# mode step 1 closed for vendored files and this reopened for the manifest).
# Sets BUS_PLAN_ID / BUS_PLAN_ALIAS / BUS_PLAN_MIN / BUS_PLAN_EXISTS.
plan_bus_json() { # <default-alias>
  BUS_PLAN_ALIAS="$1"; BUS_PLAN_MIN="$BUS_SCHEMAS_MIN_READER"; BUS_PLAN_EXISTS=0
  if [ -e "$BUSJSON" ] || [ -L "$BUSJSON" ]; then
    reject_symlink "$BUSJSON" "collab/bus.json"
    [ -f "$BUSJSON" ] || { echo "error: $BUSJSON exists and is not a regular file" >&2; exit 1; }
    # Not bare: `set -e` would kill us on the very statuses we are about to branch on.
    local mrc=0
    MF_OUR_VERSION="$VERSION_RAW" manifest_read_strict "$BUSJSON" || mrc=$?
    case $mrc in
      0) : ;;
      3) echo "error: refusing to rewrite $BUSJSON (see above)" >&2; exit 1 ;;
      *) echo "error: $BUSJSON is not a manifest this tooling can read — fix or remove it by hand;" >&2
         echo "       a project's identity is minted once and must not be guessed at." >&2
         exit 1 ;;
    esac
    manifest_json_check "$BUSJSON" || { echo "error: $BUSJSON is not valid JSON — refusing to rewrite it" >&2; exit 1; }
    BUS_PLAN_EXISTS=1
    BUS_PLAN_ID="$MF_PROJECT_ID"
    # human-owned fields survive; tooling-owned ones get refreshed below
    BUS_PLAN_ALIAS="$MF_PROJECT_ALIAS"
    BUS_PLAN_MIN="$MF_MIN_READER"
  else
    BUS_PLAN_ID="$(COLLAB_NEXT_ID_LIB=1 . "$SELF/next-id.sh" && ulid)" || {
      echo "error: could not mint a project_id" >&2; exit 1; }
  fi
  if _env_has_control "$BUS_PLAN_ALIAS"; then
    echo "error: project alias contains a control character — refusing" >&2; exit 1
  fi
}

commit_bus_json() {
  # The staging path goes in a GLOBAL that the existing EXIT cleanup removes with proper
  # quoting. Interpolating it into a trap string — `trap "rm -f '$tmp'" RETURN` — makes
  # the project's own path part of a command that gets evaluated later: a directory named
  # `x'; touch PWNED; echo '` executed arbitrary shell AND injected text into this
  # function's stdout, corrupting the project_id it returns.
  BUS_TMP="$(mktemp "$COLLAB/.bus.json.XXXXXX")" || { echo "error: could not stage $BUSJSON" >&2; exit 1; }
  local tmp="$BUS_TMP"
  manifest_render "$BUS_PLAN_ID" "$BUS_PLAN_ALIAS" "$BUS_SCHEMAS_READ" \
                  "$BUS_SCHEMAS_WRITE" "$BUS_PLAN_MIN" "$VERSION_RAW" > "$tmp"
  if [ "$BUS_PLAN_EXISTS" -eq 1 ]; then
    mv -f -- "$tmp" "$BUSJSON"; BUS_TMP=""
  else
    # FIRST creation is no-replace: two bootstraps racing on a fresh bus would otherwise
    # each mint an id and the last rename would win, leaving one caller holding a project
    # identity that no longer exists on disk. link() fails atomically if we lost.
    if ln -- "$tmp" "$BUSJSON" 2>/dev/null; then
      rm -f -- "$tmp"; BUS_TMP=""
    else
      rm -f -- "$tmp"; BUS_TMP=""
      MF_OUR_VERSION="$VERSION_RAW" manifest_read_strict "$BUSJSON" || {
        echo "error: lost the race to create $BUSJSON, and the winner's manifest is unreadable" >&2; exit 1; }
      :
      BUS_PLAN_ID="$MF_PROJECT_ID"     # adopt the winner's identity, do not invent a second
    fi
  fi
  # Never trust rc alone: re-read what actually landed.
  MF_OUR_VERSION="$VERSION_RAW" manifest_read_strict "$BUSJSON" >/dev/null || {
    echo "error: $BUSJSON did not validate after writing" >&2; exit 1; }
  printf '%s' "$MF_PROJECT_ID"
}

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

# Two phases, because "validate before writing" has to mean before EVERY write, not just
# before the registry's own. A peer name that cannot become a legal participant id used to
# fail only after the tree, manifest, scripts and PROTOCOL had already been created (fresh)
# or after the vendored scripts had been replaced (migrate).
REG_IDS=""; REG_KINDS=""
plan_registry() { # <peer> — READ ONLY: derives ids and validates whatever already exists
  local peer="$1" lower id kind i=0
  lower="$(printf '%s' "$peer" | tr 'A-Z' 'a-z')"
  REG_IDS="claude-primary $lower-primary"
  REG_KINDS="claude $lower"
  for id in $REG_IDS; do
    i=$((i+1)); kind="$(printf '%s' "$REG_KINDS" | cut -d' ' -f$i)"
    if ! [[ "$id" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then
      echo "error: peer '$peer' does not yield a legal participant id (got '$id')" >&2
      echo "       register one by hand later: collab/bin/participant.sh register <id> --kind $kind" >&2
      exit 1
    fi
    # Existing artifacts are validated here — including the expected kind, and refusing a
    # symlink outright rather than through a validator that would follow it.
    if [ -L "$COLLAB/participants/$id.json" ]; then
      echo "error: collab/participants/$id.json is a symlink — refusing" >&2; exit 1
    fi
    if [ -e "$COLLAB/participants/$id.json" ]; then
      # `validate` is read-only. Using `register` to check the kind made the "plan" phase
      # stage and link files, and it also compared the ALIAS — which bootstrap does not
      # own: a legitimate hand-set alias made migrate fail with a bogus kind-mismatch.
      COLLAB_ROOT="$COLLAB" "$SELF/participant.sh" validate "$id" --kind "$kind" \
        || { echo "error: existing participant $id is unreadable, or is not kind '$kind' — fix it by hand" >&2; exit 1; }
    fi
  done
  for d in participants bindings; do
    reject_symlink "$COLLAB/$d" "collab/$d"
    [ -e "$COLLAB/$d" ] && [ ! -d "$COLLAB/$d" ] \
      && { echo "error: $COLLAB/$d exists and is not a directory" >&2; exit 1; }
  done
  return 0
}

commit_registry() { # create-missing-only; everything was validated by plan_registry
  local d id kind i=0
  # Re-check destination safety here too: plan ran before the tree existed, and something
  # could have appeared in between.
  for d in participants bindings; do
    reject_symlink "$COLLAB/$d" "collab/$d"
  done
  for d in participants bindings; do
    mkdir -p "$COLLAB/$d" || { echo "error: could not create $COLLAB/$d" >&2; exit 1; }
  done
  for id in $REG_IDS; do
    i=$((i+1)); kind="$(printf '%s' "$REG_KINDS" | cut -d' ' -f$i)"
    [ -e "$COLLAB/participants/$id.json" ] && continue
    COLLAB_ROOT="$COLLAB" "$SELF/participant.sh" register "$id" --kind "$kind" >/dev/null \
      || { echo "error: could not declare participant $id" >&2; exit 1; }
  done
}

# --- protocol files (v0.9) ----------------------------------------------------
# collab-bus owns PROTOCOL.md / PROTOCOL-modes.md / DESIGN-DECISIONS.md and may replace
# them on a re-run; the project owns PROJECT.md, which is never overwritten. What was
# last installed is recorded (sha256) in collab/.protocol-vendored, so a re-run can tell
# an untouched file (safe to update) from one a human edited (KEPT, with a warning).
# Keeping rather than refusing preserves the migrate contract — a re-run still succeeds
# and still refreshes collab/bin/ — and keeping rather than overwriting never eats the
# project's rules. Rationale: DESIGN-DECISIONS.md §D.
PROTO_MF="$COLLAB/$PROTO_MF_NAME"
# Every render substitutes with bash parameter expansion, not sed: a project name
# containing / or & would corrupt a sed replacement. Bash 5.2+ then adds its own trap —
# with patsub_replacement (on by default there) an unescaped & in the REPLACEMENT expands
# to the matched text, so "a&b" would render as "a{{PROJECT}}b". Turn it off here, before
# any render in either path; older bash has no such option, hence the tolerated failure.
shopt -u patsub_replacement 2>/dev/null || true

proto_template() { # <dest-name> → template path
  case "$1" in
    PROTOCOL.md)         printf '%s\n' "$TPL_DIR/PROTOCOL.template.md" ;;
    PROTOCOL-modes.md)   printf '%s\n' "$TPL_DIR/PROTOCOL-modes.template.md" ;;
    DESIGN-DECISIONS.md) printf '%s\n' "$TPL_DIR/DESIGN-DECISIONS.template.md" ;;
    PROJECT.md)          printf '%s\n' "$TPL_DIR/PROJECT.template.md" ;;
    *) return 1 ;;
  esac
}

sha256_of() { # <file> → lowercase hex on stdout
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else echo "error: need shasum or sha256sum to track the protocol files" >&2; return 1
  fi
}

# Staged renders live in these variables between PLAN and COMMIT (bash 3.2: no
# associative arrays), keyed by proto_key.
R_PROTOCOL=""; R_MODES=""; R_DD=""; R_PROJECT=""
proto_key() { # <dest-name> → variable holding its staged render
  case "$1" in
    PROTOCOL.md) echo R_PROTOCOL ;; PROTOCOL-modes.md) echo R_MODES ;;
    DESIGN-DECISIONS.md) echo R_DD ;; PROJECT.md) echo R_PROJECT ;; *) return 1 ;;
  esac
}

# Render <dest-name>'s template for <project> into its staging variable. Runs in the PLAN
# phase, so a failure stops the run before anything on disk changes.
# Callers use `proto_stage … || exit 1`, which switches `set -e` OFF in here: every step
# must check its own failure. Letting `cat` fail silently is exactly the review bug — the
# template renders as an empty string, the empty string is written over a working file.
proto_stage() { # <dest-name> <project>
  local tpl var c
  tpl="$(proto_template "$1")" || { echo "error: no template for $1" >&2; return 1; }
  var="$(proto_key "$1")" || { echo "error: no staging slot for $1" >&2; return 1; }
  c="$(cat "$tpl")" || { echo "error: cannot read template $tpl" >&2; return 1; }
  [ -n "$c" ] || { echo "error: template $tpl rendered empty — refusing" >&2; return 1; }
  c="${c//\{\{PROJECT\}\}/$2}"
  c="${c//\{\{PEER\}\}/$PEER}"
  c="${c//\{\{VERSION\}\}/$VERSION}"
  printf -v "$var" '%s' "$c"
}

proto_staged() { # <dest-name> → its staged render on stdout
  local var; var="$(proto_key "$1")" || return 1
  printf '%s\n' "${!var}"
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else return 1
  fi
}

# Write <dest-name>'s staged render to <dest> via a temp in collab/ + rename, so an
# existing file's inode — including a hard-linked one — is never written through.
proto_write() { # <dest-name> <dest>
  PROTO_TMP="$(mktemp "$COLLAB/.proto.XXXXXX")" || { PROTO_TMP=""; echo "error: cannot create a temp file in $COLLAB" >&2; return 1; }
  proto_staged "$1" > "$PROTO_TMP" || { echo "error: cannot write $PROTO_TMP" >&2; return 1; }
  mv -f "$PROTO_TMP" "$2" || { echo "error: cannot install $2" >&2; return 1; }
  PROTO_TMP=""
}

# A destination must be absent or a regular file; never a symlink (it could redirect the
# write) and never something else.
proto_dest_ok() { # <path> <label>
  if [ -L "$1" ]; then echo "error: $2 is a symlink — refusing to write through it" >&2; return 1; fi
  if [ -e "$1" ] && [ ! -f "$1" ]; then echo "error: $2 exists and is not a regular file" >&2; return 1; fi
}

proto_recorded() { # <dest-name> → recorded hash (empty if none)
  [ -f "$PROTO_MF" ] || return 0
  awk -v f="$1" '$2==f && $1 ~ /^[0-9a-f]+$/ && length($1)==64 {print $1; exit}' "$PROTO_MF"
}

# <name>=<hash> pairs on stdin; written via temp + rename.
proto_write_manifest() {
  local tmp line
  tmp="$(mktemp "$COLLAB/.proto.XXXXXX")" || { echo "error: cannot create a temp file in $COLLAB" >&2; return 1; }
  {
    echo "# collab-bus protocol manifest — written by bootstrap.sh; do not edit."
    echo "# What bootstrap last installed, so a re-run can tell an untouched protocol file"
    echo "# (safe to update) from one a human edited (kept). See DESIGN-DECISIONS.md §D."
    echo "version $VERSION"
    while IFS='=' read -r name hash; do
      # `if`, not `&&`: a false test as the loop's last command would make the whole
      # while return 1, and under `set -e` + pipefail that aborts the migration.
      if [ -n "$hash" ]; then printf '%s  %s\n' "$hash" "$name"; fi
    done
  } > "$tmp"
  mv -f "$tmp" "$PROTO_MF"
}

# PLAN (migrate): decide the mode and check every destination BEFORE anything — collab/bin
# included — is replaced, so an unsafe protocol file aborts a migration cleanly.
plan_protocol() { # <project>
  PROTO_MODE=legacy
  proto_dest_ok "$PROTO_MF" "collab/$PROTO_MF_NAME" || exit 1
  if [ -f "$PROTO_MF" ]; then
    PROTO_MODE=update
  elif [ "$ADOPT" -eq 1 ]; then
    PROTO_MODE=adopt
  fi
  [ "$PROTO_MODE" = legacy ] && return 0
  sha256_of /dev/null >/dev/null || exit 1
  local f
  for f in $PROTO_GENERIC PROJECT.md; do
    proto_dest_ok "$COLLAB/$f" "collab/$f" || exit 1
  done
  if [ "$PROTO_MODE" = adopt ]; then
    for f in $PROTO_GENERIC; do
      [ -e "$COLLAB/$f" ] || continue
      if [ -e "$COLLAB/$f.pre-$VERSION" ] || [ -L "$COLLAB/$f.pre-$VERSION" ]; then
        echo "error: backup collab/$f.pre-$VERSION already exists — move it away and re-run --adopt" >&2
        exit 1
      fi
    done
  fi
  # Render everything now, while nothing has been touched: a template that cannot be
  # rendered aborts the run with collab/bin, the protocol files and the manifest intact.
  for f in $PROTO_GENERIC; do proto_stage "$f" "$1" || exit 1; done
  if [ ! -e "$COLLAB/PROJECT.md" ]; then proto_stage PROJECT.md "$1" || exit 1; fi
}

# COMMIT (migrate): apply the mode chosen by plan_protocol, from the renders it staged.
commit_protocol() {
  local f new cur rec pairs=""
  case "$PROTO_MODE" in
    legacy)
      if [ -f "$COLLAB/PROTOCOL.md" ]; then
        echo "kept: collab/PROTOCOL.md was NOT overwritten (it may carry project-specific edits)."
        echo "      Patch it by hand where it disagrees with $VERSION — the id-allocation,"
        echo "      transport (both directions go through collab/bin/knock.sh), and version lines."
      else
        echo "note: no collab/PROTOCOL.md found — write one from"
        echo "      $TEMPLATE (substitute {{PROJECT}}, {{PEER}}, {{VERSION}})."
      fi
      echo "note: this bus predates the v0.9 protocol layout, so its protocol files are never"
      echo "      updated automatically. To adopt it: move this project's own rules into"
      echo "      collab/PROJECT.md (see $TPL_DIR/PROJECT.template.md), then re-run with"
      echo "      --adopt — the current protocol files are backed up as *.pre-$VERSION first."
      return 0 ;;
    adopt)
      for f in $PROTO_GENERIC; do
        new="$(proto_staged "$f" | sha256_stdin)" || exit 1
        if [ -e "$COLLAB/$f" ]; then
          ( set -o noclobber; cat "$COLLAB/$f" > "$COLLAB/$f.pre-$VERSION" ) 2>/dev/null \
            || { echo "error: could not back up collab/$f" >&2; exit 1; }
          echo "backed up: collab/$f → collab/$f.pre-$VERSION"
        fi
        proto_write "$f" "$COLLAB/$f" || exit 1
        echo "installed: collab/$f ($VERSION)"
        pairs="$pairs$f=$new"$'\n'
      done ;;
    update)
      for f in $PROTO_GENERIC; do
        new="$(proto_staged "$f" | sha256_stdin)" || exit 1
        rec="$(proto_recorded "$f")"
        if [ ! -e "$COLLAB/$f" ]; then
          proto_write "$f" "$COLLAB/$f" || exit 1; pairs="$pairs$f=$new"$'\n'
          echo "installed: collab/$f ($VERSION)"
          continue
        fi
        cur="$(sha256_of "$COLLAB/$f")" || exit 1
        if [ "$cur" = "$new" ]; then
          pairs="$pairs$f=$new"$'\n'
          echo "up to date: collab/$f"
        elif [ -n "$rec" ] && [ "$cur" = "$rec" ]; then
          proto_write "$f" "$COLLAB/$f" || exit 1; pairs="$pairs$f=$new"$'\n'
          echo "updated: collab/$f → $VERSION"
        else
          # Edited by hand (or never recorded): keep it, and keep its OLD recorded hash so
          # the next re-run still sees it as edited instead of silently overwriting it.
          if [ -n "$rec" ]; then pairs="$pairs$f=$rec"$'\n'; fi
          echo "KEPT: collab/$f was edited by hand — NOT updated to $VERSION." >&2
          echo "      Move the project-specific parts into collab/PROJECT.md, then delete or" >&2
          echo "      restore collab/$f and re-run to receive the new version." >&2
        fi
      done ;;
  esac
  if [ ! -e "$COLLAB/PROJECT.md" ] && [ -n "$R_PROJECT" ]; then
    if ( set -o noclobber; proto_staged PROJECT.md > "$COLLAB/PROJECT.md" ) 2>/dev/null; then
      echo "created: collab/PROJECT.md — this project's own rules go here (never overwritten)"
    fi
  fi
  printf '%s' "$pairs" | proto_write_manifest
}

if [ -e "$COLLAB" ] || [ -L "$COLLAB" ]; then
  # --- migrate ---------------------------------------------------------------
  reject_symlink "$COLLAB" "collab"
  [ -d "$COLLAB" ] || { echo "error: $COLLAB exists but is not a directory" >&2; exit 1; }
  plan_bus_json "$(basename "$DIR")"      # validated BEFORE any script is replaced
  plan_registry "$PEER"                   # …and so is the registry
  plan_protocol "$BUS_PLAN_ALIAS"         # …and so are the protocol files (all rendered)
  vendor_scripts
  pid="$(commit_bus_json)"
  commit_registry                  # §9: migrate creates participants/ and bindings/ when missing
  echo "bus.json: project_id $pid, schemas read=[$BUS_SCHEMAS_READ] write=$BUS_SCHEMAS_WRITE min_reader=$BUS_PLAN_MIN"
  echo "migrated: re-vendored ${#VENDOR[@]} scripts into collab/bin/ at $VERSION (${VENDOR[*]})"
  # The project name for {{PROJECT}} is bus.json's human-owned project_alias, so a
  # re-render keeps the title the project was scaffolded (or renamed) with.
  commit_protocol
  exit 0
fi

# --- fresh scaffold ----------------------------------------------------------
if command -v git >/dev/null 2>&1 && top="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  PROJECT="$(basename "$top")"
else
  PROJECT="$(basename "$DIR")"
fi

# Render all four protocol files before anything is created: a template that cannot be
# rendered then leaves no half-scaffolded collab/ behind (which a re-run would mistake for
# a pre-v0.9 bus).
for _f in $PROTO_GENERIC PROJECT.md; do proto_stage "$_f" "$PROJECT" || exit 1; done

# participants/ and bindings/ exist from the start: a logical endpoint does not need a
# live agent, so bootstrap can pre-declare the pair even before either side is wired.
plan_registry "$PEER"     # nothing below runs if the peer cannot yield a legal id
for d in "inbox/to/$PEER" "inbox/to/claude" "inbox/archive" "reviews" "tasks" \
         "participants" "bindings"; do
  mkdir -p "$COLLAB/$d"
  : > "$COLLAB/$d/.gitkeep"
done
# Defense in depth for the case-folding hazard above: the two inboxes must be two
# distinct directories, whatever the filesystem does with case.
if [ "$COLLAB/inbox/to/$PEER" -ef "$COLLAB/inbox/to/claude" ]; then
  echo "error: inbox/to/$PEER and inbox/to/claude are the same directory on this filesystem — pick another peer name" >&2
  exit 1
fi
plan_bus_json "$PROJECT"
vendor_scripts
pid="$(commit_bus_json)"

# Write the renders staged above; noclobber, since a fresh scaffold never replaces anything.
for _f in $PROTO_GENERIC PROJECT.md; do
  if ! ( set -o noclobber; proto_staged "$_f" > "$COLLAB/$_f" ) 2>/dev/null; then
    echo "error: $COLLAB/$_f already exists — refusing to overwrite" >&2; exit 1
  fi
done
# The manifest lets a later re-run update the collab-bus-owned files without touching a
# hand-edited one.
_pairs=""
for _f in $PROTO_GENERIC; do
  _h="$(sha256_of "$COLLAB/$_f")" || exit 1
  _pairs="$_pairs$_f=$_h"$'\n'
done
printf '%s' "$_pairs" | proto_write_manifest


# Pre-declare the two logical endpoints. `register` is no-replace and idempotent, so this
# never disturbs an existing registry — and scaffolding an endpoint is NOT the same as
# binding it: an agent still has to claim its own id from its own pane.
commit_registry

cat <<EOF
scaffolded collab-bus $VERSION in $DIR
  collab/PROTOCOL.md              the shared contract (Claude Code ⇄ $PEER) — read every round
  collab/PROJECT.md               THIS project's own rules — fill it in; never overwritten
  collab/PROTOCOL-modes.md        rare modes (wait-cycle, fallback) — read when they apply
  collab/DESIGN-DECISIONS.md      why the design is what it is — read before changing it
  collab/bus.json                 machine-readable capabilities; project_id $pid
  collab/bin/                     next-id.sh, publish.sh, knock.sh (both sides call these)
  collab/inbox/to/{claude,$PEER}/ message boxes; collab/inbox/archive/ for processed ones
  collab/participants/            claude-primary and $PEER-primary declared; each agent must
                                  still run: collab/bin/participant.sh bind <its own id>

next:
  1. run both agents as herdr agents in the SAME herdr tab (that tab is the pair).
  2. send the first message: DRAFT=\$(collab/bin/next-id.sh <recipient> <slug> <your-tab-id>)
     → write the body into \$DRAFT → DEST=\$(collab/bin/publish.sh "\$DRAFT")
     → collab/bin/knock.sh <peer-pane-id> "process \$DEST"
  3. either side may initiate; see PROTOCOL.md for pair routing and the async mode.
EOF

#!/usr/bin/env bash
# collab-bus participant registry — logical identity, and the live process holding it.
#
#   participant.sh register <id> --kind <kind> [--alias <text>]
#   participant.sh bind     <id> [--takeover]
#   participant.sh ensure   <id>
#   participant.sh show     [<id>]
#
# THE SPLIT THIS EXISTS FOR (v0.8 contract §3): a participant is a durable, immutable
# endpoint; the process currently holding it is a separate, mutable BINDING. Transport
# coordinates — pane, tab, herdr session — appear only in the binding, never in the
# identity and never in a published message. Deriving an address from a pane or a tab is
# what made `<kind>-<tab>` unusable: move the pane, rename the agent, or restart it, and
# an already-published (immutable) message points at an endpoint nobody can claim.
#
#   collab/participants/<id>.json   identity   — created once, no-replace, never rewritten
#   collab/bindings/<id>.json       binding    — replaced whenever the process or its
#                                                coordinates change
#
# "Which one am I?" is answered by the agent RUNNING `bind <id>`, not by inspecting the
# filesystem. An agent knows its id because its briefing names it; that is deliberate —
# an id that could be guessed from live state would be a locator again.
#
# Exit: 0 ok; 2 bad usage; 1 refused (unknown id, duplicate live claim, corrupt file,
#       herdr unavailable).
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SELF/lib/manifest.sh"          # _mf_file_has_nul, _mf_json_escape, _mf_unescape_alias

COLLAB_ROOT="${COLLAB_ROOT:-collab}"
PART_SCHEMA=1
BIND_SCHEMA=1
# What THIS build can parse. A binding recorded by a newer tool is left alone.
# Bound from the binary, never from inherited environment: a capability an env var can
# raise or lower is not a capability (the step-2 lesson).
PART_READER_SCHEMA=2

_p_err() { echo "participant: $1" >&2; }
_p_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# One control-character gate, used by every path that accepts agent-authored text. The
# previous code called a helper that did not exist and only worked because a `||` fallback
# quietly took over — a check nobody could see failing is not a check.
_p_has_control() { printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; }
# Same gate applied to a FILE, excluding the newlines that separate its lines.
_p_file_has_control() { LC_ALL=C tr -d '\n' < "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; }

# Exact two-path link(2), never `ln SOURCE DIR`: with a directory destination `ln` creates
# a link INSIDE it and reports success. Same wrapper publish.sh uses, for the same reason.
_p_link_noreplace() {
  if command -v link >/dev/null 2>&1; then link "$1" "$2"
  else perl -e 'link($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"; fi
}

# A directory we are about to write into must be a real directory we own, not a symlink
# pointing out of the project.
_p_safe_dir() {
  [ -L "$1" ] && { _p_err "$1 is a symlink — refusing to write through it"; return 1; }
  mkdir -p "$1" || return 1
  [ -d "$1" ] || { _p_err "$1 is not a directory"; return 1; }
  return 0
}

# --- claim serialization ----------------------------------------------------
# The approved contract requires exactly one winner when two processes claim an absent or
# stale binding. An atomic write alone cannot give that: both can pass the liveness check
# and the last rename simply wins. The lock is per project+participant, lives OUTSIDE the
# project (a synced folder resurrects released locks — the v0.4.1 lesson), and is
# explicitly scoped to ONE host: it is not a cross-machine lease.
#
# NOTHING HERE EVER UNLINKS A CONTENDED PATHNAME. Removing a stale lock and re-creating it
# cannot be made safe by checking harder: `[ "$priv" -ef "$lock" ]` followed by
# `rm "$lock"` is two syscalls, so two recoverers could both pass the check, the first
# could remove the ghost, a fresh claimant could then create its own lock, and the second
# recoverer's `rm` would delete THAT — leaving a "holder" nobody is excluded from. POSIX
# has no compare-and-unlink, so instead the contended NAME moves: the lock is a directory
# of generations `g0`, `g1`, … each created once with a no-replace link. A holder that
# dies is never deleted, it is SUPERSEDED — the next claimant creates the next generation.
# The newest generation therefore only moves forward, which turns "this generation is
# older than the newest" into a statement that can never stop being true, and that is what
# finally makes deleting one safe.
CLAIM_LOCK=""        # our own generation file — set only once it is ours
CLAIM_HELD=0
CLAIM_TOKEN=""
CLAIM_STAGE=""
CLAIM_FREE='released'
_P_GEN_DIGITS=15     # a generation we could not increment without overflow is refused

_p_pid_alive() { kill -0 "$1" 2>/dev/null; }
_p_host() { hostname -s 2>/dev/null || echo host; }

# held | released | dead | unknown. Anything we cannot read exactly is `unknown`, which
# makes the caller wait instead of assuming a generation is free — including a token from
# another machine, whose pids mean nothing here.
_p_lock_state() { # <content>
  local c="$1" host pid
  [ "$c" = "$CLAIM_FREE" ] && { printf 'released'; return 0; }
  [[ "$c" =~ ^([A-Za-z0-9_.-]+):([0-9]+):[0-9]+$ ]] || { printf 'unknown'; return 0; }
  host="${BASH_REMATCH[1]}"; pid="${BASH_REMATCH[2]}"
  [ "$host" = "$(_p_host)" ] || { printf 'unknown'; return 0; }
  _p_pid_alive "$pid" && { printf 'held'; return 0; }
  printf 'dead'
}

# A generation NAME IS CANONICAL OR IT IS NOTHING. `_mf_digits_cmp` compares by value, so
# `g02` and `g2` are the same generation under two names — and one of them can hold
# different content. A released `g02` alongside a live `g2` let the scanner report the
# alias, a second session take `g3`, and its collection then delete the generation the
# first session was still inside: two holders, both told they had won. Numbers are only
# a total order while every value has exactly one name, so anything the emitter would not
# have written is refused.
_P_GEN_RE='^(0|[1-9][0-9]*)$'

# The newest generation, or nothing when the directory is empty. A name we did not write
# is refused rather than skipped: a claim directory we cannot read exactly is one we must
# not derive a "next" generation from.
_p_lock_newest() { # <dir>
  local dir="$1" f n best="" r
  for f in "$dir"/g*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ -L "$f" ] && { _p_err "$f is a symlink — refusing"; return 1; }
    n="${f##*/g}"
    [[ "$n" =~ $_P_GEN_RE ]] || { _p_err "$f is not a generation file — refusing"; return 1; }
    # A canonical-looking FIFO would block the `cat` below for as long as nobody wrote to
    # it, which is not a wait the claim timeout can end.
    [ -f "$f" ] || { _p_err "$f is not a regular file — refusing"; return 1; }
    [ "${#n}" -le "$_P_GEN_DIGITS" ] || { _p_err "$f: generation out of range"; return 1; }
    if [ -z "$best" ]; then best="$n"
    else r=0; _mf_digits_cmp "$n" "$best" || r=$?; [ "$r" = 1 ] && best="$n"; fi
  done
  printf '%s' "$best"
  return 0
}

# Only ever called by a process that holds `mine`, and only for generations BELOW it.
# While we hold the newest generation nobody can create a higher one — they would have to
# read ours as free first — so every lower generation is settled history and can never
# become the newest again. That is the property the old recovery `rm` lacked.
_p_lock_gc() { # <dir> <our-generation>
  local dir="$1" mine="$2" f n r
  for f in "$dir"/g*; do
    [ -f "$f" ] || continue
    n="${f##*/g}"
    [[ "$n" =~ $_P_GEN_RE ]] || continue
    r=0; _mf_digits_cmp "$n" "$mine" || r=$?
    [ "$r" = 2 ] && rm -f -- "$f"
  done
  return 0
}

# Release must PROVE the lock is still ours. The first version set CLAIM_LOCK before
# acquiring and let an unconditional EXIT trap `rm -f` it, so interrupting a waiter
# deleted the lock a live holder was still inside — worse than having no lock at all.
_p_lock_release() {
  [ -n "$CLAIM_STAGE" ] && { rm -f -- "$CLAIM_STAGE"; CLAIM_STAGE=""; }
  if [ "$CLAIM_HELD" = 1 ] && [ -n "$CLAIM_LOCK" ]; then
    # Release REPLACES THE CONTENT; it never unlinks. If the newest generation could
    # disappear, the count would go backwards and two claimants could pick the same next
    # generation — each believing it had won a name nobody else could hold.
    if [ "$(cat "$CLAIM_LOCK" 2>/dev/null || true)" = "$CLAIM_TOKEN" ]; then
      local t
      if t="$(mktemp "${CLAIM_LOCK%/*}/.rel.XXXXXX" 2>/dev/null)"; then
        printf '%s\n' "$CLAIM_FREE" > "$t" && mv -f -- "$t" "$CLAIM_LOCK" || rm -f -- "$t"
      fi
    fi
    CLAIM_HELD=0
  fi
  return 0
}

_p_lock_acquire() { # <participant-id>
  local base key dir waited=0 newest seen target after r stalled=0
  base="${COLLAB_LOCK_BASE:-/tmp/collab-bus-$(id -u)}"
  case "$base" in /*) : ;; *) _p_err "COLLAB_LOCK_BASE must be absolute"; return 1 ;; esac
  [ -L "$base" ] && { _p_err "$base is a symlink — refusing"; return 1; }
  mkdir -p "$base" 2>/dev/null || true
  key="$(printf '%s\0%s' "$(cd "$COLLAB_ROOT" && pwd -P)" "$1" | cksum | tr -d ' \n')"
  dir="$base/claim-$key.d"
  [ -L "$dir" ] && { _p_err "$dir is a symlink — refusing"; return 1; }
  mkdir -p "$dir" 2>/dev/null || true
  [ -d "$dir" ] || { _p_err "could not create the claim directory $dir"; return 1; }
  CLAIM_TOKEN="$(_p_host):$$:${RANDOM}${RANDOM}"
  CLAIM_STAGE="$(mktemp "$base/.claim.XXXXXX")" || { _p_err "could not stage a lock"; return 1; }
  printf '%s\n' "$CLAIM_TOKEN" > "$CLAIM_STAGE"
  while :; do
    newest="$(_p_lock_newest "$dir")" || { rm -f -- "$CLAIM_STAGE"; CLAIM_STAGE=""; return 1; }
    target=""
    if [ -z "$newest" ]; then
      target=0
    else
      seen="$(cat "$dir/g$newest" 2>/dev/null || true)"
      case "$(_p_lock_state "$seen")" in
        released|dead) target=$((newest+1)) ;;
        *) : ;;                       # held, or unreadable — look again in a moment
      esac
    fi
    # A delay the tests use to reach the one interleaving they otherwise cannot: a
    # claimant that read `newest`, then gets superseded twice — so the generation it is
    # about to create has been garbage-collected by a HIGHER holder and its create will
    # succeed. The hook only ever SLEEPS, and only once. It cannot change a decision,
    # which is what stops a test hook from becoming a capability an environment grants.
    if [ -n "$target" ] && [ "$stalled" = 0 ] && [[ "${COLLAB_LOCK_TEST_STALL:-}" =~ ^[0-9]+$ ]]; then
      stalled=1; sleep "$COLLAB_LOCK_TEST_STALL"
    fi
    if [ -n "$target" ] && _p_link_noreplace "$CLAIM_STAGE" "$dir/g$target" 2>/dev/null; then
      # We created it — but our reading of "newest" could have been stale, and a claimant
      # that superseded us in the meantime may already hold a HIGHER generation. Removing
      # our own file then is safe (it is already older than the newest) and we look again.
      if ! after="$(_p_lock_newest "$dir")"; then
        rm -f -- "$dir/g$target" "$CLAIM_STAGE"; CLAIM_STAGE=""; return 1
      fi
      r=0
      [ -n "$after" ] && { _mf_digits_cmp "$after" "$target" || r=$?; }
      if [ "$r" = 1 ]; then
        rm -f -- "$dir/g$target"
      else
        CLAIM_LOCK="$dir/g$target"; CLAIM_HELD=1
        rm -f -- "$CLAIM_STAGE"; CLAIM_STAGE=""
        _p_lock_gc "$dir" "$target"
        return 0
      fi
    fi
    waited=$((waited+1))
    if [ "$waited" -gt 100 ]; then   # ~10s; a claim is a short critical section
      _p_err "timed out waiting for the claim lock on '$1' (holder: ${seen:-unknown})"
      rm -f -- "$CLAIM_STAGE"; CLAIM_STAGE=""
      return 1
    fi
    sleep 0.1
  done
}

# --- canonical shapes -------------------------------------------------------
# Whole-file grammars, for the reason bus.json needed one: a per-key search accepts a
# valid-looking field inside a corrupt file and the next write launders the damage.
_P_ID_RE='^[a-z0-9][a-z0-9._-]{0,63}$'
_PL1='^[[:space:]]*\{[[:space:]]*$'
_PL2='^[[:space:]]*"participant_schema"[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*$'
_PL3='^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"([a-z0-9][a-z0-9._-]*)"[[:space:]]*,[[:space:]]*$'
_PL4='^[[:space:]]*"kind"[[:space:]]*:[[:space:]]*"([a-z0-9][a-z0-9._-]*)"[[:space:]]*,[[:space:]]*$'
_PL5='^[[:space:]]*"alias"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"[[:space:]]*,[[:space:]]*$'
# RFC 3339 UTC to the second. The old [0-9T:Z-]+ accepted "---".
_P_TS='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
_PL6='^[[:space:]]*"created"[[:space:]]*:[[:space:]]*"('"$_P_TS"')"[[:space:]]*$'
_PL7='^[[:space:]]*\}[[:space:]]*$'

_BL2='^[[:space:]]*"binding_schema"[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*$'
_BL3='^[[:space:]]*"participant"[[:space:]]*:[[:space:]]*"([a-z0-9][a-z0-9._-]*)"[[:space:]]*,[[:space:]]*$'
_BL4='^[[:space:]]*"pane_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9:_-]+)"[[:space:]]*,[[:space:]]*$'
_BL5='^[[:space:]]*"tab_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9:_-]+)"[[:space:]]*,[[:space:]]*$'
_BL6='^[[:space:]]*"agent_session"[[:space:]]*:[[:space:]]*"([A-Za-z0-9:_.-]+)"[[:space:]]*,[[:space:]]*$'
_BL7='^[[:space:]]*"reader_schema"[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*$'
_BL_CLAIM='^[[:space:]]*"claim_mode"[[:space:]]*:[[:space:]]*"(bind|ensure|takeover)"[[:space:]]*,[[:space:]]*$'
_BL_FROM='^[[:space:]]*"claimed_from"[[:space:]]*:[[:space:]]*"([A-Za-z0-9:_.-]*)"[[:space:]]*,[[:space:]]*$'
_BL8='^[[:space:]]*"bound_at"[[:space:]]*:[[:space:]]*"('"$_P_TS"')"[[:space:]]*$'

P_ID=""; P_KIND=""; P_ALIAS=""; P_CREATED=""
B_PANE=""; B_TAB=""; B_SESSION=""; B_READER=""; B_AT=""; B_CLAIM=""; B_FROM=""

_p_read_lines() {  # <file> -> sets _P_LINES / _P_N
  local f="$1" l
  [ -r "$f" ] || { _p_err "cannot read $f"; return 1; }
  _mf_file_has_nul "$f" && { _p_err "$f: contains a NUL byte — refusing"; return 1; }
  _P_LINES=(); _P_N=0
  while IFS= read -r l || [ -n "$l" ]; do
    [ -n "${l//[[:space:]]/}" ] || continue
    _P_LINES[$_P_N]="$l"; _P_N=$((_P_N+1))
  done < "$f"
  return 0
}

# participant_load <id> [expected-kind] — THE single entry point every caller must use.
# Reading an identity is not enough: the file's own id, the id the caller asked for, and
# the filename are three records of one fact, and a caller that skips the comparison (as
# register-existing, show and bootstrap all did) will happily act on a mismatched file.
participant_load() {
  # Split: in one `local` statement every word is expanded BEFORE the assignments happen,
  # so "$PDIR/$id.json" would read an $id that does not exist yet (and trip set -u).
  local id="$1" want="${2:-}"
  # Validate the requested id BEFORE it becomes part of a path, refuse a symlinked parent
  # (checking only the leaf let a symlinked participants/ serve a foreign identity), and
  # hold the decoded content to the same grammar the CLI enforces on input.
  [[ "$id" =~ $_P_ID_RE ]] || { _p_err "'$id' is not a valid participant id"; return 1; }
  [ -L "$PDIR" ] && { _p_err "$PDIR is a symlink — refusing"; return 1; }
  [ -d "$PDIR" ] || { _p_err "$PDIR is not a directory"; return 1; }
  local f="$PDIR/$id.json"
  [ -L "$f" ] && { _p_err "$f is a symlink — refusing"; return 1; }
  [ -f "$f" ] || { _p_err "$id is not registered"; return 1; }
  participant_read "$f" || return $?
  [ "$P_ID" = "$id" ] || { _p_err "$f declares id '$P_ID' — it must match its filename"; return 1; }
  [[ "$P_ID" =~ $_P_ID_RE ]] || { _p_err "$f: id '$P_ID' violates the id grammar"; return 1; }
  [[ "$P_KIND" =~ $_P_ID_RE ]] || { _p_err "$f: kind '$P_KIND' violates the id grammar"; return 1; }
  if [ -n "$want" ] && [ "$P_KIND" != "$want" ]; then
    _p_err "$id is registered as kind '$P_KIND', not '$want'"; return 1
  fi
  return 0
}

participant_read() { # <file>
  _p_read_lines "$1" || return 1
  # Control bytes must be refused by the READER too: register only ever checked its own
  # input, so a raw TAB hand-written into an existing alias sailed through every later
  # read. (LF is structural and already consumed by the line reader.)
  _p_file_has_control "$1" && { _p_err "$1: contains a control character"; return 1; }
  [ "$_P_N" -eq 7 ] || { _p_err "$1: expected a 7-line identity object, found $_P_N"; return 1; }
  [[ "${_P_LINES[0]}" =~ $_PL1 ]] || { _p_err "$1: not a JSON object"; return 1; }
  [[ "${_P_LINES[1]}" =~ $_PL2 ]] || { _p_err "$1: bad participant_schema"; return 1; }
  [ "${BASH_REMATCH[1]}" = "$PART_SCHEMA" ] || { _p_err "$1: participant_schema ${BASH_REMATCH[1]} is not supported"; return 1; }
  [[ "${_P_LINES[2]}" =~ $_PL3 ]] || { _p_err "$1: bad id"; return 1; }; P_ID="${BASH_REMATCH[1]}"
  [[ "${_P_LINES[3]}" =~ $_PL4 ]] || { _p_err "$1: bad kind"; return 1; }; P_KIND="${BASH_REMATCH[1]}"
  [[ "${_P_LINES[4]}" =~ $_PL5 ]] || { _p_err "$1: bad alias"; return 1; }
  P_ALIAS="$(_mf_unescape_alias "${BASH_REMATCH[1]}")" || return 1
  [[ "${_P_LINES[5]}" =~ $_PL6 ]] || { _p_err "$1: bad created"; return 1; }; P_CREATED="${BASH_REMATCH[1]}"
  [[ "${_P_LINES[6]}" =~ $_PL7 ]] || { _p_err "$1: does not close"; return 1; }
  return 0
}

binding_read() { # <file>
  _p_read_lines "$1" || return 1
  [ "$_P_N" -eq 11 ] || { _p_err "$1: expected an 11-line binding object, found $_P_N"; return 1; }
  [[ "${_P_LINES[0]}" =~ $_PL1 ]] || { _p_err "$1: not a JSON object"; return 1; }
  [[ "${_P_LINES[1]}" =~ $_BL2 ]] || { _p_err "$1: bad binding_schema"; return 1; }
  [ "${BASH_REMATCH[1]}" = "$BIND_SCHEMA" ] || { _p_err "$1: binding_schema ${BASH_REMATCH[1]} is not supported"; return 1; }
  [[ "${_P_LINES[2]}" =~ $_BL3 ]] || { _p_err "$1: bad participant"; return 1; }; P_ID="${BASH_REMATCH[1]}"
  [[ "${_P_LINES[3]}" =~ $_BL4 ]] || { _p_err "$1: bad pane_id"; return 1; }; B_PANE="${BASH_REMATCH[1]}"
  [[ "${_P_LINES[4]}" =~ $_BL5 ]] || { _p_err "$1: bad tab_id"; return 1; }; B_TAB="${BASH_REMATCH[1]}"
  [[ "${_P_LINES[5]}" =~ $_BL6 ]] || { _p_err "$1: bad agent_session"; return 1; }; B_SESSION="${BASH_REMATCH[1]}"
  [[ "${_P_LINES[6]}" =~ $_BL7 ]] || { _p_err "$1: bad reader_schema"; return 1; }; B_READER="${BASH_REMATCH[1]}"
  [[ "${_P_LINES[7]}" =~ $_BL_CLAIM ]] || { _p_err "$1: bad claim_mode"; return 1; }; B_CLAIM="${BASH_REMATCH[1]}"
  [[ "${_P_LINES[8]}" =~ $_BL_FROM ]] || { _p_err "$1: bad claimed_from"; return 1; }; B_FROM="${BASH_REMATCH[1]}"
  [[ "${_P_LINES[9]}" =~ $_BL8 ]] || { _p_err "$1: bad bound_at"; return 1; }; B_AT="${BASH_REMATCH[1]}"
  [[ "${_P_LINES[10]}" =~ $_PL7 ]] || { _p_err "$1: does not close"; return 1; }
  # A binding recorded by newer tooling must not be canonicalized backwards.
  # Digit-string compare, not shell arithmetic: past the 64-bit range `-gt` prints an
  # error and returns false, so a huge reader_schema compared as NOT newer and the binding
  # was canonicalized backwards. Same comparator step 2 already had to adopt.
  local _rc=0; _mf_digits_cmp "$B_READER" "$PART_READER_SCHEMA" || _rc=$?
  if [ "$_rc" = 1 ]; then
    _p_err "$1: reader_schema $B_READER is newer than this build ($PART_READER_SCHEMA) — refusing to rewrite it"
    return 3
  fi
  return 0
}

# --- live coordinates -------------------------------------------------------
# Resolved fresh every time from herdr, never remembered. Tests replace herdr on PATH.
LIVE_PANE=""; LIVE_TAB=""; LIVE_SESSION=""
resolve_live() {
  command -v herdr >/dev/null 2>&1 || { _p_err "herdr not found — cannot resolve this process's coordinates"; return 1; }
  local out
  out="$(herdr pane current 2>/dev/null)" || { _p_err "herdr pane current failed — are we inside a herdr pane?"; return 1; }
  LIVE_PANE="$(printf '%s' "$out" | sed -n 's/.*"pane_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  LIVE_TAB="$(printf '%s' "$out" | sed -n 's/.*"tab_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  LIVE_SESSION="$(printf '%s' "$out" | sed -n 's/.*"agent_session"[^}]*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$LIVE_PANE" ] && [ -n "$LIVE_TAB" ] \
    || { _p_err "could not read pane_id/tab_id from herdr"; return 1; }
  # Without our own session id there is no way to tell "this binding is mine" from
  # "somebody else holds it", so duplicate-claim protection would silently do nothing.
  [ -n "$LIVE_SESSION" ] \
    || { _p_err "herdr did not report an agent_session for this pane — refusing to bind"; return 1; }
  # The values must be representable by the binding codec BEFORE we take the lock and
  # overwrite anything: the old order wrote the new binding first and only discovered a
  # bad pane_id in the post-read, having already destroyed the previous valid one.
  [[ "$LIVE_PANE" =~ ^[A-Za-z0-9:_-]+$ ]] \
    || { _p_err "herdr reported a pane_id this codec cannot store: '$LIVE_PANE'"; return 1; }
  [[ "$LIVE_TAB" =~ ^[A-Za-z0-9:_-]+$ ]] \
    || { _p_err "herdr reported a tab_id this codec cannot store: '$LIVE_TAB'"; return 1; }
  [[ "$LIVE_SESSION" =~ ^[A-Za-z0-9:_.-]+$ ]] \
    || { _p_err "herdr reported an agent_session this codec cannot store: '$LIVE_SESSION'"; return 1; }
  return 0
}

# session_liveness <session> — prints live | absent | unknown.
# THREE states, not two: folding "the list says it is gone" together with "the list could
# not be read" makes a herdr restart look exactly like a finished agent, and the caller
# would then steal a live binding without anyone asking for a takeover. Only a successful,
# parseable list that does NOT contain the session means absent.
session_liveness() {
  local out parsed=""
  [ -n "$1" ] || { printf 'unknown'; return 0; }
  command -v herdr >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  out="$(herdr agent list 2>/dev/null)" || { printf 'unknown'; return 0; }

  # A REAL PARSER OR NOTHING. There is no dependency-free shortcut here: the previous
  # fallback counted `[` and `]` without knowing whether it was inside a JSON string, so
  # a live agent listed as `{"note":"]","agent_session":{"value":"sess-A"}}` ended the
  # array early, the session went unseen, and `bind` silently stole a live binding with
  # no --takeover. A heuristic that can read `live` as `absent` is worse than no answer,
  # because `absent` is the one verdict that authorises taking someone else's claim.
  # Writing a string- and escape-aware tokeniser in shell to avoid depending on a JSON
  # parser we already have would be trading a real risk for a cosmetic one.
  #
  # A parser that is present but cannot RUN (a broken interpreter, a stub) is not a
  # verdict — we go on to the next one. A parser that runs and reports MALFORMED is a
  # verdict, and that verdict is `unknown`.
  #
  # "Did it run" is the EXIT STATUS, never "did it print something". A broken interpreter
  # that emitted a partial `OK` and then died was read as a complete answer with no
  # sessions in it — `absent` — and silently took a live binding. Our own parsers report
  # a malformed list as rc=0 plus `MALFORMED`, precisely so that a verdict and a crash
  # cannot arrive looking the same.
  local p rc
  for p in python3 ruby; do
    command -v "$p" >/dev/null 2>&1 || continue
    rc=0
    case "$p" in
      python3) parsed="$(printf '%s' "$out" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("MALFORMED"); raise SystemExit
a = (d.get("result") or {}).get("agents")
if not isinstance(a, list): print("MALFORMED"); raise SystemExit
print("OK")
for e in a:
    if isinstance(e, dict):
        s = (e.get("agent_session") or {})
        if isinstance(s, dict) and isinstance(s.get("value"), str): print(s["value"])
' 2>/dev/null)" || rc=$? ;;
      ruby)    parsed="$(printf '%s' "$out" | ruby -rjson -e '
begin; d = JSON.parse(STDIN.read); rescue; puts "MALFORMED"; exit; end
a = (d["result"] || {})["agents"]
unless a.is_a?(Array); puts "MALFORMED"; exit; end
puts "OK"
a.each { |e| v = (e.is_a?(Hash) && e["agent_session"].is_a?(Hash)) ? e["agent_session"]["value"] : nil; puts v if v.is_a?(String) }
' 2>/dev/null)" || rc=$? ;;
    esac
    [ "$rc" = 0 ] || { parsed=""; continue; }   # it did not finish: not a verdict
    [ -n "$parsed" ] && break                   # it ran; whatever it says is the answer
  done

  case "$parsed" in
    OK*) if printf '%s' "$parsed" | tail -n +2 | grep -Fxq -- "$1"; then printf 'live'; else printf 'absent'; fi ;;
    *)   printf 'unknown' ;;          # malformed, or no parser we could run
  esac
  return 0
}

# --- writers ----------------------------------------------------------------
# The staging path is never interpolated into a trap: a project directory whose name
# closes a quote would otherwise execute shell (the bus.json lesson).
P_TMP=""
_p_cleanup() {
  [ -n "$P_TMP" ] && rm -f -- "$P_TMP"
  _p_lock_release          # ownership-checked; never removes somebody else's lock
  return 0
}
# A signal trap that only cleans up and RETURNS lets the script carry on: the handler
# released the lock and the interrupted critical section then went on to write the binding
# anyway, so another claimant could be inside it at the same time. Each signal must end
# the process with its own status; EXIT cleanup stays idempotent.
_p_on_signal() { local n="$1"; _p_cleanup; trap - EXIT; exit $((128 + n)); }
trap '_p_on_signal 2'  INT
trap '_p_on_signal 15' TERM
trap '_p_on_signal 1'  HUP
trap _p_cleanup EXIT

_p_stage() { P_TMP="$(mktemp "$1/.stage.XXXXXX")" || { _p_err "could not stage in $1"; exit 1; }; }

render_participant() { # <id> <kind> <alias> <created>
  printf '{\n  "participant_schema": %s,\n  "id": "%s",\n  "kind": "%s",\n  "alias": "%s",\n  "created": "%s"\n}\n' \
    "$PART_SCHEMA" "$1" "$2" "$(_mf_json_escape "$3")" "$4"
}
render_binding() { # <id> <pane> <tab> <session> <reader> <claim_mode> <claimed_from> <at>
  printf '{\n  "binding_schema": %s,\n  "participant": "%s",\n  "pane_id": "%s",\n  "tab_id": "%s",\n  "agent_session": "%s",\n  "reader_schema": %s,\n  "claim_mode": "%s",\n  "claimed_from": "%s",\n  "bound_at": "%s"\n}\n' \
    "$BIND_SCHEMA" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# --- subcommands ------------------------------------------------------------
usage() {
  echo "usage: participant.sh register <id> --kind <kind> [--alias <text>]" >&2
  echo "       participant.sh bind <id> [--takeover]" >&2
  echo "       participant.sh ensure <id>" >&2
  echo "       participant.sh validate <id> [--kind <kind>]   (read-only)" >&2
  echo "       participant.sh get <id> <field>                (read-only)" >&2
  echo "       participant.sh snapshot <id>                  (read-only, tab-separated:" >&2
  echo "                    reader_schema  liveness  pane_id  tab_id  agent_session)" >&2
  echo "       participant.sh whoami                          (read-only)" >&2
  echo "       participant.sh show [<id>]" >&2
}

[ "$#" -ge 1 ] || { usage; exit 2; }
CMD="$1"; shift

[ -d "$COLLAB_ROOT" ] || { _p_err "$COLLAB_ROOT not found — run bootstrap.sh first"; exit 1; }
PDIR="$COLLAB_ROOT/participants"; BDIR="$COLLAB_ROOT/bindings"

case "$CMD" in
  register)
    ID="${1:-}"; shift || true
    KIND=""; ALIAS=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind)  [ $# -ge 2 ] || { _p_err "--kind needs a value"; exit 2; }; KIND="$2"; shift 2 ;;
        --alias) [ $# -ge 2 ] || { _p_err "--alias needs a value"; exit 2; }; ALIAS="$2"; shift 2 ;;
        *) _p_err "unexpected argument '$1'"; usage; exit 2 ;;
      esac
    done
    [[ "$ID" =~ $_P_ID_RE ]] || { _p_err "id '$ID' must match [a-z0-9][a-z0-9._-]* (max 64)"; exit 2; }
    [[ "$KIND" =~ $_P_ID_RE ]] || { _p_err "--kind is required and must match [a-z0-9][a-z0-9._-]*"; exit 2; }
    ALIAS="${ALIAS:-$ID}"
    _p_has_control "$ALIAS" && { _p_err "alias contains a control character"; exit 2; }
    _p_safe_dir "$PDIR" || exit 1
    DEST="$PDIR/$ID.json"
    [ -L "$DEST" ] && { _p_err "$DEST is a symlink — refusing"; exit 1; }
    _p_stage "$PDIR"
    render_participant "$ID" "$KIND" "$ALIAS" "$(_p_now)" > "$P_TMP"
    # No-replace: two registrations racing on the same id must not both "succeed" with
    # the last write winning — an identity is minted once.
    if _p_link_noreplace "$P_TMP" "$DEST" 2>/dev/null; then
      # Post-verify: the destination must be the staged inode's regular-file twin. A link
      # variant that mis-placed it would otherwise report a success that did not happen.
      if [ ! -f "$DEST" ] || [ ! "$DEST" -ef "$P_TMP" ]; then
        _p_err "post-create check failed for $DEST"; exit 1
      fi
      rm -f -- "$P_TMP"; P_TMP=""
      participant_read "$DEST" >/dev/null || { _p_err "wrote $DEST but it does not validate"; exit 1; }
      [ "$P_ID" = "$ID" ] || { _p_err "$DEST holds id '$P_ID', not '$ID'"; exit 1; }
      echo "registered $ID (kind $KIND)"
    else
      rm -f -- "$P_TMP"; P_TMP=""
      participant_load "$ID" "$KIND" \
        || { _p_err "$ID already exists and does not match this request — identities are immutable"; exit 1; }
      # Idempotent only on a FULL semantic match: an identity is immutable, so a different
      # alias is a conflicting request, not something to silently ignore.
      if [ "$P_ALIAS" != "$ALIAS" ]; then
        _p_err "$ID already exists with alias '$P_ALIAS'; refusing to imply '$ALIAS' was applied"; exit 1
      fi
      echo "already registered: $ID (kind $P_KIND)"
    fi
    ;;

  bind|ensure)
    ID="${1:-}"; shift || true
    TAKEOVER=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --takeover)
          [ "$CMD" = bind ] || { _p_err "--takeover is only valid for bind"; exit 2; }
          TAKEOVER=1; shift ;;
        *) _p_err "unexpected argument '$1'"; usage; exit 2 ;;
      esac
    done
    [[ "$ID" =~ $_P_ID_RE ]] || { _p_err "id '$ID' is not a participant id"; exit 2; }
    participant_load "$ID" || exit 1

    resolve_live || exit 1
    _p_safe_dir "$BDIR" || exit 1
    BF="$BDIR/$ID.json"

    # Everything from here to the write is one critical section: without it two processes
    # can both observe an absent/stale binding, both pass the liveness check, and both be
    # told they hold the identity while the last write silently wins.
    _p_lock_acquire "$ID" || exit 1

    CLAIM_MODE="$CMD"; CLAIMED_FROM=""
    if [ -e "$BF" ] || [ -L "$BF" ]; then
      [ -L "$BF" ] && { _p_err "$BF is a symlink — refusing"; _p_lock_release; exit 1; }
      binding_read "$BF" >/dev/null || { _p_lock_release; exit 1; }
      [ "$P_ID" = "$ID" ] || { _p_err "$BF names participant '$P_ID', not '$ID'"; _p_lock_release; exit 1; }
      if [ "$B_SESSION" != "$LIVE_SESSION" ]; then
        LIVENESS="$(session_liveness "$B_SESSION")"
        case "$LIVENESS" in
          live)
            if [ "$TAKEOVER" -eq 1 ]; then
              CLAIM_MODE=takeover; CLAIMED_FROM="$B_SESSION"
              echo "taking over $ID from live session $B_SESSION" >&2
            else
              _p_err "$ID is held by a LIVE session ($B_SESSION) in pane $B_PANE"
              _p_err "pass --takeover only if you are certain that process is finished with it"
              _p_lock_release; exit 1
            fi ;;
          unknown)
            # herdr could not answer. A restarting server looks exactly like a finished
            # agent here, so treating it as stale would steal a live binding in silence.
            if [ "$TAKEOVER" -eq 1 ]; then
              CLAIM_MODE=takeover; CLAIMED_FROM="$B_SESSION"
              echo "liveness of $B_SESSION is UNKNOWN; taking over because --takeover was given" >&2
            else
              _p_err "cannot determine whether session $B_SESSION is still live (herdr did not answer)"
              _p_err "refusing rather than assuming it is gone; retry, or pass --takeover deliberately"
              _p_lock_release; exit 1
            fi ;;
          absent) : ;;   # confirmed gone: re-bind freely
        esac
      else
        # Same session refreshing its own coordinates: keep the audit trail of how this
        # identity was claimed rather than washing it away on the next pane move.
        CLAIM_MODE="$B_CLAIM"; CLAIMED_FROM="$B_FROM"
      fi
      if [ "$CMD" = ensure ] \
         && [ "$B_SESSION" = "$LIVE_SESSION" ] && [ "$B_PANE" = "$LIVE_PANE" ] \
         && [ "$B_TAB" = "$LIVE_TAB" ] && [ "$B_READER" = "$PART_READER_SCHEMA" ]; then
        echo "$ID: binding already current ($LIVE_PANE)"      # no write at all
        _p_lock_release; exit 0
      fi
    fi

    _p_stage "$BDIR"
    render_binding "$ID" "$LIVE_PANE" "$LIVE_TAB" "$LIVE_SESSION" "$PART_READER_SCHEMA" \
                   "$CLAIM_MODE" "$CLAIMED_FROM" "$(_p_now)" > "$P_TMP"
    # Validate the STAGED file, then swap. Writing first and checking afterwards leaves a
    # corrupt binding in place of a previously valid one when the check fails.
    binding_read "$P_TMP" >/dev/null \
      || { _p_err "refusing to install a binding that does not validate"; _p_lock_release; exit 1; }
    mv -f -- "$P_TMP" "$BF"; P_TMP=""
    _p_lock_release
    echo "$CMD: $ID -> $LIVE_PANE (tab $LIVE_TAB, session $LIVE_SESSION, claim $CLAIM_MODE)"
    ;;

  validate)
    # Read-only by construction: bootstrap's preflight must not stage or link anything,
    # and it owns only the id/kind expectation — never the alias, which belongs to the
    # immutable identity somebody already created.
    ID="${1:-}"; shift || true
    WANT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind) [ $# -ge 2 ] || { _p_err "--kind needs a value"; exit 2; }; WANT="$2"; shift 2 ;;
        *) _p_err "unexpected argument '$1'"; usage; exit 2 ;;
      esac
    done
    participant_load "$ID" "$WANT" >/dev/null || exit 1
    ;;

  get)
    # A machine-readable accessor, so a consumer never has to scrape `show`. Everything
    # printed here has been through the whole-file codec first: the step-2 rule that a
    # per-key search launders corruption applies to READERS just as much as to writers,
    # and routing is about to become a reader.
    ID="${1:-}"; FIELD="${2:-}"; shift 2 2>/dev/null || true
    [ "$#" -eq 0 ] || { _p_err "get takes exactly two arguments"; usage; exit 2; }
    { [ -n "$ID" ] && [ -n "$FIELD" ]; } || { _p_err "get needs <id> and <field>"; usage; exit 2; }
    participant_load "$ID" >/dev/null || exit 1
    case "$FIELD" in
      kind)    printf '%s\n' "$P_KIND" ;;
      alias)   printf '%s\n' "$P_ALIAS" ;;
      created) printf '%s\n' "$P_CREATED" ;;
      pane_id|tab_id|agent_session|reader_schema|claim_mode|claimed_from|bound_at|live)
        [ -L "$BDIR" ] && { _p_err "$BDIR is a symlink — refusing"; exit 1; }
        BF="$BDIR/$ID.json"
        [ -L "$BF" ] && { _p_err "$BF is a symlink — refusing"; exit 1; }
        [ -f "$BF" ] || { _p_err "$ID has no binding — run: participant.sh bind $ID"; exit 1; }
        # rc 3 ("recorded by newer tooling") is passed through rather than flattened: a
        # caller that must not act on a binding it cannot fully read needs to tell that
        # apart from a corrupt file.
        r=0; binding_read "$BF" >/dev/null || r=$?
        [ "$r" = 0 ] || exit "$r"
        [ "$P_ID" = "$ID" ] || { _p_err "$BF binds '$P_ID', not '$ID'"; exit 1; }
        case "$FIELD" in
          pane_id)       printf '%s\n' "$B_PANE" ;;
          tab_id)        printf '%s\n' "$B_TAB" ;;
          agent_session) printf '%s\n' "$B_SESSION" ;;
          reader_schema) printf '%s\n' "$B_READER" ;;
          claim_mode)    printf '%s\n' "$B_CLAIM" ;;
          claimed_from)  printf '%s\n' "$B_FROM" ;;
          bound_at)      printf '%s\n' "$B_AT" ;;
          # THREE states. A binding file is the record of the last claim, not proof that
          # the process is still there, and callers that treat "a file exists" as "a live
          # reader" (capability did) end up licensing decisions on a session that ended.
          live)          printf '%s\n' "$(session_liveness "$B_SESSION")" ;;
        esac ;;
      *) _p_err "unknown field '$FIELD'"; exit 2 ;;
    esac
    ;;

  snapshot)
    # ONE decode, one answer, for EVERY fact a caller might otherwise splice. Two `get`
    # calls are two processes that each re-read a mutable binding, so a rebind between
    # them joins one holder's liveness to another holder's schema — or to another
    # holder's pane, which is the same bug wearing transport clothes. Liveness here is
    # asked about the session THIS decode saw, so if that holder has since been replaced
    # the honest answer is that it is gone.
    #
    # OUTPUT CONTRACT — one line, tab-separated, fixed order, appended to only at the end:
    #   reader_schema  liveness  pane_id  tab_id  agent_session
    ID="${1:-}"; shift || true
    [ "$#" -eq 0 ] || { _p_err "snapshot takes exactly one argument"; usage; exit 2; }
    [ -n "$ID" ] || { _p_err "snapshot needs <id>"; usage; exit 2; }
    participant_load "$ID" >/dev/null || exit 1
    [ -L "$BDIR" ] && { _p_err "$BDIR is a symlink — refusing"; exit 1; }
    BF="$BDIR/$ID.json"
    [ -L "$BF" ] && { _p_err "$BF is a symlink — refusing"; exit 1; }
    [ -f "$BF" ] || { _p_err "$ID has no binding — run: participant.sh bind $ID"; exit 1; }
    r=0; binding_read "$BF" >/dev/null || r=$?
    [ "$r" = 0 ] || exit "$r"
    [ "$P_ID" = "$ID" ] || { _p_err "$BF binds '$P_ID', not '$ID'"; exit 1; }
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$B_READER" "$(session_liveness "$B_SESSION")" "$B_PANE" "$B_TAB" "$B_SESSION"
    ;;

  whoami)
    # The INVERSE lookup, and the distinction matters. Deriving an ADDRESS from live state
    # is what made `<kind>-<tab>` a locator; asking "which identity did I already claim?"
    # reads a binding somebody deliberately created, and the live session is only the key.
    resolve_live || exit 1
    [ -L "$BDIR" ] && { _p_err "$BDIR is a symlink — refusing"; exit 1; }
    [ -d "$BDIR" ] || { _p_err "no bindings yet — run: participant.sh bind <id>"; exit 1; }
    hits=""; n=0; broken=0
    for f in "$BDIR"/*.json; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      # Same artifact gate `get` and `show` apply. A symlinked or non-regular binding is
      # not a binding that is merely absent: reading through one lets a file outside the
      # project answer "which identity am I?".
      [ -L "$f" ] && { _p_err "$f is a symlink — refusing"; broken=1; continue; }
      [ -f "$f" ] || { _p_err "$f is not a regular file — refusing"; broken=1; continue; }
      # A binding we cannot read is NOT a binding that is not ours. Skipping it quietly
      # would answer "nobody" for a session whose own record is the corrupt one.
      r=0; binding_read "$f" >/dev/null || r=$?
      [ "$r" = 0 ] || { broken=1; continue; }
      base="$(basename "$f")"; base="${base%.json}"
      [ "$P_ID" = "$base" ] || { broken=1; continue; }
      # An orphan binding — no identity behind it — cannot be the answer either: the
      # identity is the durable half, and a claim on something unregistered is not one.
      # `[ -f ]` was not that check: it follows a symlink and reads nothing, so a symlinked
      # or corrupt identity still counted as "an identity is behind this". The invariant
      # lives in participant_load (id vs filename vs content, kind, parent symlink), and
      # every reader has to go through it or it is not an invariant.
      participant_load "$base" >/dev/null || { broken=1; continue; }
      [ "$B_SESSION" = "$LIVE_SESSION" ] || continue
      hits="$hits $base"; n=$((n+1))
    done
    [ "$broken" = 0 ] || { _p_err "one or more bindings are unreadable — refusing to guess which identity is mine"; exit 1; }
    case "$n" in
      1) printf '%s\n' "${hits# }" ;;
      0) _p_err "no participant is bound to this session ($LIVE_SESSION) — run: participant.sh bind <id>"; exit 1 ;;
      *) _p_err "session $LIVE_SESSION holds more than one participant:${hits}"
         _p_err "that is a duplicate claim, not something to pick a winner from"; exit 1 ;;
    esac
    ;;

  show)
    ID="${1:-}"
    if [ -n "$ID" ]; then
      participant_load "$ID" || exit 1
      printf '%s  kind=%s  alias=%s  created=%s\n' "$P_ID" "$P_KIND" "$P_ALIAS" "$P_CREATED"
      [ -L "$BDIR" ] && { _p_err "$BDIR is a symlink — refusing"; exit 1; }
      if [ -L "$BDIR/$ID.json" ]; then
        _p_err "$BDIR/$ID.json is a symlink"; exit 1
      elif [ -f "$BDIR/$ID.json" ]; then
        # "unreadable" and "absent" are different answers; collapsing them hid corruption
        # behind a cheerful "(none)".
        binding_read "$BDIR/$ID.json" >/dev/null || { _p_err "$ID has a binding that does not validate"; exit 1; }
        local_live="$(session_liveness "$B_SESSION")"
        printf '  bound: pane=%s tab=%s session=%s reader_schema=%s live=%s\n' \
          "$B_PANE" "$B_TAB" "$B_SESSION" "$B_READER" "$local_live"
      else
        printf '  bound: (none)\n'
      fi
    else
      [ -d "$PDIR" ] || { echo "(no participants registered)"; exit 0; }
      found=0; broken=0
      for f in "$PDIR"/*.json; do
        [ -e "$f" ] || continue
        found=1
        # Keep listing the rest, but a partial registry must not look healthy to
        # automation, so the command still exits nonzero.
        base="$(basename "$f")"; base="${base%.json}"
        participant_load "$base" >/dev/null || { broken=1; continue; }
        printf '%s  kind=%s\n' "$P_ID" "$P_KIND"
      done
      [ "$found" = 1 ] || echo "(no participants registered)"
      [ "$broken" = 0 ] || { _p_err "one or more identity files are unreadable"; exit 1; }
    fi
    ;;

  -h|--help) usage; exit 0 ;;
  *) _p_err "unknown subcommand '$CMD'"; usage; exit 2 ;;
esac

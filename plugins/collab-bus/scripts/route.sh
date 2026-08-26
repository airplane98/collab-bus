#!/usr/bin/env bash
# collab-bus routing — which messages in my inbox are addressed to ME.
#
#   route.sh list       [--agent <id>] [--include-closed] [--dir <inbox-dir>]
#   route.sh explain    [--agent <id>] <file>
#   route.sh capability
#
# WHY THIS IS A TOOL AND NOT AN INSTRUCTION. Until now the drain rule lived in prose:
# "process every inbox/to/<kind>/*.md whose `pair` matches your tab and whose `status` is
# open". That rule is a locator — it addresses a TAB, so the moment two participants of
# the same kind share one tab (the actual mesh blocker) both of them match every message,
# and the only thing keeping them apart is that there have only ever been two agents.
# Schema 2 addresses a PARTICIPANT, and the match is exact.
#
# The fallback is the interesting half. Legacy messages carry no `to_agent`, and they are
# already published — immutable, so they cannot be upgraded. They fall back to `pair`.
# What must NOT happen is a fallback for a message that HAS `to_agent`: "addressed to
# someone else, but my tab matches" is precisely the misdelivery exact routing exists to
# prevent, so a present-and-different `to_agent` is final.
#
# Exit: 0 ok; 1 at least one file could not be read (named on stderr, scan continues);
#       2 bad usage.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SELF/lib/envelope.sh"          # fm_block, fm_get, envelope_schema_of
. "$SELF/lib/manifest.sh"          # manifest_read_strict, _mf_digits_cmp

COLLAB_ROOT="${COLLAB_ROOT:-collab}"
PARTICIPANT="$SELF/participant.sh"
# What this build emits and understands. Bound from the binary for the step-2 reason: a
# capability an environment variable can raise is not a capability. The library keeps an
# overridable default so it stays testable; every real caller pins it here instead.
ROUTE_WRITER_SCHEMA=2
MF_TOOLING_READ=1,2
MF_TOOLING_WRITE="$ROUTE_WRITER_SCHEMA"

_r_err() { echo "route: $1" >&2; }

# --- who am I ---------------------------------------------------------------
# Two facts, from two DIFFERENT sources on purpose.
#
#   identity — from the registry, through its own codec. Reading bindings/<id>.json here
#              with a grep would be the per-key search step 2 banned, one directory over.
#   live tab — from THIS process's `herdr pane current`, never from the binding.
#
# The second is the fix for a real hole: `--agent` is what the docs tell an unbound
# session to pass, so taking the tab out of that identity's binding hands routing the
# LOCATOR OF WHOEVER HELD IT LAST. A previous session's tab then decides which legacy
# messages this one claims. `--agent` supplies the stable identity and nothing else; when
# herdr cannot answer, exact schema-2 messages still route and only the legacy fallback
# goes loud — the half that genuinely needs a tab is the only half that loses.
MY_AGENT=""; MY_KIND=""; MY_TAB=""

_r_live_tab() {
  command -v herdr >/dev/null 2>&1 || return 1
  local out t
  out="$(herdr pane current 2>/dev/null)" || return 1
  t="$(printf '%s' "$out" | sed -n 's/.*"tab_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$t" ] || return 1
  printf '%s' "$t"
}

_r_resolve_agent() { # [<id>]
  if [ -n "${1:-}" ]; then MY_AGENT="$1"
  else
    MY_AGENT="$(COLLAB_ROOT="$COLLAB_ROOT" "$PARTICIPANT" whoami)" \
      || { _r_err "pass --agent <id>, or bind this session first"; return 1; }
  fi
  MY_KIND="$(COLLAB_ROOT="$COLLAB_ROOT" "$PARTICIPANT" get "$MY_AGENT" kind)" || return 1
  MY_TAB="$(_r_live_tab)" || MY_TAB=""
  [ -n "$MY_TAB" ] || _r_err "herdr could not give this process a tab_id — legacy messages cannot be routed this round"
  [ -n "$MY_AGENT" ] && [ -n "$MY_KIND" ]
}

# --- the registry, cached ---------------------------------------------------
# `to_agent` was string equality and nothing else, so a perfectly legal publish could name
# a participant that does not exist, or one whose kind does not match the inbox it landed
# in — and every reader then said "not mine", quietly, with rc 0. A message nobody claims
# and nobody reports is worse than a rejected one.
_R_RK=(); _R_RV=(); _R_RN=0; R_KIND=""
# Sets R_KIND; rc 1 when the id is not registered. It does not PRINT the kind, because a
# caller would then wrap it in `$(...)` and the cache — written inside that subshell —
# would be thrown away on every lookup.
_r_kind_of() { # <participant-id>
  local i=0 k
  R_KIND=""
  while [ "$i" -lt "$_R_RN" ]; do
    if [ "${_R_RK[$i]}" = "$1" ]; then
      [ "${_R_RV[$i]}" = "!" ] && return 1
      R_KIND="${_R_RV[$i]}"; return 0
    fi
    i=$((i+1))
  done
  k="$(COLLAB_ROOT="$COLLAB_ROOT" "$PARTICIPANT" get "$1" kind 2>/dev/null)" || k=""
  _R_RK[$_R_RN]="$1"; _R_RV[$_R_RN]="${k:-!}"; _R_RN=$((_R_RN+1))
  [ -n "$k" ] || return 1
  R_KIND="$k"
}

# --- what may even be read --------------------------------------------------
# Shared by every entry point, because "list and explain share the verdict" was only true
# of the frontmatter: list skipped a dangling symlink silently while explain followed a
# live one and answered MINE. Admissibility is part of the verdict.
_r_admit() { # <file>
  if [ -L "$1" ]; then _r_err "$1 is a symlink — refusing"; return 1; fi
  if [ ! -e "$1" ]; then _r_err "$1 does not exist"; return 1; fi
  if [ ! -f "$1" ]; then _r_err "$1 is not a regular file — refusing"; return 1; fi
  return 0
}

# --- the routing decision ---------------------------------------------------
# One function, so `list` and `explain` can never disagree about what is mine — the point
# of `explain` is to show the reason for a verdict `list` actually used.
#
# Sets ROUTE_VERDICT to: mine | theirs:<why> | closed:<status> | unrouted:<why> | bad:<why>
#
# It SETS rather than prints for a reason that cost a whole review round: a caller writing
# `v="$(route_verdict "$f")"` runs the scan inside a subshell, so the decoded fields the
# scan produced die with it and `explain` then described a file it had not read — correct
# verdict, every field blank. State a caller has to keep cannot be produced behind a fork.
ROUTE_VERDICT=""
route_verdict() { # <file>
  local f="$1" to_agent from_agent pair status to_kind from_kind
  ROUTE_VERDICT=""
  # THE WHOLE ENVELOPE, THROUGH THE SHARED SCANNER. Pulling three keys out with a per-key
  # search is what the whole-file grammar exists to stop: a message carrying `to_agent:`
  # twice routes to the first value here and to the last one in Ruby, so two readers
  # disagree about who it is for. `envelope_read` also names each problem on stderr.
  envelope_read "$f" || { ROUTE_VERDICT='bad:the envelope did not validate'; return 0; }
  to_agent="$(env_field to_agent || true)"
  from_agent="$(env_field from_agent || true)"
  pair="$(env_field pair || true)"
  status="$(env_field status || true)"
  to_kind="$(env_field to || true)"
  from_kind="$(env_field from || true)"

  # Provenance first. An unregistered or wrong-kind sender makes the message
  # self-contradictory, and it also breaks the "is this handled?" query, which keys on the
  # recipient replying as itself.
  if [ -n "$from_agent" ]; then
    if _r_kind_of "$from_agent"; then
      [ "$R_KIND" = "$from_kind" ] || {
        ROUTE_VERDICT="bad:from_agent $from_agent is kind $R_KIND, but the message says from: $from_kind"
        return 0; }
    else
      ROUTE_VERDICT="bad:from_agent $from_agent is not a registered participant"; return 0
    fi
  fi

  # Addressing, THEN lifecycle: a message addressed to somebody else is not mine to report
  # as "already handled", and the two answers mean different things to a caller.
  if [ -n "$to_agent" ]; then
    if _r_kind_of "$to_agent"; then
      [ "$R_KIND" = "$to_kind" ] || {
        ROUTE_VERDICT="bad:to_agent $to_agent is kind $R_KIND, but the message says to: $to_kind"
        return 0; }
      [ "$to_agent" = "$MY_AGENT" ] || { ROUTE_VERDICT="theirs:to_agent=$to_agent"; return 0; }
    else
      # Loud, and NEVER a fallback to the tab: the sender named a recipient, so the tab is
      # not a second opinion about who it is for. Registering that id later makes the next
      # scan route it normally.
      ROUTE_VERDICT="unrouted:to_agent $to_agent is not a registered participant"; return 0
    fi
  elif [ -n "$pair" ]; then
    # Legacy: no stable address exists, so the tab is all there is.
    [ -n "$MY_TAB" ] || { ROUTE_VERDICT='unrouted:legacy message needs my live tab, which herdr did not give'; return 0; }
    [ "$pair" = "$MY_TAB" ] || { ROUTE_VERDICT="theirs:pair=$pair"; return 0; }
  else
    # Neither an address nor a tab. Claiming it would mean guessing, and a wrong guess
    # here hands one pair's work to another.
    ROUTE_VERDICT='unrouted:no to_agent and no pair'; return 0
  fi

  # `status` is legacy but still authoritative for the drain, and schema 2 keeps emitting
  # it precisely so a v0.7 reader still sees the same open set (contract D).
  case "$status" in
    ''|open) ROUTE_VERDICT='mine' ;;
    *)       ROUTE_VERDICT="closed:$status" ;;
  esac
  return 0
}

# --- subcommands ------------------------------------------------------------
usage() {
  echo "usage: route.sh list [--agent <id>] [--include-closed] [--dir <inbox-dir>]" >&2
  echo "       route.sh explain [--agent <id>] <file>" >&2
  echo "       route.sh capability" >&2
}

# Where my messages arrive: inbox/to/<my kind>/, resolved through the registry so it is
# the identity that decides, not a directory name somebody typed.
_r_default_dir() {
  local kind
  kind="$(COLLAB_ROOT="$COLLAB_ROOT" "$PARTICIPANT" get "$MY_AGENT" kind)" || return 1
  printf '%s/inbox/to/%s' "$COLLAB_ROOT" "$kind"
}

[ "$#" -ge 1 ] || { usage; exit 2; }
CMD="$1"; shift

case "$CMD" in
  list)
    AGENT=""; ALL=0; DIR=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --agent) [ $# -ge 2 ] || { _r_err "--agent needs a value"; exit 2; }; AGENT="$2"; shift 2 ;;
        --dir)   [ $# -ge 2 ] || { _r_err "--dir needs a value"; exit 2; }; DIR="$2"; shift 2 ;;
        # NOT `--all`: this widens the list to my CLOSED messages, it does not show
        # other participants' work. A flag that reads like "everything" invites exactly
        # the cross-pair processing the routing exists to stop.
        --include-closed) ALL=1; shift ;;
        *) _r_err "unexpected argument '$1'"; usage; exit 2 ;;
      esac
    done
    _r_resolve_agent "$AGENT" || exit 1
    [ -n "$DIR" ] || DIR="$(_r_default_dir)" || exit 1
    [ -d "$DIR" ] || { _r_err "$DIR is not a directory"; exit 1; }
    [ -L "$DIR" ] && { _r_err "$DIR is a symlink — refusing"; exit 1; }
    rc=0
    # Sorted by filename: ULIDs are lexicographically ordered by their timestamp half, so
    # this is oldest-first for anything this tool minted. It is an ORDER, not a clock —
    # §5 forbids using it to decide anything.
    for f in "$DIR"/*.md; do
      # Distinguish "the glob matched nothing" from "the entry is not admissible": a
      # dangling symlink fails -f too, and skipping it silently is how a message that
      # should have been reported disappears.
      [ -e "$f" ] || [ -L "$f" ] || continue
      _r_admit "$f" || { rc=1; continue; }
      route_verdict "$f"; v="$ROUTE_VERDICT"
      case "$v" in
        mine)    printf '%s\n' "$f" ;;
        closed:*) [ "$ALL" = 1 ] && printf '%s\n' "$f" ;;
        # Loud and non-fatal, per contract E: one bad file must not stop the scan, and it
        # must not vanish either — silence here is how a message goes missing forever.
        bad:*)      _r_err "$f: ${v#bad:}"; rc=1 ;;
        unrouted:*) _r_err "$f: ${v#unrouted:} — not claiming it"; rc=1 ;;
        *) : ;;
      esac
    done
    exit "$rc"
    ;;

  explain)
    AGENT=""; FILE=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --agent) [ $# -ge 2 ] || { _r_err "--agent needs a value"; exit 2; }; AGENT="$2"; shift 2 ;;
        -*) _r_err "unexpected argument '$1'"; usage; exit 2 ;;
        *) [ -z "$FILE" ] || { _r_err "explain takes one file"; exit 2; }; FILE="$1"; shift ;;
      esac
    done
    [ -n "$FILE" ] || { usage; exit 2; }
    _r_admit "$FILE" || exit 1
    _r_resolve_agent "$AGENT" || exit 1
    route_verdict "$FILE"; v="$ROUTE_VERDICT"
    # Everything below comes from the SAME scan the verdict used — re-reading the file
    # here is how an explanation starts describing a different file than the one acted on.
    printf 'agent: %s (kind %s, live tab %s)\n' "$MY_AGENT" "$MY_KIND" "${MY_TAB:-(unknown)}"
    printf 'schema: %s\n' "${ENV_SCHEMA:-(unreadable)}"
    printf 'to_agent: %s\n' "$(env_field to_agent || echo '(absent)')"
    printf 'pair: %s\n' "$(env_field pair || echo '(absent)')"
    printf 'status: %s\n' "$(env_field status || echo '(absent)')"
    case "$v" in
      mine)       printf 'verdict: MINE\n' ;;
      theirs:*)   printf 'verdict: not mine (%s)\n' "${v#theirs:}" ;;
      closed:*)   printf 'verdict: mine, but already %s\n' "${v#closed:}" ;;
      unrouted:*) printf 'verdict: UNROUTED (%s)\n' "${v#unrouted:}"; exit 1 ;;
      bad:*)      printf 'verdict: UNREADABLE (%s)\n' "${v#bad:}"; exit 1 ;;
    esac
    ;;

  capability)
    # Contract D: whether the legacy fields may be dropped is a claim about LIVE READERS,
    # so it is answered by the bindings of running processes plus a floor a human raised
    # on purpose — never by the version of the file on disk. All three must hold, and the
    # honest answer today is no.
    BF="$COLLAB_ROOT/bus.json"
    minr="?"; r=0
    if [ -f "$BF" ]; then
      manifest_read_strict "$BF" || r=$?
      case "$r" in
        0) minr="$MF_MIN_READER" ;;
        # rc 3 is the codec's WRITER verdict — "newer than this build, do not overwrite".
        # A reader must not flatten that into "corrupt": the honest report is that this
        # build cannot judge the floor, which keeps the legacy fields required.
        3) _r_err "$BF was written by newer tooling — this build cannot judge min_reader" ;;
        *) _r_err "$BF does not validate" ;;
      esac
    else
      _r_err "$BF not found — run bootstrap.sh"
    fi
    BDIR="$COLLAB_ROOT/bindings"
    # A BINDING FILE IS A RECORD OF THE LAST CLAIM, NOT A LIVE READER. Counting files let
    # two ended sessions vouch for a capability nobody present could honour, so every
    # binding is put through step 3's three-state liveness and only `live` counts.
    below=""; unbound=""; stale=""; unsure=""; nb=0; snap=""
    if [ -d "$COLLAB_ROOT/participants" ]; then
      for p in "$COLLAB_ROOT/participants"/*.json; do
        [ -f "$p" ] || continue
        id="$(basename "$p")"; id="${id%.json}"
        if [ ! -f "$BDIR/$id.json" ]; then
          # Registered and never claimed: an UNKNOWN reader, and unknown cannot license
          # dropping the fields it might need.
          unbound="$unbound $id"; continue
        fi
        # ONE call, one decode. Asking for the schema and the liveness separately ran two
        # processes that each re-read the binding, so a rebind in between spliced a stale
        # holder's schema onto a new holder's liveness — and reported a schema-2 live
        # reader that existed at no instant. A snapshot is not merely tidier here; it is
        # the difference between a stale answer and an impossible one.
        snap="$(COLLAB_ROOT="$COLLAB_ROOT" "$PARTICIPANT" snapshot "$id" 2>/dev/null || true)"
        # Positional, per the snapshot output contract: schema, liveness, pane, tab,
        # session. Read by position rather than by trimming the ends, so appending a
        # field later cannot silently turn `liveness` into something else.
        rs=""; lv=""
        IFS='	' read -r rs lv _ <<SNAP
$snap
SNAP
        if [ -z "$rs" ] || [ -z "$lv" ]; then unsure="$unsure $id(unreadable)"; continue; fi
        case "$lv" in
          live)
            c=0; _mf_digits_cmp "$rs" 2 || c=$?
            if [ "$c" = 2 ]; then below="$below $id($rs)"; else nb=$((nb+1)); fi ;;
          absent) stale="$stale $id" ;;
          *)      unsure="$unsure $id(liveness $lv)" ;;
        esac
      done
    fi
    printf 'writer schema: %s (emits schema 2 plus legacy pair + status: open)\n' "$ROUTE_WRITER_SCHEMA"
    printf 'bus.json min_reader: %s\n' "$minr"
    printf 'LIVE bindings at schema >= 2: %s\n' "$nb"
    printf 'live but below schema 2:%s\n' "${below:- none}"
    printf 'bound but not live (stale claim):%s\n' "${stale:- none}"
    printf 'liveness unknown:%s\n' "${unsure:- none}"
    printf 'registered but never bound:%s\n' "${unbound:- none}"
    if [ "$minr" = 2 ] && [ -z "$below" ] && [ -z "$unbound" ] && [ -z "$stale" ] \
       && [ -z "$unsure" ] && [ "$nb" -gt 0 ]; then
      printf 'legacy pair + status: MAY BE DROPPED\n'
    else
      printf 'legacy pair + status: REQUIRED — keep emitting both\n'
      printf '  raising min_reader is a deliberate human migration step, not a side effect\n'
    fi
    # Said plainly, because the tool cannot prove it either way: a session that started
    # before v0.8 has no binding at all, so no inventory of this directory can show that
    # it is gone. Raising min_reader is the human asserting that cutover happened.
    printf '  note: a pre-v0.8 session has no binding to inventory — only the human\n'
    printf '        min_reader cutover can rule those readers out\n'
    ;;

  -h|--help) usage; exit 0 ;;
  *) _r_err "unknown subcommand '$CMD'"; usage; exit 2 ;;
esac

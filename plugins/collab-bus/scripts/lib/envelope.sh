#!/usr/bin/env bash
# collab-bus envelope library — parse, quote, and validate message frontmatter.
# SOURCE this file; it defines functions and has no side effects of its own.
#
# Two schemas coexist by design (v0.8 contract §9):
#   schema 1  legacy — no `schema:` key. The nine fields the bus has actually used.
#   schema 2  v0.8   — adds thread / stable agent ids / intent / outcome, and REQUIRES
#                      human-authored scalars to be single-quoted.
#
# The validator is deliberately dependency-free: a conservative lint written in bash,
# because collab-bus must run wherever the peer runs. Where a real YAML parser happens to
# be installed, `envelope_yaml_check` adds a safe-load on top — a strengthening, never a
# requirement.
#
# Why single quotes for human text: YAML's single-quoted style has NO backslash
# processing, so the only escape is '' for a literal apostrophe. Double quotes would drag
# in backslash escapes, \u, and multi-line folding — far more ways for an agent-authored
# subject to produce a file nobody can parse.

ENVELOPE_SCHEMA_LATEST=2

# Keys the legacy bus actually uses (measured over 126 live messages, v0.8 plan §14.1).
# Narrower than "anything goes" so a typo is caught, wider than schema 2 so the running
# bus is not locked out of its own gate.
ENVELOPE_KEYS_V1="id from to type subject refs status pair reply_to"
ENVELOPE_KEYS_V2="schema id thread reply_to cancels from to from_agent to_agent intent type subject refs outcome status pair"
ENVELOPE_REQUIRED_V1="id from to type subject status"
ENVELOPE_REQUIRED_V2="schema id thread from to from_agent to_agent intent type subject"
# Values written by an agent rather than by a script.
ENVELOPE_HUMAN_KEYS="subject refs note alias"

_env_err() { echo "envelope: $1" >&2; }

# _env_file_has_nul <file> — a RAW BYTE check, done on the file itself.
# Bash cannot hold a NUL: command substitution silently drops it, so by the time the
# frontmatter is in a variable the byte is gone and both the lint and the YAML parser see
# a clean string — while the file on disk stays unreadable to a real parser. No
# variable-based check can ever catch this; the file has to be compared against a
# NUL-stripped copy of itself.
_env_file_has_nul() {
  ! LC_ALL=C tr -d '\000' < "$1" | cmp -s - "$1"
}
_env_has() { case " $2 " in *" $1 "*) return 0;; *) return 1;; esac; }

# fm_block <file> — print the frontmatter, without the --- delimiters.
fm_block() {
  local f="$1"
  [ -r "$f" ] || { _env_err "cannot read $f"; return 1; }
  # Require the very first line to be the opening delimiter; stop at the closing one.
  # `exit` in awk runs END before leaving, so the status must be carried in a variable —
  # otherwise END's own `exit 3` overwrites the "no opening delimiter" status.
  awk 'NR==1 && $0!="---" { rc=2; exit }
       NR==1 { next }
       $0=="---" { found=1; exit }
       { print }
       END { if (rc) exit rc; if (!found) exit 3 }' "$f"
}

# fm_get <file> <key> — print a scalar value with canonical single-quoting removed.
fm_get() {
  local f="$1" k="$2" raw sq=\'
  raw="$(fm_block "$f" | sed -n "s/^${k}:[[:space:]]*//p" | head -1)" || return 1
  [ -n "$raw" ] || return 1
  case "$raw" in
    "'"*"'")
      raw="${raw#\'}"; raw="${raw%\'}"
      # In single-quoted YAML the ONLY escape is a doubled apostrophe. The pattern and
      # replacement come from a variable: a literal \' inside ${x//../..} is kept as a
      # backslash rather than being treated as an escaped quote.
      printf '%s' "${raw//$sq$sq/$sq}" ;;
    *) printf '%s' "$raw" ;;
  esac
}

# _env_has_control <string> — true if the value holds a C0 control byte (or DEL).
# YAML forbids most of these outright, so a value carrying one produces a file a real
# parser rejects while our own quoting happily accepts it. Enumerating just LF/CR/TAB was
# not enough: a BEL survived the generator and Ruby then refused the message.
_env_has_control() {
  case "$1" in
    *[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037'$'\177']*) return 0 ;;
    *$'\n'*|*$'\r'*|*$'\t'*) return 0 ;;
  esac
  return 1
}

# fm_quote <string> — canonical single-quoted YAML scalar.
fm_quote() {
  local s="$1" sq=\'
  # Refuse rather than silently mangle: a value that spans lines or hides a control byte
  # is a writer bug, and quietly passing it through changes what the reader ends up
  # seeing — or makes the file unreadable to a real parser.
  case "$s" in
    *$'\n'*) _env_err "value contains a newline, which frontmatter forbids"; return 2 ;;
    *$'\r'*) _env_err "value contains a carriage return, which frontmatter forbids"; return 2 ;;
    *$'\t'*) _env_err "value contains a tab, which frontmatter forbids"; return 2 ;;
  esac
  if _env_has_control "$s"; then
    _env_err "value contains a control character, which frontmatter forbids"; return 2
  fi
  printf "'%s'" "${s//$sq/$sq$sq}"
}

# _env_unquote <raw> — strip canonical single-quoting; in that style the only escape is a
# doubled apostrophe. A literal \' inside ${x//../..} stays a backslash, so the pattern
# and the replacement come from a variable.
_env_unquote() {
  local raw="$1" sq=\'
  case "$raw" in
    "'"*"'") raw="${raw#\'}"; raw="${raw%\'}"; printf '%s' "${raw//$sq$sq/$sq}" ;;
    *) printf '%s' "$raw" ;;
  esac
}

# envelope_schema_of <file> — 2 when `schema:` says so, else 1 (legacy has no such key).
envelope_schema_of() {
  local v
  v="$(fm_get "$1" schema 2>/dev/null)" || { printf '1'; return 0; }
  case "$v" in ''|*[!0-9]*) printf '1' ;; *) printf '%s' "$v" ;; esac
}

# _env_plain_is_safe <value> — can this UNQUOTED scalar survive a real YAML parser?
#
# This is the ONLY protection where no YAML parser is installed, so it is deliberately
# conservative: anything it is not sure about must be single-quoted instead. ": " is the
# mapping indicator that actually broke 13 live messages; the rest are the other plain
# scalar traps — leading indicators (including "- " for a sequence and "? " for a complex
# key), an inline " #" comment that would truncate the value, and whitespace or control
# characters that do not survive a round trip.
_env_plain_is_safe() {
  local v="$1"
  case "$v" in
    *": "*)        return 1 ;;   # mapping indicator
    *:)            return 1 ;;   # trailing colon reads as a key
    *" #"*)        return 1 ;;   # the rest would be dropped as a comment
    *$'\t'*|*$'\r'*) return 1 ;; # control characters
    " "*|*" ")     return 1 ;;   # leading/trailing space is stripped, not preserved
    "- "*|"? "*)   return 1 ;;   # block sequence / complex key
    [-?:,\[\]\{\}\#\&\*\!\|\>\'\"\%\@\`]*) return 1 ;;   # any leading indicator
    "")            return 1 ;;
  esac
  return 0
}

# _env_quoting_is_balanced <raw> — for a single-quoted scalar, every interior apostrophe
# must be doubled, so stripping the outer quotes must leave only even-length ' runs.
_env_quoting_is_balanced() {
  local raw="$1" inner rest sq=\'
  case "$raw" in "'"*"'") : ;; *) return 1 ;; esac
  inner="${raw#\'}"; inner="${inner%\'}"
  # Delete every doubled apostrophe; anything left over was unpaired. Done in bash rather
  # than awk because BSD awk does not read \x27 as an escape, which made this silently
  # pass everything on macOS.
  rest="${inner//$sq$sq/}"
  case "$rest" in *"$sq"*) return 1 ;; esac
  return 0
}

# --- one scanner, two modes -------------------------------------------------
# ROUTING READS THE SAME FILES THE GATE WRITES, so it has to parse them the same way. A
# reader that pulls three keys out with `sed -n s/^to_agent://p | head -1` reintroduces
# exactly what the whole-file grammar exists to stop: a message carrying `to_agent:` twice
# routes to the FIRST value here and to the LAST one in Ruby or PyYAML, so two readers
# disagree about who a message is for. Any second implementation drifts from the first the
# moment either changes, so there is one scanner with a mode.
#
# The modes differ in ONE rule, and only because published messages are immutable:
#   publish — every identifier and reference must be a ULID. New messages are held to this.
#   reader  — in schema 1, an identifier OR A REFERENCE TO ONE may be the pre-ULID counter
#             (`0077`). Both halves are required, and deliberately: those messages are
#             already on the bus and cannot be rewritten, and a legacy reply legitimately
#             carries `reply_to: 0077`. Refusing to READ them would not un-publish them,
#             it would only make them invisible — and narrowing this to `id` alone would
#             re-break every legacy reply chain.
# Everything else — duplicates, unknown keys, required keys, value shapes, quoting — is
# identical, because none of it becomes safe to skip just because a file is old.
#
# On success the decoded fields are left in _ENV_K/_ENV_V for `env_field`, so a caller
# never parses the file a second time.
ENV_SCHEMA=""; _ENV_K=(); _ENV_V=(); _ENV_N=0

# env_field <key> — the decoded value from the last successful scan, or empty.
env_field() {
  local i=0
  while [ "$i" -lt "$_ENV_N" ]; do
    [ "${_ENV_K[$i]}" = "$1" ] && { printf '%s' "${_ENV_V[$i]}"; return 0; }
    i=$((i+1))
  done
  return 1
}

# envelope_check <file> — the publish gate. Prints every problem, returns 1 if any.
envelope_check() { _envelope_scan "$1" publish; }
# envelope_read <file> — the reader gate. Same scan, legacy ids tolerated; on success the
# fields are available through `env_field`.
envelope_read()  { _envelope_scan "$1" reader; }

# EVERY failure exit goes through here. "A failed scan leaves nothing behind" was written
# as an epilogue, so the early returns — which are failures too — walked straight past it
# and left a caller reading state from a scan that had been refused.
_env_scan_fail() { ENV_SCHEMA=""; _ENV_K=(); _ENV_V=(); _ENV_N=0; return 1; }

_envelope_scan() {
  local f="$1" mode="${2:-publish}" schema keys required block line key raw bad=0 seen=""
  ENV_SCHEMA=""; _ENV_K=(); _ENV_V=(); _ENV_N=0
  # BEFORE any command substitution, or the byte we are looking for is already gone.
  if [ -r "$f" ] && _env_file_has_nul "$f"; then
    _env_err "$f: contains a NUL byte — refusing (a real parser would reject this file)"
    _env_scan_fail; return 1
  fi
  block="$(fm_block "$f")" || {
    case $? in
      2) _env_err "$f: no opening --- on line 1" ;;
      3) _env_err "$f: frontmatter is never closed by ---" ;;
      *) _env_err "$f: unreadable" ;;
    esac
    _env_scan_fail; return 1
  }
  schema="$(envelope_schema_of "$f")"
  if [ "$schema" = 1 ]; then
    keys="$ENVELOPE_KEYS_V1"; required="$ENVELOPE_REQUIRED_V1"
  elif [ "$schema" = 2 ]; then
    keys="$ENVELOPE_KEYS_V2"; required="$ENVELOPE_REQUIRED_V2"
  else
    # A schema this build cannot read is a REFUSAL, so it must not be published as the
    # success-state ENV_SCHEMA; the rejected value belongs in the message, not in a field
    # a caller reads after a failure.
    _env_err "$f: unknown envelope schema '$schema' — refusing to guess"
    _env_scan_fail; return 1
  fi
  # Only now, with the schema known-good, does it become part of the scan result.
  ENV_SCHEMA="$schema"

  while IFS= read -r line; do
    [ -n "${line//[[:space:]]/}" ] || continue
    if ! [[ "$line" =~ ^[a-z][a-z0-9_]*: ]]; then
      _env_err "$f: not a 'key: value' line: ${line:0:60}"; bad=1; continue
    fi
    key="${line%%:*}"
    raw="${line#*:}"; raw="${raw# }"
    if ! _env_has "$key" "$keys"; then
      _env_err "$f: key '$key' is not in the schema $schema field set"; bad=1; continue
    fi
    # A repeated key is not merely untidy: fm_get takes the first, while Ruby and PyYAML
    # take the LAST, so a duplicated `to:` would route differently depending on who reads
    # it. Refuse rather than pick a winner.
    if _env_has "$key" "$seen"; then
      _env_err "$f: key '$key' appears more than once — readers would disagree on its value"; bad=1; continue
    fi
    seen="$seen $key"
    # Record the DECODED value as we go: canonical single-quoting removed exactly once,
    # here, so no caller has to know the quoting rules to read a field.
    _ENV_K[$_ENV_N]="$key"; _ENV_V[$_ENV_N]="$(_env_unquote "$raw")"; _ENV_N=$((_ENV_N+1))
    if [ -z "$raw" ]; then
      # Only `refs` may be present-but-empty, and only in the legacy schema, because the
      # v0.7 template emitted a bare `refs:`. Everything else must carry a value —
      # otherwise "required" would be satisfied by an empty line.
      if [ "$key" = refs ] && [ "$schema" = 1 ]; then continue; fi
      _env_err "$f: key '$key' has an empty value"; bad=1; continue
    fi

    if _env_has "$key" "$ENVELOPE_HUMAN_KEYS"; then
      # Applies to quoted and plain alike: fm_quote refuses these, but a value written by
      # hand never went through fm_quote, and without a real YAML parser installed this
      # check is the only thing standing between a control byte and the bus.
      if _env_has_control "$raw"; then
        _env_err "$f: $key: value contains a control character"; bad=1; continue
      fi
      case "$raw" in
        "'"*)
          _env_quoting_is_balanced "$raw" || {
            _env_err "$f: $key: single-quoted value has an unpaired apostrophe (double it: '')"; bad=1; }
          ;;
        '"'*)
          _env_err "$f: $key: use single quotes, not double (no backslash escaping)"; bad=1 ;;
        *)
          if [ "$schema" -ge 2 ]; then
            _env_err "$f: $key: schema 2 requires a single-quoted value"; bad=1
          elif ! _env_plain_is_safe "$raw"; then
            _env_err "$f: $key: unquoted value is not valid YAML (contains ': ', a trailing ':', a leading indicator, or a tab)"; bad=1
          fi
          ;;
      esac
      continue
    fi

    # Machine tokens: allowlisted shapes, never quoted.
    case "$key" in
      schema)   [[ "$raw" =~ ^[0-9]+$ ]] || { _env_err "$f: schema must be an integer"; bad=1; } ;;
      id|thread|reply_to|cancels)
                if [[ "$raw" =~ ^[0-7][0-9A-HJKMNP-TV-Z]{25}$ ]]; then :
                elif [ "$mode" = reader ] && [ "$schema" = 1 ] && [[ "$raw" =~ ^[0-9]{1,8}$ ]]; then
                  : # a pre-ULID identifier or reference: already published, unrewritable,
                    # and `reply_to` needs it as much as `id` does
                else
                  _env_err "$f: $key must be a 26-char Crockford ULID (got '$raw')"; bad=1
                fi ;;
      from|to)  [[ "$raw" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { _env_err "$f: $key: bad kind '$raw'"; bad=1; } ;;
      from_agent|to_agent)
                [[ "$raw" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { _env_err "$f: $key: bad participant id '$raw'"; bad=1; } ;;
      intent)   [[ "$raw" =~ ^(action|fyi)$ ]] || { _env_err "$f: intent must be action|fyi"; bad=1; } ;;
      outcome)  [[ "$raw" =~ ^(done|rejected|failed|canceled)$ ]] \
                  || { _env_err "$f: outcome must be done|rejected|failed|canceled"; bad=1; } ;;
      # `closed` is legacy-only: it is what FYI messages have been using.
      status)   if [ "$schema" -ge 2 ]; then
                  [[ "$raw" =~ ^(open|done)$ ]] || { _env_err "$f: schema 2 status must be open|done"; bad=1; }
                else
                  [[ "$raw" =~ ^(open|done|closed)$ ]] || { _env_err "$f: status must be open|done|closed"; bad=1; }
                fi ;;
      pair)     [[ "$raw" =~ ^w[0-9]+:t[0-9]+$ ]] || { _env_err "$f: pair must look like w3:t6"; bad=1; } ;;
      type)     [[ "$raw" =~ ^[a-z][a-z-]*$ ]] || { _env_err "$f: type: bad value '$raw'"; bad=1; } ;;
    esac
  done <<EOF
$block
EOF

  for key in $required; do
    _env_has "$key" "$seen" || { _env_err "$f: required key '$key' is missing (schema $schema)"; bad=1; }
  done
  # A failed scan leaves NOTHING behind. Fields accumulated before the first problem are
  # a partial decode, and a caller reading them would be acting on a file this function
  # just refused.
  [ "$bad" = 0 ] || _env_scan_fail
  return "$bad"
}

# envelope_yaml_check <file> — OPTIONAL strengthening. Runs a real parser when one is
# already installed; silently reports success when none is, so it never becomes a
# dependency. Returns 1 only when a parser actually rejected the frontmatter.
envelope_yaml_check() {
  local f="$1" block out
  block="$(fm_block "$f")" || return 1
  # Three outcomes must stay distinct, which an exit code alone cannot express:
  # the parser accepted it, the parser REJECTED it, or the parser could not run at all
  # (missing, broken, wrong version). Only the middle one is a validation failure —
  # treating "could not run" as a rejection would fail every file on a host where, say,
  # `ruby` exists but is unusable. A printed sentinel separates them.
  if command -v ruby >/dev/null 2>&1; then
    out="$(printf '%s\n' "$block" | ruby -ryaml -e '
      begin; YAML.safe_load(STDIN.read); puts "ENVELOPE_YAML_OK"
      rescue => e; puts "ENVELOPE_YAML_BAD: #{e.message.lines.first.to_s.strip}"; end' 2>/dev/null)"
    case "$out" in
      ENVELOPE_YAML_OK*)  return 0 ;;
      ENVELOPE_YAML_BAD*) _env_err "$f: ${out#ENVELOPE_YAML_BAD: }"; return 1 ;;
    esac
  fi
  if command -v python3 >/dev/null 2>&1; then
    out="$(printf '%s\n' "$block" | python3 -c '
import sys
try: import yaml
except Exception: sys.exit(0)
try:
    yaml.safe_load(sys.stdin.read()); print("ENVELOPE_YAML_OK")
except Exception as e: print("ENVELOPE_YAML_BAD: %s" % str(e).splitlines()[0])' 2>/dev/null)"
    case "$out" in
      ENVELOPE_YAML_OK*)  return 0 ;;
      ENVELOPE_YAML_BAD*) _env_err "$f: ${out#ENVELOPE_YAML_BAD: }"; return 1 ;;
    esac
  fi
  return 0   # no usable parser — the dependency-free lint above is the whole guarantee
}

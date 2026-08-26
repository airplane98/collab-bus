#!/usr/bin/env bash
# collab-bus bus.json codec — strict reader/writer for the capability manifest.
# SOURCE this file; it defines functions and has no side effects.
#
# NOTE FOR CALLERS: these functions RETURN a status as their result (0 ok / 1 malformed /
# 3 newer-than-us). A caller running under `set -e` must therefore not invoke them bare —
# `set -e` would kill the script on a perfectly expected non-zero result, before the
# caller can even read it. Use `if manifest_read_strict f; then` or
# `rc=0; manifest_read_strict f || rc=$?`. Internally this file is written to survive
# `set -e` too: every command whose non-zero status is meaningful is guarded.
#
# Why not `sed -n 's/.*"key": "\(...\)".*/\1/p'`: a search finds a shape anywhere in a
# file, so "THIS IS NOT JSON \"project_id\": \"<ulid>\" TRAILING" was accepted and then
# rewritten as valid JSON — corruption laundered into a clean-looking manifest. A file
# that decides identity and capability has to be *parsed*, not grepped.
#
# Same shape as the envelope work: a dependency-free strict grammar is the guarantee, and
# a real JSON parser is an optional strengthening layered on top (standard parsers accept
# duplicate keys, so the duplicate check must be ours regardless).
#
# Ownership matrix — who may change what:
#   immutable                      project_id
#   human-owned, preserved         project_alias, schemas.min_reader
#   tooling-owned, refreshed       schemas.read, schemas.write, publisher_version
# The last group is refreshed only when canonicalizing the same version or moving
# FORWARD. Older tooling meeting a newer manifest must fail, never silently downgrade.

MANIFEST_SCHEMA_LATEST=1
# What THIS tooling can read; a manifest claiming more came from something newer.
MF_TOOLING_READ="${MF_TOOLING_READ:-1,2}"
# What this tooling could have WRITTEN. A recorded value outside this set did not come
# from us, so resetting it would be a downgrade rather than a canonicalization.
MF_TOOLING_WRITE="${MF_TOOLING_WRITE:-1}"

# Parsed results (set by manifest_read_strict)
MF_PROJECT_ID=""; MF_PROJECT_ALIAS=""; MF_MIN_READER=""
MF_PUBLISHER_VERSION=""; MF_MANIFEST_SCHEMA=""

_mf_err() { echo "manifest: $1" >&2; }

# A raw-byte check on the FILE. Bash drops NUL at command substitution and cannot hold it
# in a variable, so a NUL inserted after the opening brace survives every string-level
# check while leaving a file no JSON parser will read. Same lesson as the envelope gate:
# a byte the checker cannot represent has to be looked for in the bytes.
_mf_file_has_nul() { ! LC_ALL=C tr -d '\000' < "$1" | cmp -s - "$1"; }

# _mf_json_escape <string> — the two characters JSON requires escaping in a string.
# Control bytes are rejected by the caller rather than escaped: a manifest is machine
# data, and a project alias containing one is a bug, not something to encode.
_mf_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# _mf_version_cmp <a> <b> — 0 if a==b, 1 if a>b, 2 if a<b. Numeric per component, so
# 0.10.0 sorts after 0.9.0 (a lexical compare would get that backwards).
# A version this tooling would accept anywhere: three numeric parts, optional
# prerelease, optional build metadata — anchored, so "0.7.0junk" is not a version.
MF_VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

# _mf_digits_cmp <a> <b> — compare two digit strings WITHOUT shell arithmetic.
# SemVer numeric identifiers have no upper bound and MF_VERSION_RE accepts arbitrarily
# long digits, so `[ "$x" -gt "$y" ]` on a value past the 64-bit range prints
# "integer expression expected" and returns false — which fell through to "equal", i.e. a
# hugely newer version compared as not-newer and got silently downgraded. Length first,
# then a C-locale lexical compare, is exact at any size.
_mf_digits_cmp() {
  local LC_ALL=C a="$1" b="$2"
  while [ "${#a}" -gt 1 ] && [ "${a:0:1}" = 0 ]; do a="${a:1}"; done
  while [ "${#b}" -gt 1 ] && [ "${b:0:1}" = 0 ]; do b="${b:1}"; done
  [ "${#a}" -gt "${#b}" ] && return 1
  [ "${#a}" -lt "${#b}" ] && return 2
  [[ "$a" > "$b" ]] && return 1
  [[ "$a" < "$b" ]] && return 2
  return 0
}

# _mf_id_cmp <a> <b> — one dot-separated prerelease identifier, SemVer rules: numeric
# identifiers compare numerically and rank BELOW alphanumeric ones.
_mf_id_cmp() {
  local LC_ALL=C a="$1" b="$2" an=0 bn=0 r
  [[ "$a" =~ ^[0-9]+$ ]] && an=1
  [[ "$b" =~ ^[0-9]+$ ]] && bn=1
  if [ "$an" = 1 ] && [ "$bn" = 1 ]; then
    r=0; _mf_digits_cmp "$a" "$b" || r=$?
    return "$r"
  fi
  [ "$an" = 1 ] && return 2      # numeric < alphanumeric
  [ "$bn" = 1 ] && return 1
  [[ "$a" > "$b" ]] && return 1
  [[ "$a" < "$b" ]] && return 2
  return 0
}

# _mf_version_cmp <a> <b> — 0 if a==b, 1 if a>b, 2 if a<b (SemVer precedence).
# Build metadata is ignored, but must be stripped BEFORE the prerelease suffix: otherwise
# "0.7.1+meta" leaves "1+meta" as the patch component, which parses as non-numeric and
# silently becomes 0. Prerelease is NOT simply discarded either — dropping it made a
# stable 0.7.0 compare equal to 0.7.0-alpha, so prerelease tooling would rewrite a stable
# manifest back to itself.
_mf_version_cmp() {
  local LC_ALL=C a="$1" b="$2" i x y apre bpre ai bi n
  a="${a%%+*}"; b="${b%%+*}"
  apre=""; bpre=""
  case "$a" in *-*) apre="${a#*-}"; a="${a%%-*}" ;; esac
  case "$b" in *-*) bpre="${b#*-}"; b="${b%%-*}" ;; esac
  local r
  for i in 1 2 3; do
    x="$(printf '%s' "$a" | cut -d. -f$i)"; y="$(printf '%s' "$b" | cut -d. -f$i)"
    case "$x" in ''|*[!0-9]*) x=0 ;; esac
    case "$y" in ''|*[!0-9]*) y=0 ;; esac
    r=0; _mf_digits_cmp "$x" "$y" || r=$?
    [ "$r" -ne 0 ] && return "$r"
  done
  # Same core: a version WITHOUT a prerelease outranks one with.
  [ -z "$apre" ] && [ -z "$bpre" ] && return 0
  [ -z "$apre" ] && return 1
  [ -z "$bpre" ] && return 2
  local -a A B
  IFS=. read -r -a A <<< "$apre"
  IFS=. read -r -a B <<< "$bpre"
  n=${#A[@]}; [ ${#B[@]} -gt "$n" ] && n=${#B[@]}
  for (( i=0; i<n; i++ )); do
    ai="${A[$i]:-}"; bi="${B[$i]:-}"
    [ -z "$ai" ] && return 2        # a ran out of fields first: fewer fields ranks lower
    [ -z "$bi" ] && return 1
    local r=0; _mf_id_cmp "$ai" "$bi" || r=$?
    [ "$r" -ne 0 ] && return "$r"
  done
  return 0
}

# The canonical shape we emit. The reader requires exactly this, because a file that
# decides identity and capability must be validated as a WHOLE — a per-key search accepts
# a root array, a string where a number belongs, prose wrapped around the object, or a key
# it simply cannot see, and then rewrites all of it away as if nothing were wrong.
_MF_L1='^[[:space:]]*\{[[:space:]]*$'
_MF_L2='^[[:space:]]*"manifest_schema"[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*$'
_MF_L3='^[[:space:]]*"project_id"[[:space:]]*:[[:space:]]*"([^"\\]*)"[[:space:]]*,[[:space:]]*$'
# The alias payload is JSON string content: either an escape (backslash + one char, whose
# legality _mf_unescape_alias then decides) or any character that is neither a quote nor a
# backslash. A bare `(.*)` accepted `"a"b"`, which is not a JSON string at all.
_MF_L4='^[[:space:]]*"project_alias"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"[[:space:]]*,[[:space:]]*$'
# The read list is a real JSON array of integers: N (',' N)* — the old [0-9, ]* also
# accepted a trailing comma, and the canonicalising rewrite then hid the damage.
_MF_L5='^[[:space:]]*"schemas"[[:space:]]*:[[:space:]]*\{[[:space:]]*"read"[[:space:]]*:[[:space:]]*\[([0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*)\][[:space:]]*,[[:space:]]*"write"[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*"min_reader"[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]*\}[[:space:]]*,[[:space:]]*$'
_MF_L6='^[[:space:]]*"publisher_version"[[:space:]]*:[[:space:]]*"([^"\\]*)"[[:space:]]*$'
_MF_L7='^[[:space:]]*\}[[:space:]]*$'

# _mf_unescape_alias <raw> — decode ONLY the escapes we emit. Anything else (\u, \n, …)
# is refused rather than passed through: accepting "\u0061" and then re-emitting it
# literally would change what the alias MEANS across a re-run.
_mf_unescape_alias() {
  local raw="$1" out="" i c n
  n=${#raw}
  for (( i=0; i<n; i++ )); do
    c="${raw:$i:1}"
    if [ "$c" = "\\" ]; then
      i=$((i+1)); c="${raw:$i:1}"
      case "$c" in
        '"'|"\\") out="$out$c" ;;
        *) _mf_err "project_alias uses the escape \\$c, which this codec does not accept"; return 1 ;;
      esac
    else
      out="$out$c"
    fi
  done
  printf '%s' "$out"
}

# manifest_read_strict <file> — parse and validate. Sets MF_*; returns:
#   0 ok   1 malformed/corrupt   3 written by NEWER tooling (caller must not downgrade)
manifest_read_strict() {
  local f="$1" lines n loose_schema loose_ver vc rd wr i
  [ -r "$f" ] || { _mf_err "cannot read $f"; return 1; }
  # Before ANY read into a shell string, for the reason above.
  if _mf_file_has_nul "$f"; then
    _mf_err "$f: contains a NUL byte — refusing (no JSON parser would read this file)"
    return 1
  fi

  # Stage 1, deliberately lenient: is this simply NEWER than us? That is a refusal to
  # downgrade, not a parse failure, and it has to be decided before the strict grammar
  # rejects fields a future version legitimately added.
  loose_schema="$(sed -n 's/.*"manifest_schema"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" 2>/dev/null | head -1 || true)"
  loose_ver="$(sed -n 's/.*"publisher_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1 || true)"
  if [ -n "$loose_schema" ] && [ "$loose_schema" -gt "$MANIFEST_SCHEMA_LATEST" ] 2>/dev/null; then
    _mf_err "$f: manifest_schema $loose_schema is newer than this tooling understands ($MANIFEST_SCHEMA_LATEST)"
    return 3
  fi
  if [ -n "$loose_ver" ] && [[ "$loose_ver" =~ $MF_VERSION_RE ]] && [ -n "${MF_OUR_VERSION:-}" ]; then
    vc=0; _mf_version_cmp "$loose_ver" "$MF_OUR_VERSION" || vc=$?
    if [ "$vc" -eq 1 ]; then
      _mf_err "$f: recorded publisher_version $loose_ver is newer than this tooling (${MF_OUR_VERSION}) — refusing to downgrade it"
      return 3
    fi
  fi

  # Stage 2: the whole-file grammar. Exactly seven lines, each anchored.
  lines=(); n=0
  while IFS= read -r l || [ -n "$l" ]; do
    [ -n "${l//[[:space:]]/}" ] || continue
    lines[$n]="$l"; n=$((n+1))
  done < "$f"
  if [ "$n" -ne 7 ]; then
    _mf_err "$f: expected the canonical 7-line manifest object, found $n significant lines"
    return 1
  fi
  [[ "${lines[0]}" =~ $_MF_L1 ]] || { _mf_err "$f: does not open with a JSON object (a root array or prose is not a manifest)"; return 1; }
  [[ "${lines[6]}" =~ $_MF_L7 ]] || { _mf_err "$f: does not close with a lone }"; return 1; }

  [[ "${lines[1]}" =~ $_MF_L2 ]] || { _mf_err "$f: manifest_schema must be a bare integer on its own line"; return 1; }
  MF_MANIFEST_SCHEMA="${BASH_REMATCH[1]}"
  [[ "${lines[2]}" =~ $_MF_L3 ]] || { _mf_err "$f: project_id must be a plain JSON string"; return 1; }
  MF_PROJECT_ID="${BASH_REMATCH[1]}"
  [[ "${lines[3]}" =~ $_MF_L4 ]] || { _mf_err "$f: project_alias must be a JSON string"; return 1; }
  MF_PROJECT_ALIAS="$(_mf_unescape_alias "${BASH_REMATCH[1]}")" || return 1
  [[ "${lines[4]}" =~ $_MF_L5 ]] || { _mf_err "$f: schemas must be { read: [...], write: N, min_reader: N }"; return 1; }
  rd="$(printf '%s' "${BASH_REMATCH[1]}" | tr -d ' ')"
  wr="${BASH_REMATCH[3]}"; MF_MIN_READER="${BASH_REMATCH[4]}"
  [[ "${lines[5]}" =~ $_MF_L6 ]] || { _mf_err "$f: publisher_version must be a plain JSON string on the last field line"; return 1; }
  MF_PUBLISHER_VERSION="${BASH_REMATCH[1]}"

  # Stage 3: semantics.
  [ "$MF_MANIFEST_SCHEMA" = "$MANIFEST_SCHEMA_LATEST" ] \
    || { _mf_err "$f: manifest_schema $MF_MANIFEST_SCHEMA is not a supported discriminator (expected $MANIFEST_SCHEMA_LATEST)"; return 1; }
  [[ "$MF_PROJECT_ID" =~ ^[0-7][0-9A-HJKMNP-TV-Z]{25}$ ]] \
    || { _mf_err "$f: project_id '$MF_PROJECT_ID' is not a ULID"; return 1; }
  [[ "$MF_PUBLISHER_VERSION" =~ $MF_VERSION_RE ]] \
    || { _mf_err "$f: publisher_version '$MF_PUBLISHER_VERSION' is not a version"; return 1; }
  [ -n "$rd" ] || { _mf_err "$f: schemas.read is empty"; return 1; }
  case ",$rd," in
    *",$MF_MIN_READER,"*) : ;;
    *) _mf_err "$f: schemas.min_reader ($MF_MIN_READER) is not in schemas.read [$rd]"; return 1 ;;
  esac

  # Capability recorded beyond what this tooling supports means the file came from
  # something newer; refreshing it would quietly REMOVE capability.
  for i in ${rd//,/ }; do
    case ",$MF_TOOLING_READ," in
      *",$i,"*) : ;;
      *) _mf_err "$f: schemas.read lists $i, which this tooling does not support — refusing to downgrade it"; return 3 ;;
    esac
  done
  case ",$MF_TOOLING_WRITE," in
    *",$wr,"*) : ;;
    *) _mf_err "$f: schemas.write is $wr, which this tooling could not have produced — refusing to overwrite it"; return 3 ;;
  esac
  return 0
}

# manifest_render <project_id> <alias> <read-list> <write> <min_reader> <version>
manifest_render() {
  printf '{\n'
  printf '  "manifest_schema": %s,\n' "$MANIFEST_SCHEMA_LATEST"
  printf '  "project_id": "%s",\n' "$1"
  printf '  "project_alias": "%s",\n' "$(_mf_json_escape "$2")"
  printf '  "schemas": { "read": [%s], "write": %s, "min_reader": %s },\n' "$3" "$4" "$5"
  printf '  "publisher_version": "%s"\n' "$6"
  printf '}\n'
}

# manifest_json_check <file> — optional strengthening when a JSON parser is installed.
# Distinguishes "parser rejected it" from "no usable parser", like the envelope check.
manifest_json_check() {
  local f="$1" out
  if command -v ruby >/dev/null 2>&1; then
    out="$(ruby -rjson -e '
      begin; JSON.parse(File.read(ARGV[0])); puts "MF_JSON_OK"
      rescue => e; puts "MF_JSON_BAD: #{e.message.lines.first.to_s.strip}"; end' "$f" 2>/dev/null)"
  elif command -v python3 >/dev/null 2>&1; then
    out="$(python3 -c '
import sys, json
try:
    json.load(open(sys.argv[1])); print("MF_JSON_OK")
except Exception as e: print("MF_JSON_BAD: %s" % str(e).splitlines()[0])' "$f" 2>/dev/null)"
  fi
  case "${out:-}" in
    MF_JSON_BAD*) _mf_err "$f: ${out#MF_JSON_BAD: }"; return 1 ;;
  esac
  return 0
}

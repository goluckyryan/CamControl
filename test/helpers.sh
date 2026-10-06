#!/usr/bin/env bash
# Minimal assert helpers. Each test script sources this, runs asserts, and
# exits with the number of failures; run-all.sh sums them.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$ROOT/test/data/$(basename "${BASH_SOURCE[1]:-scratch}" .sh)"
BIN="$ROOT/bin"

FAILS=0
if [[ -t 1 ]]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
else G=""; R=""; Y=""; D=""; O=""; fi

_pass() { printf '  %sok%s   %s\n' "$G" "$O" "$1"; }
_fail() { printf '  %sFAIL%s %s\n' "$R" "$O" "$1"; FAILS=$((FAILS + 1)); }
skip()  { printf '  %sskip%s %s\n' "$Y" "$O" "$1"; }
note()  { printf '       %s%s%s\n' "$D" "$1" "$O"; }

banner() { printf '\n%s\n' "$1"; }

assert_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then _pass "$3"; else _fail "$3"; note "expected '$1', got '$2'"; fi
}

assert_contains() { # haystack needle label
  if [[ "$1" == *"$2"* ]]; then _pass "$3"; else _fail "$3"; note "missing '$2'"; fi
}

assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then _pass "$3"; else _fail "$3"; note "unexpectedly found '$2'"; fi
}

assert_ok() { # label cmd...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then _pass "$label"; else _fail "$label"; note "command failed: $*"; fi
}

assert_fails() { # label cmd...   (expects a non-zero exit)
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then _fail "$label"; note "expected failure but it succeeded: $*"; else _pass "$label"; fi
}

assert_file() { [[ -f "$1" ]] && _pass "$2" || { _fail "$2"; note "no such file: $1"; }; }

assert_count() { # expected dir glob label
  local n; n="$(find "$2" -maxdepth 1 -name "$3" 2>/dev/null | wc -l)"
  assert_eq "$1" "$n" "$4"
}

fresh_scratch() { rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"; }

have_camera() { "$BIN/cameras" >/dev/null 2>&1; }

# Probe one field out of a media file.
probe() { ffprobe -v error -select_streams v:0 -show_entries "$1" -of default=nw=1:nk=1 "$2"; }

finish() {
  if (( FAILS )); then printf '\n%s%d failure(s)%s\n' "$R" "$FAILS" "$O"
  else printf '\n%sall passed%s\n' "$G" "$O"; fi
  exit "$FAILS"
}

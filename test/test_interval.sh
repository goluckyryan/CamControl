#!/usr/bin/env bash
# The interval is a parameter, and its bounds are enforced.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
banner "interval validation"

for bad in 0.5 0 -5 abc ""; do
  assert_fails "rejects --interval '${bad:-<empty>}'" "$BIN/capture" --interval "$bad" --duration 1 --name iv_bad
done

# 1.5s is legal but close enough to the 1s filename resolution to warn.
out="$("$BIN/capture" --interval 1.5 --duration 1 --name iv_warn_$$ 2>&1 || true)"
assert_contains "$out" "warning" "warns below 2s"
rm -rf "$ROOT/sessions/iv_warn_$$"

# Durations must be whole seconds.
assert_fails "rejects a fractional --duration" "$BIN/capture" --duration 1.5 --name iv_dur

banner "run.sh time units"
rs="$ROOT/run.sh"
sec() { "$rs" -t "$1" -n 2>/dev/null | grep -oP -- '--interval \K[0-9.]+'; }

assert_eq "10"   "$(sec 10s)"  "10s is ten seconds"
assert_eq "660"  "$(sec 11m)"  "11m is eleven minutes"
assert_eq "3600" "$(sec 1h)"   "1h is one hour"
assert_eq "90"   "$(sec 90)"   "a bare number is read as seconds"
assert_eq "90"   "$(sec 1.5m)" "a fractional minute resolves"
assert_eq "7200" "$(sec 2H)"   "the unit is case-insensitive"
assert_eq "1800" "$(sec 0.5h)" "half an hour"

for bad in 10x abc 1d -5s ""; do
  assert_fails "rejects -t '${bad:-<empty>}'" "$rs" -t "$bad" -n
done

# The floor still belongs to capture, so it applies however the time was written.
assert_contains "$("$rs" -t 0.5s --duration 1 2>&1 || true)" "at least 1 second" \
  "an interval under a second is refused whatever the unit"

# Everything that is not -t is capture's business.
assert_contains "$("$rs" -t 1h -n --name passthru --duration 60 -b 2>/dev/null)" "--name passthru --duration 60 -b" \
  "other options are handed to capture untouched"

finish

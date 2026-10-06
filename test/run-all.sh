#!/usr/bin/env bash
# Run every test_*.sh and sum the failures. Exits non-zero if any test failed.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ -t 1 ]]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; O=$'\033[0m'
else G=""; R=""; B=""; O=""; fi

total=0; ran=0
for t in test_*.sh; do
  [[ -f "$t" ]] || continue
  bash "$t"
  total=$((total + $?)); ran=$((ran + 1))
done

printf '\n%s%s%s\n' "$B" "----------------------------------------" "$O"
if (( total )); then
  printf '%s%d failure(s) across %d test file(s)%s\n' "$R" "$total" "$ran" "$O"
else
  printf '%s%d test file(s), all passed%s\n' "$G" "$ran" "$O"
fi
exit $(( total > 0 ))

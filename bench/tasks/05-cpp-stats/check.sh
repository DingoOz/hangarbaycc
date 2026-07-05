#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
g++ -std=c++17 -Wall -Wextra -o "$dir/prog" "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }
out="$(printf '3 1 4 1 5' | timeout 10 "$dir/prog")" || { echo "RUN FAIL"; exit 1; }
[[ "$out" == "sum=14 min=1 max=5 mean=2.80" ]] \
  || { echo "OUTPUT MISMATCH: got '$out'"; exit 1; }
out2="$(printf -- '-2 7' | timeout 10 "$dir/prog")" || { echo "RUN FAIL (case 2)"; exit 1; }
[[ "$out2" == "sum=5 min=-2 max=7 mean=2.50" ]] \
  || { echo "OUTPUT MISMATCH (case 2): got '$out2'"; exit 1; }
echo PASS

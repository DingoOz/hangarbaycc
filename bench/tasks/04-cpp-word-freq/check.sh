#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
g++ -std=c++17 -Wall -Wextra -o "$dir/prog" "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }
out="$(printf 'apple banana apple cherry banana apple' | timeout 10 "$dir/prog")" \
  || { echo "RUN FAIL"; exit 1; }
expected=$'apple 3\nbanana 2\ncherry 1'
[[ "$out" == "$expected" ]] || { echo "OUTPUT MISMATCH: got '$out'"; exit 1; }
echo PASS

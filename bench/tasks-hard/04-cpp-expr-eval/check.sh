#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
g++ -std=c++17 -Wall -Wextra -o "$dir/prog" "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }

input=$'2+3*4\n(2+3)*-4\n7--3\n-(3+4)%5\n100/7/2\n2 * (3 + (4 - 1))\n1-2-3\n-2*-2\n'
expect=$'14\n-20\n10\n-2\n7\n12\n-4\n4\n'
printf '%s' "$input" | timeout 10 "$dir/prog" >"$dir/out" 2>"$dir/err" \
  || { echo "RUN FAIL: $(head -1 "$dir/err")"; exit 1; }
printf '%s' "$expect" | diff -q - "$dir/out" >/dev/null \
  || { echo "OUTPUT MISMATCH: got '$(tr '\n' '|' < "$dir/out")' want '14|-20|10|-2|7|12|-4|4|'"; exit 1; }
echo PASS

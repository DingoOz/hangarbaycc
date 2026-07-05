#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
gcc -Wall -Wextra -o "$dir/prog" "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }
out="$(timeout 10 "$dir/prog")" || { echo "RUN FAIL"; exit 1; }
[[ "$out" == "1 3 5 7 9" ]] || { echo "OUTPUT MISMATCH: got '$out'"; exit 1; }
grep -q 'malloc' "$src" || { echo "NO MALLOC: not a real linked list"; exit 1; }
echo PASS

#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
gcc -Wall -Wextra -o "$dir/prog" "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }
out="$(printf 'a,"b,c",d\n' | timeout 10 "$dir/prog")" || { echo "RUN FAIL"; exit 1; }
expected=$'a\nb,c\nd'
[[ "$out" == "$expected" ]] || { echo "OUTPUT MISMATCH: got '$out'"; exit 1; }
out2="$(printf 'x,y,z\n' | timeout 10 "$dir/prog")" || { echo "RUN FAIL (case 2)"; exit 1; }
expected2=$'x\ny\nz'
[[ "$out2" == "$expected2" ]] || { echo "OUTPUT MISMATCH (case 2): got '$out2'"; exit 1; }
echo PASS

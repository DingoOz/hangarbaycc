#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
python3 -m py_compile "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }
out="$(timeout 10 python3 "$src" 2>"$dir/err")" \
  || { echo "RUN FAIL: $(tail -1 "$dir/err")"; exit 1; }
exp=$'1\n-1\n-1\n3\n4\n30'
[[ "$out" == "$exp" ]] || { echo "OUTPUT MISMATCH: got '$(printf '%s' "$out" | tr '\n' '|')' want '1|-1|-1|3|4|30'"; exit 1; }
echo PASS

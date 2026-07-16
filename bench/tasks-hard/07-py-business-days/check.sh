#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
python3 -m py_compile "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }

input=$'2026-07-06 2026-07-13\n2026-07-11 2026-07-12\n2026-07-10 2026-07-11\n2026-07-10 2026-07-10\n2026-01-01 2027-01-01\n2026-07-13 2026-07-06\n2000-01-03 2000-01-31\n'
expect=$'5\n0\n1\n0\n261\n0\n20\n'
printf '%s' "$input" | timeout 10 python3 "$src" >"$dir/out" 2>"$dir/err" \
  || { echo "RUN FAIL: $(tail -1 "$dir/err")"; exit 1; }
printf '%s' "$expect" | diff -q - "$dir/out" >/dev/null \
  || { echo "OUTPUT MISMATCH: got '$(tr '\n' '|' < "$dir/out")' want '5|0|1|0|261|0|20|'"; exit 1; }
echo PASS

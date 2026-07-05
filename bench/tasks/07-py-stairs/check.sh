#!/usr/bin/env bash
set -u
src="$1"
python3 -m py_compile "$src" 2>/dev/null || { echo "SYNTAX FAIL"; exit 1; }
out="$(timeout 10 python3 "$src")" || { echo "RUN FAIL (or too slow)"; exit 1; }
[[ "$out" == "744861131" ]] || { echo "OUTPUT MISMATCH: got '$out'"; exit 1; }
echo PASS

#!/usr/bin/env bash
set -u
src="$1"
python3 -m py_compile "$src" 2>/dev/null || { echo "SYNTAX FAIL"; exit 1; }
out="$(timeout 10 python3 "$src")" || { echo "RUN FAIL"; exit 1; }
expected=$'[3, 4, 5]\n3\n[\x27a\x27]\n1'
[[ "$out" == "$expected" ]] || { echo "OUTPUT MISMATCH: got '$out'"; exit 1; }
echo PASS

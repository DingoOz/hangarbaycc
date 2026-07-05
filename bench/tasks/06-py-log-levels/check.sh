#!/usr/bin/env bash
set -u
src="$1"
python3 -m py_compile "$src" 2>/dev/null || { echo "SYNTAX FAIL"; exit 1; }
input=$'INFO: started\nERROR: bad thing\nINFO: still going\nWARN: look out\nERROR: worse thing\nnot a log line\n'
out="$(printf '%s' "$input" | timeout 10 python3 "$src")" || { echo "RUN FAIL"; exit 1; }
expected=$'ERROR=2\nINFO=2\nWARN=1'
[[ "$out" == "$expected" ]] || { echo "OUTPUT MISMATCH: got '$out'"; exit 1; }
echo PASS

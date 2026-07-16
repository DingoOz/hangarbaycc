#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
python3 -m py_compile "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }
if grep -qE '^[^#]*\bimport csv\b|^[^#]*\bfrom csv\b' "$src"; then
  echo "USED csv MODULE (forbidden by the prompt)"; exit 1
fi

t=0
run() { # input expected
  t=$((t+1))
  printf '%s\n' "$1" | timeout 10 python3 "$src" >"$dir/out" 2>"$dir/err" \
    || { echo "CASE $t RUN FAIL: $(tail -1 "$dir/err")"; exit 1; }
  printf '%s' "$2" | diff -q - "$dir/out" >/dev/null \
    || { echo "CASE $t MISMATCH: got '$(tr '\n' '|' < "$dir/out")'"; exit 1; }
}

run 'a,"b""c",,"d,e",'   $'a\nb"c\n\nd,e\n\n'
run 'plain,fields,here'  $'plain\nfields\nhere\n'
run '""'                 $'\n'
run '"x,y",z'            $'x,y\nz\n'
run '"has ""both"", see",tail' $'has "both", see\ntail\n'
echo PASS

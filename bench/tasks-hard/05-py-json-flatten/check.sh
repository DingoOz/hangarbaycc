#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
python3 -m py_compile "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }

t=0
run() { # input expected
  t=$((t+1))
  printf '%s' "$1" | timeout 10 python3 "$src" >"$dir/out" 2>"$dir/err" \
    || { echo "CASE $t RUN FAIL: $(tail -1 "$dir/err")"; exit 1; }
  printf '%s' "$2" | diff -q - "$dir/out" >/dev/null \
    || { echo "CASE $t MISMATCH: got '$(tr '\n' '|' < "$dir/out")'"; exit 1; }
}

run '{"b": 1, "a": {"c": [true, {"d": "x"}], "e": {}}}' \
    $'a.c[0]=true\na.c[1].d="x"\nb=1\n'
run '{"n": null, "arr": [1, 2, [3]], "s": "hi there"}' \
    $'arr[0]=1\narr[1]=2\narr[2][0]=3\nn=null\ns="hi there"\n'
run '{"x": 1.5, "y": -0.25, "z": false, "w": []}' \
    $'x=1.5\ny=-0.25\nz=false\n'
run '{}' ''
echo PASS

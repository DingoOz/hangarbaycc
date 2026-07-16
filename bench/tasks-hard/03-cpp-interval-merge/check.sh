#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
g++ -std=c++17 -Wall -Wextra -o "$dir/prog" "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }

t=0
run() { # input expected
  t=$((t+1))
  printf '%s' "$1" | timeout 10 "$dir/prog" >"$dir/out" 2>"$dir/err" \
    || { echo "CASE $t RUN FAIL: $(head -1 "$dir/err")"; exit 1; }
  printf '%s' "$2" | diff -q - "$dir/out" >/dev/null \
    || { echo "CASE $t MISMATCH: got '$(tr '\n' '|' < "$dir/out")'"; exit 1; }
}

run $'5 7\n1 3\n2 4\n'            $'1 4\n5 7\n'
run $'1 3\n3 5\n10 12\n'          $'1 5\n10 12\n'
run $'1 10\n2 3\n4 5\n'           $'1 10\n'
run $'-5 -2\n-3 0\n1 2\n'         $'-5 0\n1 2\n'
run $'42 42\n'                    $'42 42\n'
run $'1 2\n4 5\n3 3\n'            $'1 2\n3 3\n4 5\n'
echo PASS

#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
gcc -Wall -Wextra -o "$dir/prog" "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }

t=0
run() { # expected_output expected_rc args...
  t=$((t+1)); local exp="$1" rc_exp="$2"; shift 2
  local out rc
  out="$(timeout 10 "$dir/prog" "$@")"; rc=$?
  [[ "$out" == "$exp" && "$rc" == "$rc_exp" ]] \
    || { echo "CASE $t MISMATCH (args: $*): got '$out' rc=$rc, want '$exp' rc=$rc_exp"; exit 1; }
}

run "14" 0  3 4 + 2 '*'
run "14" 0  5 1 2 + 4 '*' + 3 -
run "-3" 0  -7 2 /
run "3"  0  10 3 /
run "error: division by zero" 1  4 0 /
run "error: stack underflow"  1  1 +
run "error: leftover operands" 1  1 2
run "error: leftover operands" 1
run "error: bad token 'x'" 1  2 x '*'
echo PASS

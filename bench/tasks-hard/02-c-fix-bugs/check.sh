#!/usr/bin/env bash
set -u
src="$1"; dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
gcc -Wall -Wextra -fsanitize=address,undefined -o "$dir/prog" "$src" 2>"$dir/warn" \
  || { echo "COMPILE FAIL: $(head -1 "$dir/warn")"; exit 1; }
out="$(timeout 10 "$dir/prog" 2>&1)" \
  || { echo "RUN FAIL (sanitizer or crash): $(printf '%s' "$out" | grep -m1 -oE 'ERROR: [A-Za-z]+Sanitizer[^(]*' || echo nonzero exit)"; exit 1; }
exp="$(printf 'delta\ngamma\nbeta\nalpha')"
[[ "$out" == "$exp" ]] || { echo "OUTPUT MISMATCH: got '$(printf '%s' "$out" | tr '\n' '|')'"; exit 1; }
echo PASS

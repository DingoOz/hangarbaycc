Write a complete Python 3 program that reads a single JSON document (always a
JSON object) from stdin and prints its leaf values as flattened
`path=value` lines.

Path rules:
- Object keys are joined with `.` — e.g. `{"a": {"b": 1}}` -> path `a.b`.
- Array elements append `[i]` directly to the parent path (no dot) —
  e.g. `{"a": [10, 20]}` -> paths `a[0]`, `a[1]`; nested arrays stack, e.g.
  `a[2][0]`.
- Keys never contain dots or brackets.

Value rules:
- A leaf is anything that is not a non-empty object or non-empty array.
- Render the value exactly as `json.dumps` would: strings quoted, booleans as
  `true`/`false`, `None` as `null`.
- Empty objects `{}` and empty arrays `[]` produce no output at all.

Sort the output lines lexicographically (plain string comparison of the whole
line).

Example: input `{"b": 1, "a": {"c": [true, {"d": "x"}], "e": {}}}` -> output:
```
a.c[0]=true
a.c[1].d="x"
b=1
```

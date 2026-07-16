Write a complete C++ program (C++17) that reads integer intervals from stdin —
one interval per line as two integers `a b` with `a <= b` — until EOF, merges
them, and prints the merged intervals sorted by start, one per line in the
same `a b` format.

Merging rule: two intervals merge when they overlap OR share an endpoint.
- `[1,3]` and `[3,5]` merge into `[1,5]` (shared endpoint).
- `[1,2]` and `[3,4]` do NOT merge (2 and 3 are different numbers — adjacency
  of consecutive integers is not enough).

Input order is arbitrary. Intervals may be negative, may be single points
(`a == b`), and may be entirely contained in one another.

Example: input
```
5 7
1 3
2 4
```
output
```
1 4
5 7
```

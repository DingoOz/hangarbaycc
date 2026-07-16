Write a complete Python 3 program that reads lines from stdin until EOF. Each
line holds two ISO dates: `YYYY-MM-DD YYYY-MM-DD` (start, then end).

For each line print one integer on its own line: the number of business days
(Monday through Friday) in the half-open range `[start, end)` — the start
date counts if it is a weekday, the end date never counts.

If end is on or before start, print `0`.

Examples:
- `2026-07-06 2026-07-13` (Monday to the next Monday) -> `5`
- `2026-07-11 2026-07-12` (Saturday to Sunday) -> `0`
- `2026-07-10 2026-07-10` -> `0`

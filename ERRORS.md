# Error Log

### gpt-oss Edit-tool failures from hot temp band and low Write threshold — 2026-07-11

- **Severity:** Medium
- **Category:** Configuration
- **File(s):** `hangarbaycc.sh`, `hangarbaycc-editing-rules.md`
- **Pattern:** Running a small local model at the top of its sampling band (temp up to 1.0) while the editing rules steer it to the Edit tool for mid-sized files (>150 lines) produces repeated `old_string` mismatch failures deep into a session — the model composes multi-line `old_string` from memory instead of copying from a fresh Read, and byte-exact recall degrades past ~70k tokens of context.
- **Root cause:** gpt-oss:20b's band was set to [0.90, 1.00] (its recommended sampling), and the Write-over-Edit threshold in the editing rules was ~150 lines, so a 212-line file forced the failure-prone Edit path at maximum entropy.
- **Fix applied:** Pinned gpt-oss:20b's temp band to [0.90, 0.90] in `hangarbaycc.sh` and raised the Write-over-Edit threshold in `hangarbaycc-editing-rules.md` from ~150 to ~400 lines.
- **Prevention rule:** When a local model loops on Edit failures, check (in order): the appended editing rules actually reached the model, the Write threshold covers the file being edited, and the temp ceiling — lower it toward the band floor before blaming the model. Verify any band change with 2–3 runs of `/hangarbaycc-bench`, not one interactive session.

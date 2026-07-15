# Error Log

### gpt-oss Edit-tool failures from hot temp band and low Write threshold — 2026-07-11

- **Severity:** Medium
- **Category:** Configuration
- **File(s):** `hangarbaycc.sh`, `hangarbaycc-editing-rules.md`
- **Pattern:** Running a small local model at the top of its sampling band (temp up to 1.0) while the editing rules steer it to the Edit tool for mid-sized files (>150 lines) produces repeated `old_string` mismatch failures deep into a session — the model composes multi-line `old_string` from memory instead of copying from a fresh Read, and byte-exact recall degrades past ~70k tokens of context.
- **Root cause:** gpt-oss:20b's band was set to [0.90, 1.00] (its recommended sampling), and the Write-over-Edit threshold in the editing rules was ~150 lines, so a 212-line file forced the failure-prone Edit path at maximum entropy.
- **Fix applied:** Pinned gpt-oss:20b's temp band to [0.90, 0.90] in `hangarbaycc.sh` and raised the Write-over-Edit threshold in `hangarbaycc-editing-rules.md` from ~150 to ~400 lines.
- **Prevention rule:** When a local model loops on Edit failures, check (in order): the appended editing rules actually reached the model, the Write threshold covers the file being edited, and the temp ceiling — lower it toward the band floor before blaming the model. Verify any band change with 2–3 runs of `/hangarbaycc-bench`, not one interactive session.

### Classifier context budget tuned for CPU carried over unchanged to GPU host, starving the model of its own judging criteria — 2026-07-15

- **Severity:** High
- **Category:** Configuration
- **File(s):** `hangarbaycc-proxy.py`
- **Pattern:** A latency-driven trim/timeout budget (`CLASSIFIER_CONTEXT_BUDGET_BYTES`, the classifier HTTP timeout) was tuned around one backend's constraint (ml-server's ~180-215 tok/s CPU prefill) and never revisited when the backend moved to a different host (gtx1070, GPU) with a different cost curve — the number kept the same *value* even though the *reason* it was chosen no longer applied, silently degrading correctness (96% of the real system prompt discarded) instead of just latency.
- **Root cause:** `CLASSIFIER_CONTEXT_BUDGET_BYTES = 8_000` trimmed Claude Code's real ~110KB auto-mode system prompt down to ~4KB every call, discarding nearly all of the actual judging criteria/instructions. The 3B model, given only a truncated head+tail fragment, produced free-text verdicts Claude Code's client couldn't parse into an allow/deny decision, surfacing as "Auto mode could not evaluate this action" (a distinct failure mode from an explicit deny) even for benign commands like compiling and running a freshly-written C file.
- **Fix applied:** Raised `CLASSIFIER_CONTEXT_BUDGET_BYTES` to 48,000 (preserves far more of the real prompt while keeping cold-prefill latency in a live-measured single-digit-to-teens-of-seconds band on the GTX 1070) and the classifier's proxy-side HTTP timeout from 45s to 90s to give the one-time per-session cold call headroom. Set `OLLAMA_NUM_PARALLEL=1` on the classifier's `ollama serve` (in `hangarbaycc.sh`) so sequential calls reliably land in the same slot and benefit from Ollama's prompt-prefix cache — live-confirmed: repeat calls with an identical system-prompt prefix drop from ~35-45s cold prefill to ~0.1s.
- **Prevention rule:** Any hardcoded latency/size budget whose value was derived from a specific backend's measured performance (tok/s, host, GPU/CPU) must be re-derived — not just left in place — when that backend changes. Grep the constant's own comment for the backend name/hardware it cites; if the backend named there no longer matches, the number needs a fresh live measurement, not an assumption that "it still works, just faster now."

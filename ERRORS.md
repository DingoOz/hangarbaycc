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

### Grok turn failure: max_completion_tokens too small for a thinking model — 2026-07-18

- **Severity:** Medium
- **Category:** Configuration
- **File(s):** `hangarbaycc.sh`, `~/.grok/config.toml`
- **Pattern:** A per-turn output-token cap (`max_completion_tokens = 8192`) was sized for a plain instruct model, but the model served (Qwen3.6-35B-A3B) is a thinking model whose reasoning tokens count against the same completion budget — long turns exhaust the cap mid-generation and the client (grok CLI) treats a `finish_reason: length` truncation as a hard turn failure ("response truncated by max_tokens", `max_tokens_truncation`), not a partial success.
- **Root cause:** The 8192 cap was written into the appended `[model.*]` config block without accounting for reasoning-token overhead; the script also only appends the block when absent, so an already-registered model never picks up corrected values from a fixed script.
- **Fix applied:** Raised `max_completion_tokens` to 32768 in the live `~/.grok/config.toml` and in both grok-backend heredocs in `hangarbaycc.sh` (grok and grok-local), well within the 131072/200000 context windows.
- **Prevention rule:** When configuring an output-token limit for a reasoning/thinking model, budget for reasoning tokens too — start at 4x what a plain instruct model would need. And remember the script's `[model.*]` blocks are write-once: after changing values in `hangarbaycc.sh`, also update (or delete and let the script re-append) the existing block in `~/.grok/config.toml`.

### virsh in a non-interactive SSH script defaults to qemu:///session, so the gtx1070 VM "does not exist" — 2026-07-20

- **Severity:** High
- **Category:** Configuration
- **File(s):** `~/vm-gtx1070/gtx1070.sh`, `~/vm-gtx1070/gtx1070-mgmt.sh` (on ml-server), consumed by `hangarbaycc.sh` grok backend → `grok-local/bin/start-gemma4-31b-3gpu.sh`
- **Pattern:** A helper script relies on an environment variable that only an *interactive login shell* sets (here `LIBVIRT_DEFAULT_URI`), then works when run by hand but fails when the same script is invoked non-interactively via `ssh host /path/script.sh`. `set -euo pipefail` turns the failure into a silent abort of the whole caller — the model server never starts and the only clue is one stray line of stderr in a log.
- **Root cause:** The gtx1070 VM is defined under `qemu:///system`, but plain `virsh` with no URI defaults to `qemu:///session` for a non-root user. Non-interactive SSH does not source the interactive shell rc that exports the URI, so `virsh start gtx1070` reported `error: failed to get domain 'gtx1070'` and `start-gemma4-31b-3gpu.sh` died at its `ensure_vm` step before ever reaching llama-server.
- **Fix applied:** Pinned `export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"` near the top of both `gtx1070.sh` and `gtx1070-mgmt.sh`, so the interactive and scripted paths resolve the same libvirt connection.
- **Prevention rule:** Any script that may be invoked over `ssh host script.sh` must not depend on login-shell environment (`LIBVIRT_DEFAULT_URI`, `DISPLAY`, `PATH` additions, `DOCKER_HOST`, virtualenv activation). Set the value explicitly inside the script with a `${VAR:-default}` fallback, and test the script with `ssh host /abs/path/script.sh` — not just interactively — before wiring it into an automated launcher.

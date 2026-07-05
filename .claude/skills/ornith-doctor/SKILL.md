---
name: ornith-doctor
description: Diagnose a local-model Claude Code session after the fact — inspect the Ollama and temp-proxy logs, VRAM/spill state, unload events, and malformed tool calls, then recommend setting changes. Use when a launch-ornith session was slow, looped, garbled, or errored.
---

# ornith-doctor

Post-session diagnosis for the launch-ornith stack. Work through this
checklist and report findings with a concrete recommendation for each.

## 1. Is anything still running, and where?

```bash
pgrep -ax ollama; pgrep -af ornith-temp-proxy
curl -sf http://127.0.0.1:11434/api/version && curl -s http://127.0.0.1:11434/api/ps
nvidia-smi --query-gpu=memory.total,memory.used --format=csv
```

In `/api/ps`, `size_vram < size` means CPU spill → recommend a smaller
context or more compressed KV cache (see the fit table in `launch-ornith.sh`).

## 2. Server log — /tmp/ollama-ornith.log

Look for:
- `offloaded X/Y layers to GPU` with X < Y → spill (same fix as above).
- repeated `loading model` / memory-layout lines mid-session → the model was
  unloaded and reloaded (each reload re-prefills the whole conversation).
  The launcher sets `OLLAMA_KEEP_ALIVE=-1`; if reloads still happen, something
  else restarted the server — check timestamps against systemd (`journalctl -u
  ollama`) and whether two servers fought over the port.
- context-shift / truncation messages → the conversation outgrew `num_ctx`;
  recommend a larger context choice next launch.
- HTTP 4xx/5xx on `/v1/messages` → API-level failures; correlate with the
  proxy log.

## 3. Proxy log — /tmp/ornith-temp-proxy.log

- The startup line shows the active band / top_p cap / strip list — confirm
  they match the model that was run (gpt-oss should be 0.9–1.0, others
  0.55–0.70).
- `stripped N tool schema(s)` — should appear once shortly after launch. If
  N is 0, Claude Code's tool names changed; update `DISALLOWED_TOOLS` in
  `launch-ornith.sh`.
- `relay error:` lines → upstream died or timed out mid-stream; check the
  server log at the same timestamp.

## 4. Behavioral symptoms → levers

| Symptom | Likely cause | Lever |
|---|---|---|
| Same action repeated across turns | temp band too cold | raise TEMP_FLOOR/CEIL a notch |
| Malformed / invented tool names | temp band too hot | lower TEMP_CEIL |
| Same line spammed within one reply | within-decode runaway | raise REPEAT_PENALTY in the proxy |
| Garbled output on qwen2.5-coder | fp16 KV instability | use q8_0 KV |
| Minutes-long stalls before replies | reload or re-prefill | check §2 unloads; keep server warm |
| Edit tool failures in a loop | old_string mismatches | editing rules already cover this; check the model actually received them (`--append-system-prompt` line in the launch output) |

## 5. Verify with data

After changing a setting, run `/ornith-bench` (see that skill) before and
after — 2–3 runs each — rather than judging from one interactive session.

---
name: hangarbaycc-doctor
description: Diagnose a local-model Claude Code session after the fact — inspect the Ollama and temp-proxy logs, VRAM/spill state, unload events, and malformed tool calls, then recommend setting changes. Use when a HangarBayCC session was slow, looped, garbled, or errored.
---

# hangarbaycc-doctor

Post-session diagnosis for the HangarBayCC stack. Work through this
checklist and report findings with a concrete recommendation for each.

## 0. Local or `--remote`?

If `hangarbaycc.sh` was launched with `--remote HOST`, the Ollama server
lives on HOST (SSH-managed) while the proxy and Claude Code run on the
machine you're diagnosing from. Everything below still applies — just run
the "server" checks (§1's `ollama`/GPU/`/tmp/ollama-hangarbaycc.log` bits) via
`ssh HOST ...` instead of directly, and note that `curl`/`ollama ps` from the
client naturally reach the remote server already (`OLLAMA_HOST` points at it).
The proxy and its log are always local, remote mode or not.

## 1. Is anything still running, and where?

```bash
# server-side (prefix with `ssh HOST` in --remote mode)
pgrep -ax ollama
curl -sf http://<API_HOST>/api/version && curl -s http://<API_HOST>/api/ps
nvidia-smi --query-gpu=memory.total,memory.used --format=csv   # on whichever host has the GPU

# client-side (always local, both modes)
pgrep -af hangarbaycc-proxy
```

`<API_HOST>` is `127.0.0.1:11434` in local mode, `HOST:11434` in `--remote`
mode. In `/api/ps`, `size_vram < size` means CPU spill → recommend a smaller
context or more compressed KV cache (see the fit table in `hangarbaycc.sh`).

## 2. Server log — /tmp/ollama-hangarbaycc.log

In `--remote` mode this file is on the remote host: `ssh HOST tail -50
/tmp/ollama-hangarbaycc.log`. Look for:
- `offloaded X/Y layers to GPU` with X < Y → spill (same fix as above).
- repeated `loading model` / memory-layout lines mid-session → the model was
  unloaded and reloaded (each reload re-prefills the whole conversation).
  The launcher sets `OLLAMA_KEEP_ALIVE=-1`; if reloads still happen, something
  else restarted the server — check timestamps against systemd (`journalctl -u
  ollama`) and whether two servers fought over the port.
- context-shift / truncation messages → the conversation outgrew `num_ctx`
  WITHOUT Claude Code compacting first. The launcher sets
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (via `--settings`) to the chosen context
  specifically to make Claude Code compact before this happens; if you see
  context-shift anyway, check `/context` inside the session for an
  "Auto-compact window: N tokens (from CLAUDE_CODE_AUTO_COMPACT_WINDOW)" line —
  if it's absent (or shows the default 200k), the `--settings` JSON didn't
  reach Claude Code. Also just recommend a larger context choice next launch.
- HTTP 4xx/5xx on `/v1/messages` → API-level failures; correlate with the
  proxy log.

## 3. Proxy log — /tmp/hangarbaycc-proxy.log

Every generation gets a summary line:
`POST /v1/messages -> 200 5.3s req=41200B resp=8100B stop=tool_use`.

- `<-- EMPTY RESPONSE` markers → the model produced no content block; a burst
  of these right before a session died is the smoking gun (correlate with the
  temp band and the last tool results in the conversation).
- `stop=max_tokens` on real requests → responses being truncated.
- Known failure mode (2026-07-05): Ollama 404s `/v1/messages/count_tokens`;
  Claude Code then falls back to probing with max_tokens=1 requests (shows up
  server-side as bursts of 1-token evals) and that path can kill the session
  with "There's an issue with the selected model". The proxy now serves
  count_tokens locally — if you see count_tokens 404s in the OLLAMA log, the
  traffic is bypassing the proxy.

- The startup line shows the active band / top_p cap / strip list — confirm
  they match the model that was run (gpt-oss should be 0.9–1.0, others
  0.55–0.70).
- `stripped N tool schema(s)` — should appear once shortly after launch. If
  N is 0, Claude Code's tool names changed; update `DISALLOWED_TOOLS` in
  `hangarbaycc.sh`.
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

After changing a setting, run `/hangarbaycc-bench` (see that skill) before
and after — 2–3 runs each — rather than judging from one interactive session.

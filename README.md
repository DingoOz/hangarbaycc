# launch-ornith

Launch [Claude Code](https://claude.com/claude-code) against a **local model**
served by [Ollama](https://ollama.com) on a 16 GB GPU (RTX 5060 Ti), tuned to
produce decent C / C++ / Python code.

## What it does

`launch-ornith.sh`:

1. Prompts for a model, context window (32K–256K), and KV cache precision
   (fp16 / q8_0 / q4_0). Each model carries its own max context and sampling
   band (see the verified fit table in the script header).
2. Finds which model store holds the chosen model (`/var/lib/ollama/models`
   or `~/.ollama/models`) and points the server at it.
3. Restarts the Ollama server with the chosen settings, pinned to
   `OLLAMA_NUM_PARALLEL=1` (the whole context goes to one stream) and
   `OLLAMA_KEEP_ALIVE=-1` (no idle unload — an unload forces a full re-prefill
   of the conversation, which takes minutes at 100K+ tokens).
4. Preloads the model and **verifies it is fully on the GPU** via `/api/ps`
   (`size_vram == size`); aborts with advice if the KV cache spilled to CPU.
5. Starts the request-rewriting proxy (`ornith-temp-proxy.py`) and points
   Claude Code at it.
6. Hands off to Claude Code with the editing/verification rules from
   `ornith-editing-rules.md` appended to the system prompt. When Claude Code
   exits, the proxy is killed; the server is left running so the model stays
   warm.

## Models

| menu | model | notes |
|---|---|---|
| 1 | `ornith:latest` | 9B, 5.6 GB — fits every ctx/KV combo up to 256K/f16; best agentic behavior |
| 2 | `gemma4:latest` | 8B Q4_K_M — max 128K context |
| 3 | `qwen2.5-coder:14b` | strong raw coder, native 32K only; prefer q8_0 KV (fp16 KV can garble) |
| 4 | `gpt-oss:20b` | 20B MoE, ~12 GB — strongest C/C++/Python + tool calling; max 128K; use q8_0 KV (f16 KV spills beyond 32K) |

## The proxy (ornith-temp-proxy.py)

A transparent reverse proxy between Claude Code and Ollama that rewrites every
`/v1/messages` request:

- **Temperature band.** Claude Code sends `temperature: 1.0` and has no flag to
  change it; Ollama honours the request over the Modelfile. The proxy clamps
  temperature into a per-model band (default `0.55–0.70`). A band, not a single
  low value: pinned-low sampling makes a small model fall into agentic
  repetition loops; a band keeps enough entropy to escape them while still
  cutting malformed tool calls. gpt-oss's band is `0.9–1.0` — its recommended
  sampling *is* temp 1.0, so the clamp is a no-op there.
- **Tool stripping.** `--disallowedTools` only auto-denies calls at execution
  time — the model still sees the schemas and still tries. The proxy removes
  `Agent`, `Workflow`, `WebFetch`, `WebSearch`, `NotebookEdit` (and legacy
  `Task`) from the `tools` array, so the model never sees them: no hallucinated
  subagent calls, and thousands of schema tokens freed for code context.
  `--disallowedTools` stays on as a backstop.
- **Anti-repetition.** Injects `repeat_penalty`/`repeat_last_n` to suppress
  within-one-reply runaways, and caps `top_p`.

The launcher also forces `CLAUDE_CODE_SUBAGENT_MODEL=inherit` (via
`--settings`, scoped to the launched session) so a stray subagent spawn reuses
the local model instead of erroring on an unreachable `sonnet` alias.

## The editing & verification rules

`ornith-editing-rules.md` is appended to the system prompt. It steers a small
model toward Write-over-Edit, byte-exact `old_string` matching — and a verify
protocol: compile everything with `gcc/g++ -Wall -Wextra`, run it, run
`py_compile`/`pytest` for Python, and stop after 3 failed fix attempts instead
of thrashing.

## Benchmarking (bench/)

`bench/run-bench.sh MODEL [HOSTPORT]` runs 8 fixed C/C++/Python tasks against
the model (optionally through the proxy to measure a temp band), mechanically
checks the results (compile, run, exact output), and writes a scorecard to
`bench/results/`. Use it to compare models and settings with data instead of
vibes.

Baseline (2026-07-05, raw model sampling, single run each): `gpt-oss:20b`
**8/8**; `ornith:latest` **4/8** (0/3 on the C tasks). For C/C++ work, pick
gpt-oss. See `.claude/skills/ornith-bench/` — in a cloud Claude Code session in
this repo, `/ornith-bench` runs it and `/ornith-doctor` diagnoses a bad
session from the logs.

## Usage

```bash
./launch-ornith.sh
```

Afterwards, `sudo systemctl start ollama` restores the system Ollama service
if you want it back.

## Requirements

- `ollama` ≥ 0.30 (with `ollama launch claude` integration)
- `nvidia-smi` / an NVIDIA GPU (tables measured on an RTX 5060 Ti 16 GB)
- Claude Code, `python3`, `gcc`/`g++` (for the bench checks)

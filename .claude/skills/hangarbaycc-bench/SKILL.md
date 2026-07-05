---
name: hangarbaycc-bench
description: Benchmark a local Ollama model on the C/C++/Python task set and produce a pass/fail scorecard. Use when comparing models (ornith, gemma4, qwen2.5-coder, gpt-oss), context/KV settings, or temperature bands for the HangarBayCC tooling — data instead of vibes.
---

# hangarbaycc-bench

Runs `bench/run-bench.sh`: for each task in `bench/tasks/*/` it sends one
prompt to the model's Anthropic-compat endpoint, extracts the fenced code
block from the reply, and runs the task's `check.sh` (compile with
`-Wall -Wextra`, run, compare exact output). Scorecards land in
`bench/results/` (gitignored).

## How to run

1. Make sure an Ollama server is up with the settings you want to measure.
   Either `./hangarbaycc.sh` already started one, or start one manually:

   ```bash
   pkill -x ollama; sleep 2
   OLLAMA_FLASH_ATTENTION=1 OLLAMA_CONTEXT_LENGTH=32768 \
     OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_NUM_PARALLEL=1 OLLAMA_KEEP_ALIVE=-1 \
     OLLAMA_MODELS=/var/lib/ollama/models OLLAMA_HOST=127.0.0.1:11434 \
     nohup ollama serve >/tmp/ollama-bench.log 2>&1 &
   ```

   Do NOT kill a server that is mid-download (check `ls <store>/blobs/*partial*`).

2. Bench the raw model (its own default sampling):

   ```bash
   bench/run-bench.sh ornith:latest
   ```

3. Or bench THROUGH the temp proxy to measure a specific temperature band /
   tool-strip config (this is how the launched sessions actually run):

   ```bash
   python3 hangarbaycc-proxy.py 11435 127.0.0.1:11434 0.55 0.70 0.95 "" &
   bench/run-bench.sh ornith:latest 127.0.0.1:11435
   kill %1
   ```

## Interpreting results

- Sampling is stochastic: run each configuration 2–3 times before concluding
  anything from a 1-task difference. Report the range, not one run.
- `NO CODE` failures mean the model ignored the "one fenced block" instruction
  — a formatting/instruction-following problem, not a coding one. Frequent
  `NO CODE` at a temp band is itself a finding (band too hot).
- Task time includes model load on the first task — ignore the first task's
  time or preload the model before benching.
- When comparing bands or models, keep everything else fixed (ctx, KV, store).

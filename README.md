# launch-ornith

Launch [Claude Code](https://claude.com/claude-code) wired to a local **Ornith**
model served by [Ollama](https://ollama.com), with an fp16 KV cache and a large
context window.

## What it does

`launch-ornith.sh`:

1. Interactively prompts for a context window (32K/64K/128K/256K) and KV cache
   precision (fp16 / q8_0 / Q4_0).
2. Checks the GPU is healthy, restarts the Ollama server with the chosen
   settings, and preloads the model.
3. **Verifies the model is fully on the GPU** — if the KV cache spills to CPU it
   aborts and tells you to pick a smaller context / more compressed cache.
4. Starts a small temperature-clamping proxy (`ornith-temp-proxy.py`) and points
   Claude Code at it (see below).
5. Hands off to Claude Code, appending the editing rules in
   `ornith-editing-rules.md` to the system prompt.

## The temperature proxy

Claude Code sends `temperature: 1.0` on every request, and Ollama honours the
request value over the Modelfile. At temp 1.0 a 9B model emits far more malformed
and hallucinated tool calls (e.g. calling a nonexistent `Update` tool).
`ornith-temp-proxy.py` is a transparent reverse proxy: it forwards everything to
the real Ollama server unchanged except that it rewrites `temperature` down to
`$TARGET_TEMP` (default `0.4`). Tune `TARGET_TEMP` near the top of the script.

Verified on an RTX 5060 Ti (16 GB): 256K fp16 fits, 100% on GPU.

## The editing rules

Local models often fail Claude Code's `Edit` tool because `old_string` must
match the file byte-for-byte. `ornith-editing-rules.md` is appended to the
system prompt (via `ollama launch claude -- --append-system-prompt ...`) to
steer the model toward small, verbatim, copy-don't-reconstruct edits.

## Usage

```bash
./launch-ornith.sh
```

## Requirements

- `ollama` (with `ollama launch claude` integration support)
- `nvidia-smi` / an NVIDIA GPU
- Claude Code

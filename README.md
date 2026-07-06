# HangarBayCC

Launch [Claude Code](https://claude.com/claude-code) against a **local model**
served by [Ollama](https://ollama.com) on a 16 GB GPU (RTX 5060 Ti), tuned to
produce decent C / C++ / Python code. Multiple models sit in the "hangar";
`hangarbaycc.sh` preps and launches whichever one you pick, like a hangar bay
crewing up an aircraft before takeoff.

## What it does

`hangarbaycc.sh`:

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
5. Starts the request-rewriting proxy (`hangarbaycc-proxy.py`) and points
   Claude Code at it.
6. Hands off to Claude Code with the editing/verification rules from
   `hangarbaycc-editing-rules.md` appended to the system prompt. When Claude
   Code exits, the proxy is killed; the server is left running so the model
   stays warm.

## Models

| menu | model | notes |
|---|---|---|
| 1 | `ornith:latest` | 9B, 5.6 GB — fits every ctx/KV combo up to 256K/f16; best agentic behavior |
| 2 | `gemma4:latest` | 8B Q4_K_M — max 128K context |
| 3 | `qwen2.5-coder:14b` | strong raw coder, native 32K only; prefer q8_0 KV (fp16 KV can garble) |
| 4 | `gpt-oss:20b` | 20B MoE, ~12 GB — strongest C/C++/Python + tool calling; max 128K; use q8_0 KV (f16 KV spills beyond 32K) |

### Recommended configuration

**`gpt-oss:20b` at 128K context with `q8_0` KV cache** is the preferred setup.
It scored **8/8** on the C/C++/Python bench (vs 4/8 for the next best), and this
combination is the sweet spot: `q8_0` is near-lossless yet keeps the whole model
+ 128K KV on the 16 GB GPU (f16 KV spills to CPU beyond 32K on this model, and
q4_0 buys nothing here since q8_0 already fits). At the launcher prompts, pick:

- Model: **4** (`gpt-oss:20b`)
- Context: **3** (128K / 131072)
- KV cache: **2** (`q8_0`)

## The proxy (hangarbaycc-proxy.py)

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
- **count_tokens shim.** Ollama 404s `/v1/messages/count_tokens`, and Claude
  Code's fallback (max_tokens=1 probe requests) can error the whole session
  ("There's an issue with the selected model"). The proxy answers the route
  locally with a chars/4 estimate.
- **Diagnostics.** One summary line per generation (status, time, bytes,
  stop_reason, empty-response marker) in `/tmp/hangarbaycc-proxy.log`.

The launcher also forces `CLAUDE_CODE_SUBAGENT_MODEL=inherit` (via
`--settings`, scoped to the launched session) so a stray subagent spawn reuses
the local model instead of erroring on an unreachable `sonnet` alias.

## The context-window mismatch

Claude Code doesn't recognize a local Ollama model ID, so it assumes its
default 200K context window — regardless of what the model's real limit is.
That's more than cosmetic: auto-compaction is driven by that assumed window,
so with a 128K model it would never trigger before Ollama's server-side limit,
at which point llama-server silently context-shifts (drops the oldest
messages — including the appended editing rules) instead of Claude Code
compacting on purpose.

The launcher sets `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (via the same `--settings`
mechanism, pinned to the context you picked) so auto-compaction fires at the
real limit. `/context` then shows an accurate "Auto-compact window: `<N>`
tokens (from CLAUDE_CODE_AUTO_COMPACT_WINDOW)" line. The headline total at the
top of `/context` still reads 200k regardless — that part is hardcoded per
model ID with no override that doesn't *also* disable auto-compaction entirely
(`DISABLE_COMPACT` + `CLAUDE_CODE_MAX_CONTEXT_TOKENS` would fix the headline
number but turn compaction off outright — worse than a cosmetically wrong
number, so it isn't wired in here).

## The editing & verification rules

`hangarbaycc-editing-rules.md` is appended to the system prompt. It steers a
small model toward Write-over-Edit, byte-exact `old_string` matching — and a
verify protocol: compile everything with `gcc/g++ -Wall -Wextra`, run it, run
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
gpt-oss. See `.claude/skills/hangarbaycc-bench/` — in a cloud Claude Code
session in this repo, `/hangarbaycc-bench` runs it and `/hangarbaycc-doctor`
diagnoses a bad session from the logs.

## Usage

```bash
./hangarbaycc.sh
```

Afterwards, `sudo systemctl start ollama` restores the system Ollama service
if you want it back.

## Remote operation

Run the launcher from a laptop while the model runs on a GPU box elsewhere on
the LAN (e.g. `ml-server`):

```bash
./hangarbaycc.sh --remote ml-server
# or: HANGARBAY_REMOTE=ml-server ./hangarbaycc.sh
```

If you run `./hangarbaycc.sh` with no flag or env var, an interactive menu asks
whether to run locally or against a remote host, defaulting the host to
`ml-server` — so you can pick remote mode without remembering the flag.

The **Ollama server runs on the remote host** over SSH; the **proxy and Claude
Code stay on the laptop**, talking to the remote Ollama directly over the LAN
(`hangarbaycc-proxy.py`'s upstream just becomes `ml-server:11434` instead of
`127.0.0.1:11434` — the proxy code itself didn't need to change). Model
selection, context/KV prompts, the GPU-spill guard, and the editing rules all
work exactly as in local mode; only the server start/stop and the model-store
lookup happen over SSH.

**Prerequisites:**
- Laptop: this repo, the `ollama` CLI (client only — it doesn't need to run a
  local server), `claude`, `python3`, and SSH access to the remote host.
  Key-based auth is strongly preferred (`ssh-copy-id ml-server`) — a launch
  makes several separate SSH calls, which is painful to re-authenticate for
  each one with a password.
- Remote host: `ollama`, the models, an NVIDIA GPU, and (if the systemd
  `ollama` service is normally active) sudo access to stop/start it.

**Security note:** while a remote session runs, the remote host's Ollama binds
`0.0.0.0:11434` — reachable by *anything* on that LAN, not just your laptop.
Fine on a trusted home network; don't do this on a network you don't trust.
For access from outside the LAN, point `--remote` at a Tailscale IP instead of
the LAN hostname/IP — same mechanism, narrower reachability (only your
tailnet, instead of the whole LAN).

**Troubleshooting:** if the launcher times out waiting for the remote server,
check the remote host's firewall allows port 11434 from your subnet, and tail
`/tmp/ollama-hangarbaycc.log` there (`ssh ml-server tail -50
/tmp/ollama-hangarbaycc.log`). See `.claude/skills/hangarbaycc-doctor/` for a
fuller checklist — it covers remote-mode log locations too.

## Voice dictation (optional, remote mode only)

Press a hotkey, speak, press it again, and the transcript is typed into
whatever window is focused (normally the Claude Code TUI) — powered by
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) running on the GPU
host's spare VRAM. Only available with `--remote` (the laptop has no VRAM
budget of its own).

**One-time setup** (from the laptop, targets the GPU host over SSH):

```bash
./setup-whisper-server.sh ml-server
```

This clones and builds whisper.cpp with CUDA, downloads the `small.en q8_0`
model (~270 MB file, ~0.6 GB VRAM loaded), and runs a smoke test. On a
Blackwell card (e.g. RTX 5060 Ti) whose CUDA toolkit predates native `sm_120`
codegen, it builds with `-DCMAKE_CUDA_ARCHITECTURES=89-virtual` — PTX-only,
JIT-compiled by the driver at first load (a one-time delay, not a per-request
cost). If your toolkit is CUDA 12.8+, native `sm_120` codegen works too; the
script's PTX approach is just the safer default. Disk is often tight on a GPU
box — the script downloads exactly one model file, never speculatively pulls
multiple sizes, and aborts early if free space is under ~3 GB.

**Using it:**

```bash
./hangarbaycc.sh --remote ml-server --dictate
# or answer 'y' at the interactive "Enable voice dictation?" prompt
# or: HANGARBAY_DICTATE=1 ./hangarbaycc.sh --remote ml-server
```

The launcher starts `whisper-server` on the GPU host **after** confirming the
main model is 100% on GPU (never before — so dictation can only ever use
leftover VRAM, and the existing spill guard needs no changes to account for
it). If there isn't enough free VRAM (default threshold: 1000 MiB), it warns
and skips dictation rather than aborting the coding session.

Bind `hangarbay-dictate.sh` to a hotkey in your desktop environment (GNOME:
Settings → Keyboard → Custom Shortcuts; Sway/i3: a `bindsym`/`bindkey` line
running the script). First press starts recording; second press stops it,
sends the audio to whisper-server, and types the result:

```bash
hangarbay-dictate.sh                  # type into the focused window (default)
hangarbay-dictate.sh --stdout         # print the transcript instead
hangarbay-dictate.sh --clipboard      # copy it instead (wl-copy)
```

**Text injection caveat:** the default typing path tries `wtype` first, then
falls back to `ydotool`. GNOME's Wayland compositor (Mutter) does not
implement the virtual-keyboard protocol `wtype` needs, so on GNOME you'll
need `ydotool` — install it, start the `ydotoold` daemon, and make sure your
user can access `/dev/uinput` (an `input` group + udev rule, or run
`ydotoold` as a systemd service). If neither works, the transcript is copied
to the clipboard instead so nothing is lost.

**Security note:** like Ollama, `whisper-server` binds `0.0.0.0:11436` while
a dictation-enabled session runs — reachable, unauthenticated, by anything on
that LAN. Same trust posture as the rest of remote mode: fine on a trusted
home network, or point at a Tailscale IP for narrower reachability.

Left running on exit, same as Ollama (so the model stays warm and the JIT
cost isn't paid again); the next launch's cleanup step kills any stale
instance before starting a fresh one. Stop it by hand with:
`ssh ml-server pkill -x whisper-server`.

## Dependencies

Everything the launcher shells out to. On a single-machine setup all of these
live on one box; in `--remote` mode they split between the laptop (client) and
the GPU host (server) as noted.

**On the machine you run `hangarbaycc.sh` from (client):**
- **`bash`** ≥ 4 — the launcher uses `set -euo pipefail`, arrays, and `[[ ]]`.
- **`ollama`** CLI ≥ 0.30, with the `ollama launch claude` integration — used to
  hand off to Claude Code. In `--remote` mode this is the *client* only; it does
  not need to run a local server.
- **Claude Code** (`claude`) — installed and logged in, since `ollama launch
  claude` drives it.
- **`python3`** ≥ 3.8 — runs the request-rewriting proxy
  (`hangarbaycc-proxy.py`) and the GPU-spill check (stdlib only, no pip
  packages).
- **`curl`** — health checks and the preload probe.
- **`ssh`** — only for `--remote` (key-based auth strongly preferred; a launch
  makes several separate SSH calls).
- **For dictation only:** one of `pw-record` (pipewire-utils), `parecord`, or
  `arecord` to capture the mic; `wtype` and/or `ydotool` (+ `ydotoold`
  running) to type the transcript; optionally `wl-copy` (wl-clipboard) and
  `notify-send` for the clipboard fallback and status notifications.

**On the machine that hosts the model (server — the same box locally, or the
`--remote` host):**
- **NVIDIA GPU + `nvidia-smi`** — a health check aborts the launch if it fails.
  The fit tables were measured on an RTX 5060 Ti (16 GB); other cards work but
  the VRAM numbers will differ.
- **`ollama`** with `ollama serve`, plus the chosen model pulled into either
  `/var/lib/ollama/models` or `~/.ollama/models`.
- **`sudo`** — only if the systemd `ollama` service is normally active, to
  stop/restart it around the session.
- **For dictation only:** `git`, `cmake`, `gcc`/`g++`, and a CUDA **toolkit**
  (`nvcc` — Ollama bundles its own CUDA runtime and doesn't need this, so
  it's the one new build-time dependency); ~1–2 GB free disk under
  `~/whisper.cpp` for the build and model.

**For the benchmark (`bench/`) only:**
- **`gcc` / `g++`** — the bench compiles and runs the C/C++ tasks to score them.

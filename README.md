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

`launch-aider.sh` also supports a remote **meshllm** backend in addition to
these local Ollama models — see "Aider and the meshllm backend" below.

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

`run-bench.sh` also works against the meshllm backend (protocol is
auto-detected from a `meshllm/` model prefix):
`bench/run-bench.sh "meshllm/Qwen3-30B-A3B-Q4_K_M-layers" 192.168.1.16:9337`.

## Aider and the meshllm backend

`launch-aider.sh` can drive [Aider](https://aider.chat) against either a
local Ollama model (same picker as `hangarbaycc.sh`) or **meshllm**, a
remote, always-on, OpenAI-compatible LLM server on the LAN
(`http://192.168.1.16:9337/v1`, model `meshllm/Qwen3-30B-A3B-Q4_K_M-layers`).
Aider is a good fit for meshllm specifically because it drives edits via
plain-text whole-file/diff formats instead of function/tool-calling, which
meshllm's endpoint doesn't advertise support for. There's no HA here —
availability depends on both the mesh-llm process (`ml-server`) and the
Docker container hosting split layers (`rtx3070`) staying up.

```
./launch-aider.sh
# Backend [1-2]: 2
```

## Example prompts

Five prompts to try once a session is up, grounded in what's actually in this
repo — good for seeing what the local model (or Claude) actually produces,
with visual output where possible.

**1. Instant visual wow (single-shot HTML artifact)**
> Build a complete, playable Breakout clone as a single self-contained HTML
> file (canvas, no external libraries) — paddle physics with angle-based
> bounce, brick grid, lives, pause, win/lose states.

**2. Generative art / physics (single-shot HTML artifact)**
> Build an interactive particle-flocking simulation (boids) in a single HTML
> canvas file — mouse acts as an attractor/repeller, particles leave a subtle
> motion trail, color-by-velocity gradient.

**3. Fix + extend the real codebase (native SDL2 window)**
> app/src/main.cpp fails to compile — there's a nested function definition
> inside main() that's invalid C++. Fix the build, then add a particle-burst
> effect when the smart bomb (GameState.hpp) clears enemies. Build and run it.

**4. Put the dormant raylib dependency to work (native OpenGL window)**
> platform/CMakeLists.txt already fetches raylib 5.0 but platform.cpp/
> platform.hpp are empty stubs. Implement them to open a raylib window
> rendering a bouncing, colliding ball swarm with gravity and elastic
> collisions. Build and run it.

**5. `/ralph-loop` — autonomous local-model refinement**
```
/ralph-loop Build the Breakout clone described in breakout-benchmark.md.
Score yourself against the rubric in that file after each pass and keep
improving until every checklist item passes. --max-iterations 6
--completion-promise "BREAKOUT BENCHMARK PASSED"
```
Publish each pass's HTML output as an artifact to see the model refine its
own code iteration over iteration.

Bonus: `/loop 20m /hangarbaycc-bench`, then ask for the running results as an
artifact bar chart comparing model pass rates over time — less "pretty
graphics," more "the benchmarking harness itself is the show."

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

## Grok Build backend

Backend options 4 and 5 launch [Grok Build](https://x.ai) (the `grok` CLI)
instead of Claude Code, wired to a Qwen3.6-35B-A3B `llama-server`. No proxy
is involved either way — `llama-server` already speaks OpenAI-compatible
`/v1/chat/completions` natively, and `grok` is a native OpenAI-compatible
client (unlike Claude Code, which needs `hangarbaycc-proxy.py`'s
Anthropic-to-OpenAI translation). `grok` itself always runs on the machine
you launch `hangarbaycc.sh` from; the two options differ in where the model
server runs:

### Option 4 — ml-server (remote)

The model is `grok-local` — really just a set of scripts in
`~/Programming/grok-local` on `ml-server` — running `llama-server` fixed at
`:8081`, 128K context, `q8_0` KV, `n-cpu-moe 20`. Unlike `grok-local.sh`
(which runs both the model *and* the `grok` TUI on ml-server), this backend
only starts/reuses the model server on ml-server over SSH; `grok` talks to it
over the LAN. The first run adds a `[model.qwen36-mlserver]` entry to
`~/.grok/config.toml` pointing at `http://192.168.1.16:8081/v1`.

**Requires:** the model already downloaded on ml-server
(`~/Programming/grok-local/bin/download-qwen36.sh` if not).

### Option 5 — local (this machine only)

The model server is `grok-local-server.sh`, vendored into this repo (so
`hangarbaycc.sh` has no external script reference) from
`~/ai-models/qwen3.6-35b-a3b/run.sh` — `llama-server` fixed at `:8080`, 200K
context, `q8_0` KV, tuned for a 16 GB GPU. No SSH, no LAN dependency —
everything stays on this box. The model weights and the `llama-server`
binary itself still live outside the repo (too large to vendor); both paths
are overridable via `GROK_LOCAL_MODEL_DIR` and `GROK_LOCAL_LLAMA_SERVER` if
yours differ from the defaults (`~/ai-models/qwen3.6-35b-a3b` and
`~/llama.cpp/build/bin/llama-server`). The first run adds a
`[model.qwen36-local]` entry to `~/.grok/config.toml` pointing at
`http://127.0.0.1:8080/v1`.

**Requires:** the weights present at `GROK_LOCAL_MODEL_DIR` (or the default
above) and a built `llama-server` at `GROK_LOCAL_LLAMA_SERVER`.

### Both options

Fixed model config — no model/context/KV menus, same posture as meshllm
above. `~/.grok/config.toml` is the only place model definitions are read
from (project-scoped `.grok/config.toml` only supports `[mcp_servers]`), so
both options' entries live there side by side; later runs reuse whichever
entry already exists.

If the model server isn't already up, it takes a while to load (a 35B MoE on
one consumer GPU) — the launcher polls `/health` until it answers, same as
the Ollama backend's wait step. Left running afterward so it stays warm for
the next launch, same as Ollama.

If the `grok` CLI itself isn't on `PATH`, either option offers to install it
on the spot (`curl -fsSL https://x.ai/cli/install.sh | bash`, the official
xAI installer) rather than just erroring — confirm with `y` at the prompt,
or install manually from <https://x.ai/cli> and re-run. Either way you'll
still need to be logged in (a SuperGrok/X Premium+ subscription, or an
`XAI_API_KEY`) — the launcher only handles getting the binary onto `PATH`.

## Web search (SearXNG)

Every backend can optionally give the model real web search, via a
self-hosted [SearXNG](https://github.com/searxng/searxng) instance and a
small MCP tool (`searxng-mcp/server.py`) — asked once, right after you pick a
backend: `Enable web search via a local SearXNG instance? [y/N]`. Declining,
or any failure along the way, degrades to no web search rather than aborting
the session; nothing else about the launch changes.

**Where SearXNG runs** depends on the backend, matching each one's existing
LAN posture:
- **Backend 5 (Grok Build, local)** — SearXNG runs on *this* machine
  (`127.0.0.1:8888`), no SSH, no LAN dependency, since that backend's whole
  point is staying fully local.
- **Every other backend** (Ollama in any mode, meshllm, backend 4's ml-server
  grok) — SearXNG runs on `ml-server` (`:8888`, reachable over the LAN),
  since those backends already depend on the LAN or ml-server specifically
  for their own model serving. (Ollama's own `--remote` target, if it
  differs from ml-server, doesn't change this — search still goes to
  ml-server, matching meshllm/grok's existing convention of treating it as
  "the server".)

**How it's wired in:** SearXNG's JSON API is disabled by default (public
instances get scraped otherwise) — `searxng-settings.yml` (vendored in this
repo, mounted read-only into the container) turns it on for this private,
non-internet-facing instance. `searxng-mcp/server.py` is a small MCP stdio
server (hand-written against the official `mcp` Python SDK, not one of the
existing npm `searxng-mcp` packages, since neither Node nor npm is assumed to
be installed) exposing one `web_search` tool that hits SearXNG's
`/search?format=json`. It runs in its own venv (`searxng-mcp/.venv`,
git-ignored, bootstrapped on first use) so nothing installs into system
Python. Claude Code backends get it via `--mcp-config` (a generated
`/tmp/hangarbaycc-searxng-mcp.json`); the grok backends get it via a
generated `[mcp_servers.searxng]` block in `./.grok/config.toml`
(project-scoped — grok reads `[mcp_servers]` only from there, not from the
global `~/.grok/config.toml` used for the `[model.*]` entries above), which
grok picks up automatically with no extra flag. Both configs are
machine-specific (absolute paths, the resolved host's URL) and regenerated
every launch, so neither is meant to be committed.

**Requires Docker** on whichever host is serving SearXNG for that backend
(see above). If it's missing, you're offered the official installer
(`curl -fsSL https://get.docker.com | sh`, needs sudo) — same offer-first
posture as the Ollama and grok CLI installers elsewhere in this launcher.
One wrinkle specific to Docker: a fresh install adds your user to the
`docker` group, but group membership is only read at login, so a session
that just installed Docker still can't use it — you'll need to log out/in
(or open a new SSH session, for the remote/ml-server case) and re-run.

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
- **For web search only:** `python3 -m venv` (stdlib `venv` module) to
  bootstrap `searxng-mcp/.venv` on first use; `scp` (bundled with the `ssh`
  client on virtually every distro) when SearXNG runs on `ml-server` rather
  than locally.

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

**On whichever host serves SearXNG (this machine for backend 5; `ml-server`
for every other backend) — only if web search is enabled:**
- **Docker** — offered via the official installer if missing (see "Web
  search" above). ~256 MB RAM for the container; no GPU needed.

**For the benchmark (`bench/`) only:**
- **`gcc` / `g++`** — the bench compiles and runs the C/C++ tasks to score them.

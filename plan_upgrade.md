# HangarBayCC Model Upgrade Plan

Date: 11 July 2026
Hardware: RTX 5060 Ti 16 GB
Current champion: `gpt-oss:20b` at 128K context, q8_0 KV cache (8/8 on bench)

## Objective

Evaluate newer local models against the current gpt-oss:20b baseline using
`bench/run-bench.sh`, and decide whether any earn a slot in the hangar menu.
The bench scorecard is the arbiter, not vibes.

## Candidate 1: Devstral Small 2 — FIT-CHECKED, REJECTED (2026-07-12)

`devstral-small-2:24b` (Q4_K_M, 15 GB, Apache 2.0)

- Purpose-built agentic coder from Mistral AI: tool use, codebase
  exploration, multi-file edits. Reported 68.0% on SWE-bench Verified.
- Fits the 16 GB card, but only just: 15 GB of weights plus KV cache means
  context must stay modest. 128K context needs roughly 20 GB even at Q4, so
  plan around a 16K to 32K ceiling with q8_0 or q4_0 KV.
- The inverse trade to gpt-oss:20b: a smarter agent on a much shorter leash.

**Result:** the plan's fit estimate was wrong — this does not fit the card
at all. Ollama was 0.30.11 (well past the 0.13.3 requirement), pull
succeeded (15 GB), but the GPU-spill guard failed at every combo tested,
including the smallest sane one:

| ctx | KV | model size | size_vram | spilled to RAM |
|---|---|---|---|---|
| 16K | f16 | 18.3 GB | 11.8 GB | ~6.5 GB |
| 8K  | q4_0 | 15.9 GB | 11.5 GB | ~4.4 GB |

Unlike gpt-oss:20b (MoE, sparse experts, fits fully at 13 GB) or the other
menu models, Devstral Small 2 is a **dense** 24B model — all parameters
active, so its ~15 GB weight file alone leaves under 1.3 GB of headroom on
a 16.3 GB card, not enough for KV cache and CUDA context even at 8K/q4_0.
Measured generation speed under that spill: **2.6 tok/s** (496 tokens in
188.6s on a single short prompt) — unusable for interactive work, in line
with the "Not recommended" section's note on `qwen3-coder:30b`'s 3-8 tok/s
CPU-spill speed.

**Decision: rejected, no menu slot.** Skipped the full `bench/run-bench.sh`
suite — a fit-check failure this severe (spill at every combo, single-digit
tok/s) isn't worth 15+ minutes of bench runs per the plan's own framing that
generation speed can veto the score regardless of correctness. Devstral
Small 2 belongs in the same category as `qwen3-coder:30b`: needs materially
more than 16 GB VRAM to be usable here. Left pulled on ml-server (15 GB,
47 GB free) in case a future GPU upgrade revisits it.

## Candidate 2: Qwen3-Coder-Next

`qwen3-coder-next` (MoE)

- Agentic successor to qwen2.5-coder; reported 70%+ on SWE-bench Verified,
  ahead of Qwen2.5-Coder's ~69.6%. Recommended when agentic multi-turn work
  matters more than raw completion.
- Will not fit fully in 16 GB VRAM. MoE models tolerate partial offload far
  better than dense models (dense layers on GPU, sparse experts in system
  RAM), so it may still be usable, but it breaks a core launcher assumption.
- Recommended sampling is temp 1.0 / top-p 0.95, so the temperature clamp is
  a no-op, same as gpt-oss.

Launcher work required:

1. The `size_vram == size` hard-abort check will fail by design. Add either
   a per-model exemption flag or a "tolerated spill" mode that warns instead
   of aborting, gated to MoE models only.
2. Keep context at or under 64K with q8_0 KV to limit the offload penalty.
3. Bench it through the proxy and record tokens per second alongside the
   score; if generation speed is unusable for interactive work, the score
   does not matter.

## Not recommended

- `qwen3-coder:30b` (dense-style 19 GB Q4_K_M package): spills to system RAM
  on a 16 GB card, reported 3 to 8 tok/s with offload. Coder-Next covers the
  same niche with a gentler offload profile.
- Qwen3.6 27B/35B-A3B and Gemma 4 31B QAT: official packages target 24 GB
  and up. Revisit only if a clean low-bit build with credible quality
  reports appears.

## Low-risk swap — BENCHED, NOT ADOPTED (2026-07-12)

Replace or supplement menu option 3 (`qwen2.5-coder:14b`) with `qwen3:14b`:
same VRAM class, generally stronger reasoning, and it may not share the
fp16 KV garbling issue noted for qwen2.5-coder. Bench before swapping.

**Result:** fit check passed clean (11.9 GB / 16.3 GB, 100% GPU at 32K/q8_0).
Four bench runs each (2 raw + 2 through the proxy at the standard 0.55-0.70
band), same task set, same server:

| model | run scores | avg score | avg time/task |
|---|---|---|---|
| qwen3:14b | 7, 6, 6, 8 | 6.75/8 (84%) | ~86s |
| qwen2.5-coder:14b | 6, 7, 6, 6 | 6.25/8 (78%) | ~6.2s |
| gpt-oss:20b (baseline, 2026-07-05) | — | 8/8 (100%) | — |

qwen3:14b scores modestly higher on average but is **~14x slower per task**,
and twice failed task 03 outright by exhausting the 8192-token budget on
hidden reasoning before emitting any code (`stop=max_tokens` / empty
response) rather than producing wrong code — a distinct, less recoverable
failure mode than qwen2.5-coder's wrong-answer failures.

**Decision: do not swap.** Both candidates trail the gpt-oss:20b baseline on
correctness, and gpt-oss is also far faster than qwen3:14b. For an
interactive coding launcher, a ~14x latency increase is not justified by an
8-point average score bump, especially when the faster incumbent isn't even
the strongest option available. Menu option 3 stays `qwen2.5-coder:14b`
unchanged. qwen3:14b is left pulled on ml-server (both stores) in case a
future non-interactive or reasoning-heavy use case wants it, but it does not
earn a menu slot.

**Bug found during benching (not fixed, needs follow-up):** the temp proxy's
`<-- EMPTY RESPONSE (no content block)` diagnostic — the doctor skill's
signal for a dead/looping session — fires on every qwen3:14b response, even
successful ones, because it only counts text content blocks and doesn't
account for thinking blocks. Any thinking model on this launcher will drown
real dead-session signals in false positives until the proxy's response
parser is taught about thinking blocks.

## Test procedure

1. Pull candidate model; verify store location resolution in the launcher.
2. Add fit table entry and temperature band; run a manual preload to confirm
   the GPU-spill guard result at each proposed ctx/KV combo.
3. Run `bench/run-bench.sh MODEL` raw, then again through the proxy to
   measure the temperature band.
4. Record scorecard, tok/s, and any proxy log anomalies (empty responses,
   malformed tool calls, repetition) in `bench/results/`.
5. Compare against the gpt-oss:20b 8/8 baseline from 2026-07-05. A candidate
   earns a menu slot if it matches the score at usable speed, or beats the
   baseline on the multi-file tasks without failing others.

## Decision framing

gpt-oss:20b at 128K/q8_0 remains the default until beaten. Devstral Small 2
is most likely to earn menu option 5 as a complement (short-context,
high-capability agent sessions) rather than a replacement. Qwen3-Coder-Next
is the speculative bet that justifies the tolerated-spill launcher feature;
if its offloaded speed is acceptable, it may be the strongest model in the
hangar.

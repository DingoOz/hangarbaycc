#!/usr/bin/env python3
"""
bench-xai.py — benchmark tokens/sec of the xAI (Grok) API.

Sends a prompt to the xAI Chat Completions API and measures:
  - Time to first token (TTFT)
  - Total generation time
  - Input/output token counts (from API usage)
  - Tokens/sec (overall and after TTFT)

Usage:
    export XAI_KEY="xai-your-key-here"
    python3 bench/bench-xai.py                          # default model
    python3 bench/bench-xai.py grok-2-latest            # specific model
    python3 bench/bench-xai.py grok-2-latest "Your prompt"
    python3 bench/bench-xai.py grok-2-latest -n 5       # average over 5 runs

Defaults:
    MODEL = GROK_MODEL env var, or "grok-2-latest"
    API   = api.x.ai/v1/chat/completions (OpenAI-compatible)
"""
import json
import os
import sys
import time
import http.client
from urllib.parse import urlparse

API_HOST = "api.x.ai"
API_PATH = "/v1/chat/completions"

MODEL = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GROK_MODEL", "grok-2-latest")
API_KEY = os.environ.get("XAI_KEY", os.environ.get("XAI_API_KEY", ""))
RUNS = 1

args = sys.argv[2:]
i = 0
while i < len(args):
    if args[i] == "-n" and i + 1 < len(args):
        RUNS = int(args[i + 1])
        i += 2
    else:
        PROMPT = " ".join(args[i:])
        break
    i += 1
else:
    PROMPT = (
        "Write exactly 2000 words explaining the history, architecture, and tradeoffs "
        "of transformer language models. Cover self-attention, multi-head attention, "
        "positional encodings, pre-training objectives, scaling laws, and inference "
        "optimizations like kv-caching and speculative decoding. Be thorough and "
        "detailed — aim for a comprehensive survey-style answer."
    )

if not API_KEY:
    print("ERROR: Set XAI_KEY or XAI_API_KEY environment variable.")
    print("Get one at https://console.x.ai/")
    sys.exit(1)

parsed = urlparse(API_KEY)
if parsed.scheme:
    api_key = API_KEY
else:
    api_key = API_KEY

print(f"Model : {MODEL}")
print(f"API   : {API_HOST}{API_PATH}")
print(f"Runs  : {RUNS}")
print(f"Prompt: {PROMPT[:80]}...")
print("-" * 70)

body = {
    "model": MODEL,
    "messages": [{"role": "user", "content": PROMPT}],
    "max_tokens": 8192,
    "stream": True,
}
body_bytes = json.dumps(body).encode("utf-8")

conn = http.client.HTTPConnection(API_HOST, 443, timeout=300)
conn.request(
    "POST", API_PATH,
    body=body_bytes,
    headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    },
)
resp = conn.getresponse()

if resp.status != 200:
    raw = resp.read().decode()[:300]
    print(f"ERROR: HTTP {resp.status}: {raw}")
    sys.exit(1)

# Stream the response
t_start = time.monotonic()
t_first_token = None
total_output_tokens = 0
total_input_tokens = 0
stop_reason = None
text_chars = 0

data_lines = b""
while True:
    chunk = resp.read(4096)
    if not chunk:
        break
    data_lines += chunk

    while b"\n" in data_lines:
        line, data_lines = data_lines.split(b"\n", 1)
        line = line.rstrip(b"\r")
        if not line.startswith(b"data: "):
            continue
        payload = line[len(b"data: "):].strip()
        if not payload or payload == b"[DONE]":
            continue
        try:
            event = json.loads(payload)
        except json.JSONDecodeError:
            continue

        choices = event.get("choices") or []
        for choice in choices:
            delta = choice.get("delta", {})
            if delta.get("content") and t_first_token is None:
                t_first_token = time.monotonic()

            if delta.get("content"):
                text_chars += len(delta["content"])

        usage = event.get("usage")
        if usage:
            total_input_tokens = usage.get("prompt_tokens", 0)
            total_output_tokens = usage.get("completion_tokens", 0)

        finish = choices[0].get("finish_reason") if choices else None
        if finish:
            stop_reason = finish

conn.close()

t_end = time.monotonic()
total_time = t_end - t_start
ttft = t_first_token - t_start if t_first_token else None

print("-" * 70)
print(f"Total time:          {total_time:.2f}s")
if ttft is not None and ttft > 0:
    print(f"Time to first token: {ttft:.2f}s")
print(f"Input tokens:        {total_input_tokens:,}")
print(f"Output tokens:       {total_output_tokens:,}")
print(f"Response text chars: {text_chars:,}")
if total_time > 0:
    print(f"Tokens/sec:          {total_output_tokens / total_time:.2f}")
if ttft is not None and ttft > 0 and (total_time - ttft) > 0:
    print(f"Tokens/sec (after TTFT): {total_output_tokens / (total_time - ttft):.2f}")
if stop_reason:
    print(f"Stop reason:         {stop_reason}")

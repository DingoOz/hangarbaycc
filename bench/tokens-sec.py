#!/usr/bin/env python3
"""
tokens-sec.py — measure tokens/sec for a single generation request.

Sends a prompt to an Anthropic-compatible streaming endpoint (Ollama proxy,
Ollama /api/chat, or any compatible server) and reports throughput stats.

Usage:
    # Against Ollama's native /api/chat (no proxy needed):
    python3 bench/tokens-sec.py                        # localhost:11434, llama3.2
    python3 bench/tokens-sec.py 127.0.0.1:11434        # specify host:port
    python3 bench/tokens-sec.py 127.0.0.1:11434 phi4   # specify model too

    # Against the hangarbaycc proxy (port 11435 by default):
    python3 bench/tokens-sec.py 127.0.0.1:11435

    # Custom prompt:
    python3 bench/tokens-sec.py MODEL "Your prompt here"

Defaults:
    HOSTPORT = 127.0.0.1:11434  (raw Ollama)
    MODEL    = llama3.2
    PROMPT   = "Write a detailed explanation of how a B-tree index works in a database, including discussion of node splitting, balancing, and range query optimization."

Before running, make sure a model is loaded:
    ollama pull llama3.2
    ollama run llama3.2 ""   # primes the model
"""
import json
import sys
import time
import http.client

HOSTPORT = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:11434"
MODEL = sys.argv[2] if len(sys.argv) > 2 else "llama3.2"
PROMPT = sys.argv[3] if len(sys.argv) > 3 else (
    "Write a detailed explanation of how a B-tree index works in a database, "
    "including discussion of node splitting, balancing, and range query optimization."
)

host, port = HOSTPORT.rsplit(":", 1)

# --- Ollama native /api/chat endpoint ---
print(f"Model : {MODEL}")
print(f"Host  : {HOSTPORT}")
print(f"Prompt: {PROMPT[:80]}...")
print(f"Max tokens: 4096")
print("-" * 60)

body = {
    "model": MODEL,
    "stream": True,
    "messages": [{"role": "user", "content": PROMPT}],
    "options": {
        "num_predict": 4096,
    },
}
body_bytes = json.dumps(body).encode("utf-8")

t_start = time.monotonic()
t_first_token = None
total_output_tokens = 0
total_input_tokens = 0
total_bytes = 0
stop_reason = None

conn = http.client.HTTPConnection(host, port, timeout=600)
conn.request("POST", "/api/chat", body=body_bytes,
             headers={"Content-Type": "application/json"})
resp = conn.getresponse()

if resp.status != 200:
    print(f"ERROR: HTTP {resp.status}: {resp.read().decode()[:200]}")
    sys.exit(1)

# Stream SSE-like lines (Ollama /api/chat streams JSON lines, not SSE)
data_lines = b""
while True:
    chunk = resp.read(4096)
    if not chunk:
        break
    data_lines += chunk
    total_bytes += len(chunk)

    while b"\n" in data_lines:
        line, data_lines = data_lines.split(b"\n", 1)
        line = line.rstrip(b"\r")
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        # Track first token
        if t_first_token is None and event.get("message", {}).get("content"):
            t_first_token = time.monotonic()

        # Count output tokens from eval_count delta
        if event.get("eval_count"):
            total_output_tokens = event["eval_count"]

        # Track input tokens from prompt_eval_count
        if event.get("prompt_eval_count"):
            total_input_tokens = event["prompt_eval_count"]

        if event.get("done"):
            stop_reason = event.get("done_reason", "unknown")

conn.close()

t_end = time.monotonic()
total_time = t_end - t_start
ttft = t_first_token - t_start if t_first_token else None

# Fallback: if eval_count wasn't reported, estimate from chars/4
if total_output_tokens == 0 and total_bytes > 0:
    # Rough estimate: response is mostly JSON, text is ~chars/4 tokens
    total_output_tokens = max(1, total_bytes // 20)

print("-" * 60)
print(f"Total time:          {total_time:.2f}s")
if ttft is not None and ttft > 0:
    print(f"Time to first token: {ttft:.2f}s")
print(f"Input tokens:        {total_input_tokens}")
print(f"Output tokens:       {total_output_tokens}")
print(f"Response size:       {total_bytes:,} bytes")
if total_time > 0:
    print(f"Output tokens/sec:   {total_output_tokens / total_time:.2f}")
if ttft is not None and ttft > 0 and (total_time - ttft) > 0:
    print(f"Tokens/sec (after TTFT): {total_output_tokens / (total_time - ttft):.2f}")
if stop_reason:
    print(f"Stop reason:         {stop_reason}")


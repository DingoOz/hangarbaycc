#!/usr/bin/env python3
"""
bench-local.py — benchmark tokens/sec of the local llama-server (Qwen3.6-35B-A3B).

Sends a prompt to the OpenAI-compatible /v1/chat/completions endpoint and
measures streaming throughput.

Usage:
    python3 bench/bench-local.py                        # defaults
    python3 bench/bench-local.py 8080                   # custom port
    python3 bench/bench-local.py 8080 -n 5              # average over 5 runs
    python3 bench/bench-local.py 8080 "Your prompt"     # custom prompt

Defaults:
    HOST = 127.0.0.1
    PORT = 8080
    MODEL = auto-detected from /v1/models
    PROMPT = A ~150 token coding question that elicits a multi-paragraph answer
"""
import json
import sys
import time
import http.client

HOST = "127.0.0.1"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].lstrip("-").isdigit() else 8080

# Parse remaining args
args = sys.argv[2:]
RUNS = 1
i = 0
while i < len(args):
    if args[i] == "-n" and i + 1 < len(args) and args[i + 1].lstrip("-").isdigit():
        RUNS = int(args[i + 1])
        i += 2
    else:
        PROMPT = " ".join(args[i:])
        break
    i += 1
else:
    PROMPT = (
        "Write a Python function called `merge_intervals` that takes a list of "
        "intervals (each a tuple of two integers (start, end)) and merges all "
        "overlapping intervals. For example, given [(1,3),(2,6),(8,10),(15,18)], "
        "it should return [(1,6),(8,10),(15,18)]. Include a docstring with examples "
        "and a brief explanation of the algorithm's time complexity. Write the "
        "complete function."
    )

# Auto-detect model from server
try:
    conn = http.client.HTTPConnection(HOST, PORT, timeout=10)
    conn.request("GET", "/v1/models")
    resp = conn.getresponse()
    models = json.loads(resp.read())
    model_id = models["data"][0]["id"] if models.get("data") else "unknown"
    conn.close()
except Exception:
    model_id = "unknown"

print(f"Model : {model_id}")
print(f"Host  : {HOST}:{PORT}")
print(f"Runs  : {RUNS}")
print(f"Prompt: {PROMPT[:80]}...")
print("-" * 70)

body = {
    "model": model_id,
    "messages": [{"role": "user", "content": PROMPT}],
    "max_tokens": 8192,
    "stream": True,
}
body_bytes = json.dumps(body).encode("utf-8")

results = []
for run in range(RUNS):
    if RUNS > 1:
        print(f"\n--- Run {run + 1}/{RUNS} ---")

    conn = http.client.HTTPConnection(HOST, PORT, timeout=600)
    conn.request(
        "POST", "/v1/chat/completions",
        body=body_bytes,
        headers={"Content-Type": "application/json"},
    )
    resp = conn.getresponse()

    if resp.status != 200:
        raw = resp.read().decode()[:300]
        print(f"ERROR: HTTP {resp.status}: {raw}")
        conn.close()
        sys.exit(1)

    t_start = time.monotonic()
    t_first_token = None       # first byte of ANY kind (reasoning or content) — true server TTFT
    t_first_reasoning = None
    t_first_content = None     # first real answer token — end of thinking phase
    total_output_tokens = 0
    total_input_tokens = 0
    stop_reason = None
    text_len = 0
    reasoning_len = 0

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
                reasoning = delta.get("reasoning_content")
                content = delta.get("content")
                now = time.monotonic()
                if (reasoning or content) and t_first_token is None:
                    t_first_token = now
                if reasoning:
                    if t_first_reasoning is None:
                        t_first_reasoning = now
                    reasoning_len += len(reasoning)
                if content:
                    if t_first_content is None:
                        t_first_content = now
                    text_len += len(content)

            usage = event.get("usage")
            if usage:
                total_input_tokens = usage.get("prompt_tokens", 0)
                total_output_tokens = usage.get("completion_tokens", 0)

            finish = choices[0].get("finish_reason") if choices else None
            if finish:
                stop_reason = finish

    # If the server didn't report token counts, estimate from chars
    # (reasoning tokens count toward completion_tokens on the server side too)
    if total_output_tokens == 0 and (text_len > 0 or reasoning_len > 0):
        total_output_tokens = max(1, (text_len + reasoning_len) // 4)
    if total_input_tokens == 0:
        # Estimate input tokens from the prompt length
        total_input_tokens = max(1, len(PROMPT) // 4)

    conn.close()
    t_end = time.monotonic()
    total_time = t_end - t_start
    ttft = t_first_token - t_start if t_first_token else None
    reasoning_time = (t_first_content - t_first_reasoning) if (t_first_content and t_first_reasoning) else None
    reasoning_tokens_est = max(1, reasoning_len // 4) if reasoning_len else 0

    result = {
        "run": run + 1,
        "total_time": total_time,
        "ttft": ttft,
        "reasoning_time": reasoning_time,
        "reasoning_tokens_est": reasoning_tokens_est,
        "input_tokens": total_input_tokens,
        "output_tokens": total_output_tokens,
        "text_len": text_len,
        "stop_reason": stop_reason,
    }
    results.append(result)

    # Print this run's stats
    print(f"  Total time:          {total_time:.2f}s")
    if ttft is not None and ttft > 0:
        print(f"  Time to first token: {ttft:.2f}s  (server TTFB, reasoning or content)")
    if reasoning_time is not None:
        print(f"  Reasoning duration:  {reasoning_time:.2f}s  (~{reasoning_tokens_est:,} reasoning tokens)")
    print(f"  Input tokens:        {total_input_tokens:,}")
    print(f"  Output tokens:       {total_output_tokens:,}  (completion_tokens; includes reasoning)")
    print(f"  Response chars:      {text_len:,}")
    if total_time > 0:
        print(f"  Tokens/sec:          {total_output_tokens / total_time:.2f}")
    if ttft is not None and ttft > 0 and (total_time - ttft) > 0:
        print(f"  Tokens/sec (after TTFT): {total_output_tokens / (total_time - ttft):.2f}")
    if stop_reason:
        print(f"  Stop reason:         {stop_reason}")

# Print summary if multiple runs
if RUNS > 1:
    print("\n" + "=" * 70)
    print("Summary")
    print("=" * 70)
    avg_time = sum(r["total_time"] for r in results) / RUNS
    avg_ttft = sum(r["ttft"] or 0 for r in results) / RUNS
    avg_reasoning_time = sum(r["reasoning_time"] or 0 for r in results) / RUNS
    avg_out = sum(r["output_tokens"] for r in results) / RUNS
    avg_in = sum(r["input_tokens"] for r in results) / RUNS
    print(f"  Avg total time:      {avg_time:.2f}s")
    print(f"  Avg TTFT:            {avg_ttft:.2f}s  (server TTFB, reasoning or content)")
    if avg_reasoning_time > 0:
        print(f"  Avg reasoning time:  {avg_reasoning_time:.2f}s")
    print(f"  Avg input tokens:    {avg_in:,.0f}")
    print(f"  Avg output tokens:   {avg_out:,.0f}")
    print(f"  Avg tokens/sec:      {sum(r['output_tokens'] for r in results) / sum(r['total_time'] for r in results):.2f}")
    if avg_ttft > 0:
        gen_time = sum(r['total_time'] - (r['ttft'] or 0) for r in results)
        print(f"  Avg tokens/sec (gen only): {sum(r['output_tokens'] for r in results) / gen_time:.2f}")
    print(f"  Min tokens/sec:      {min(r['output_tokens'] / r['total_time'] for r in results):.2f}")
    print(f"  Max tokens/sec:      {max(r['output_tokens'] / r['total_time'] for r in results):.2f}")

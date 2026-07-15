#!/usr/bin/env python3
"""Extract the program from a model response on stdin.

Supports both Anthropic Messages (/v1/messages) and OpenAI-compatible
chat-completions (/v1/chat/completions) response shapes. Concatenates all
`text` content blocks for Anthropic (skipping `thinking`), or takes
`choices[0].message.content` directly for OpenAI-compatible responses. Finds
every fenced code block, and prints the longest one — the prompt asks for
exactly one block, but thinking models sometimes emit fragments first; the
longest is the full program. Exits 1 (with a reason on stderr) if no code is
found.
"""
import json
import re
import sys

raw = sys.stdin.read()
try:
    resp = json.loads(raw)
except ValueError:
    sys.stderr.write(f"response is not JSON: {raw[:200]}\n")
    sys.exit(1)

if resp.get("type") == "error" or "error" in resp:
    sys.stderr.write(f"API error: {json.dumps(resp)[:300]}\n")
    sys.exit(1)

if "choices" in resp:
    choices = resp.get("choices") or []
    text = (choices[0].get("message", {}).get("content") or "") if choices else ""
elif "content" in resp:
    text = "".join(b.get("text", "") for b in resp.get("content", [])
                   if isinstance(b, dict) and b.get("type") == "text")
else:
    sys.stderr.write(f"unrecognized response shape: {json.dumps(resp)[:200]}\n")
    sys.exit(1)

if not text.strip():
    sys.stderr.write("empty text content in response\n")
    sys.exit(1)

blocks = re.findall(r"```[^\n]*\n(.*?)```", text, re.DOTALL)
if not blocks:
    # Model may have replied with bare code and no fences; accept it if it
    # looks remotely like code (has a newline), else give up.
    if "\n" in text.strip():
        sys.stdout.write(text.strip() + "\n")
        sys.exit(0)
    sys.stderr.write("no fenced code block in response\n")
    sys.exit(1)

sys.stdout.write(max(blocks, key=len))

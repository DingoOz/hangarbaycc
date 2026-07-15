#!/usr/bin/env python3
"""
hangarbaycc-proxy.py — reverse proxy in front of a local Ollama server or a
remote OpenAI-compatible server (e.g. meshllm), for Claude Code.

Claude Code sends `temperature: 1.0` on every /v1/messages request, which
overrides the model's preferred sampling and makes a small model produce far
more malformed / hallucinated tool calls. Ollama honours the request value over
the Modelfile, and Claude Code has no temperature flag — so we clamp it here.

We clamp temperature into a *band* [TEMP_FLOOR, TEMP_CEIL] rather than pinning it
to a single low value. Pinning near-greedy (the old temp=0.4) keeps tool calls
clean but makes a small model prone to agentic repetition loops: when the context
keeps re-presenting an identical state, the argmax next-action reproduces that
state, which re-feeds the same context — a self-reinforcing fixed point. A band
keeps enough entropy to escape the loop while still cutting malformed tool calls.
The band is per-model — the launcher passes the right one (e.g. gpt-oss wants
temp≈1.0, so its band is 0.9–1.0 and the clamp is effectively a no-op).

We also strip named tools from the `tools` array (STRIP_TOOLS, comma-separated).
--disallowedTools only auto-denies a call at execution time — the model still
sees the schema and still tries. Removing the entry here means the model never
sees the tool at all: no hallucinated calls, and several thousand tokens of
schema freed for actual code context.

We implement POST /v1/messages/count_tokens LOCALLY (chars/4 estimate).
Ollama doesn't serve that route (404), and Claude Code's fallback — probing
with max_tokens=1 requests and reconciling the numbers — has been observed to
fall over and kill the session with "There's an issue with the selected
model". An estimate keeps Claude Code's context accounting on the happy path;
it only drives compaction heuristics, so precision doesn't matter.

We also inject `repeat_penalty` / `repeat_last_n` to suppress the *within-a-single-
generation* runaway (e.g. the same method emitted over and over). These are Ollama
sampling options; if the upstream Anthropic-compat adapter doesn't forward them to
the model they are simply ignored — harmless either way. Note they do NOT help the
across-turn agentic loop (penalties only apply within one decode); the temperature
band is the lever for that.

Each /v1/messages generation is summarised to stderr (status, seconds, bytes,
stop_reason, whether any content block was produced) so a dead session can be
diagnosed from /tmp/hangarbaycc-proxy.log after the fact.

Everything else is forwarded verbatim to UPSTREAM. All other routes
(/api/version, /api/tags, model preload, ...) pass straight through, so
`ollama launch claude` can be pointed at this port instead of the real server.

PROTOCOL "openai" mode: UPSTREAM speaks OpenAI-compatible /v1/chat/completions
instead of Ollama's Anthropic-compat /v1/messages (e.g. meshllm, a remote
OpenAI-compatible LLM server with no Anthropic Messages support at all). Only
POST /v1/messages gets special handling in this mode — it's translated to an
OpenAI request, sent to UPSTREAM/v1/chat/completions, and the response (JSON
or SSE stream) is translated back into Anthropic Messages shape. Every other
route (GET /v1/models, etc.) still uses the generic verbatim relay above.

CLASSIFIER_MODEL (optional): if set, any request naming CLASSIFIER_TRIGGER_MODEL
has its `model` field rewritten to CLASSIFIER_MODEL and is routed to
CLASSIFIER_UPSTREAM instead of UPSTREAM, via plain passthrough (no protocol
translation — meant for a local Ollama model, which already speaks Anthropic
Messages natively). Exists because Claude Code's auto-mode safety classifier
(which runs before Bash/Edit/Write) always requests CLASSIFIER_TRIGGER_MODEL
("claude-sonnet-5" by default — CLAUDE_CODE_AUTO_MODE_MODEL as a plain env
var does NOT change this, confirmed by testing) regardless of the main
session's configured model, so it needs its own routing/rewrite rather than
just setting an env var.

Usage:
    hangarbaycc-proxy.py [LISTEN_PORT] [UPSTREAM_HOSTPORT] [TEMP_FLOOR] [TEMP_CEIL]
                         [TOP_P_CEIL] [STRIP_TOOLS] [PROTOCOL] [CLASSIFIER_MODEL]
                         [CLASSIFIER_UPSTREAM] [CLASSIFIER_TRIGGER_MODEL]
                         [CLASSIFIER_NUM_GPU]
Defaults: 11435  127.0.0.1:11434  0.55  0.70  0.95  ""  ollama  ""  127.0.0.1:11434  claude-sonnet-5  0
"""
import http.client
import json
import re
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 11435
UPSTREAM = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1:11434"
TEMP_FLOOR = float(sys.argv[3]) if len(sys.argv) > 3 else 0.55
TEMP_CEIL = float(sys.argv[4]) if len(sys.argv) > 4 else 0.70
TOP_P_CEIL = float(sys.argv[5]) if len(sys.argv) > 5 else 0.95
STRIP_TOOLS = {t.strip() for t in (sys.argv[6] if len(sys.argv) > 6 else "").split(",") if t.strip()}
REPEAT_PENALTY = 1.2
REPEAT_LAST_N = 256

PROTOCOL = (sys.argv[7] if len(sys.argv) > 7 else "ollama").strip().lower()
if PROTOCOL not in ("ollama", "openai"):
    sys.stderr.write(f"!! unknown protocol {PROTOCOL!r} (want 'ollama' or 'openai'); "
                      f"defaulting to 'ollama'\n")
    PROTOCOL = "ollama"
OPENAI_UPSTREAM_TOKEN = "mesh"  # meshllm has no real auth; any value works
MIN_MAX_TOKENS = 4096           # openai protocol only: floor against the
                                 # hidden-reasoning-burns-the-budget failure mode
MAX_MAX_TOKENS = 8192           # openai protocol only: ceiling. meshllm's scheduler
                                 # rejects a request whose (prompt + max_tokens) exceeds
                                 # its 40960 context — Claude Code can ask for max_tokens
                                 # as high as 32000, which alone would eat most of that
                                 # budget before a single prompt token is counted.
FINISH_REASON_MAP = {"stop": "end_turn", "tool_calls": "tool_use", "length": "max_tokens"}

# Claude Code's "auto mode" runs a separate safety-classifier call before
# executing tools like Bash. Live-tested: setting CLAUDE_CODE_AUTO_MODE_MODEL
# as a plain env var has NO effect — the classifier request always names
# CLASSIFIER_TRIGGER_MODEL ("claude-sonnet-5", Claude Code's hardcoded
# default) regardless. Against a real Anthropic backend that's fine; against
# a custom ANTHROPIC_BASE_URL it's a real request for a model the upstream
# doesn't have, which errors (meshllm returned 404/429 in testing) — and
# meshllm's own 10-20s+ per-call latency (it burns hidden reasoning tokens
# even on trivial replies) blows past whatever short timeout the classifier
# expects anyway, so Claude Code can't safety-check (and therefore can't
# run) tools like Bash at all. Fix: detect any request naming
# CLASSIFIER_TRIGGER_MODEL, REWRITE its `model` field to CLASSIFIER_MODEL
# (a separate small/fast local model), and route it to CLASSIFIER_UPSTREAM
# instead of UPSTREAM — matched by content, not a different listen port,
# since Claude Code only accepts one ANTHROPIC_BASE_URL per session. Ollama
# already speaks Anthropic Messages natively, so these requests need no
# protocol translation — just a rewritten model field and a different
# upstream host:port.
CLASSIFIER_MODEL = sys.argv[8] if len(sys.argv) > 8 else ""
CLASSIFIER_UPSTREAM = sys.argv[9] if len(sys.argv) > 9 else "127.0.0.1:11434"
CLASSIFIER_TRIGGER_MODEL = sys.argv[10] if len(sys.argv) > 10 else "claude-sonnet-5"
CLASSIFIER_NUM_GPU = int(sys.argv[11]) if len(sys.argv) > 11 else 0

# options.num_gpu for the classifier's Ollama requests — only exists on
# Ollama's NATIVE /api/chat, not the Anthropic-compat /v1/messages
# passthrough, so classifier requests get translated to Ollama-native shape
# (see to_ollama_native_request / ollama_native_to_anthropic_response)
# rather than just passed through. Historically forced to 0 (CPU-only)
# because CLASSIFIER_UPSTREAM was ml-server, whose GPU is already ~full with
# mesh-llm's own layers (331-336 MiB free of 16 GB) — a second model loading
# there via GPU reliably OOMs, even for tiny requests (Ollama sizes the
# KV-cache allocation off num_ctx, not the actual prompt size). A dedicated
# classifier host with its own free GPU (e.g. gtx1070) should instead pass
# -1 here (let Ollama use the GPU) via hangarbaycc.sh's CLASSIFIER_NUM_GPU.
#
# CPU prefill is nowhere near GPU speed, though: live-measured ~180-215
# tok/s on ml-server's 12 cores for this model, so a 20K-token prompt (our
# first attempt at a trim budget) took over 2 minutes and timed out outright
# — the classifier needs to answer in single-digit seconds to be useful at
# all. CLASSIFIER_NUM_CTX is just the KV-cache allocation ceiling (cheap,
# RAM is plentiful); CLASSIFIER_CONTEXT_BUDGET_BYTES below is what actually
# controls latency, by bounding how many tokens get prefilled per call.
CLASSIFIER_NUM_CTX = 32768

# The classifier request's own context (system + full message history Claude
# Code sends it) grows with the conversation just like the main turn's does —
# live-observed reaching ~121KB (~30K tokens). Trimmed aggressively: drop the
# OLDEST messages first, always keeping the last one (the actual action
# being judged) and the system prompt (the auto-mode rules — needed to judge
# anything at all). ~8KB keeps CPU prefill to single-digit seconds
# (live-measured: ~2.5KB->3.9s, ~6KB->7.1s, ~12KB->15.4s — roughly linear).
CLASSIFIER_CONTEXT_BUDGET_BYTES = 8_000

# meshllm processes one request at a time and instantly rejects (429/404,
# 0.0s — it doesn't queue) anything that arrives while it's busy. Claude Code
# routinely fires more than one request at once (e.g. a small side-request
# for conversation-title generation alongside the main turn), so without
# this lock the loser of that race gets 429'd and retried into a storm —
# live-observed: a 32s main-turn request in flight, three consecutive 429s
# for a second request over that same window. Only guards the meshllm leg
# (PROTOCOL=="openai"); the classifier goes to a different host and doesn't
# contend with meshllm, and Ollama-protocol mode has never shown this issue.
UPSTREAM_LOCK = threading.Lock()

# Headers that must not be copied between hops.
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "content-length",
}

_last_strip_count = None  # log only when the stripped count changes


def log(msg: str) -> None:
    sys.stderr.write(time.strftime("[proxy %H:%M:%S] ") + msg + "\n")


def rewrite_body(body: bytes) -> bytes:
    """Clamp temperature into a band, cap top_p, strip named tool schemas, and
    inject anti-repetition options in a JSON body; pass anything else unchanged."""
    global _last_strip_count
    if not body:
        return body
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return body
    if not isinstance(data, dict):
        return body
    changed = False

    # Remove stripped tools from the schema the model sees.
    tools = data.get("tools")
    if STRIP_TOOLS and isinstance(tools, list):
        kept = [t for t in tools
                if not (isinstance(t, dict) and t.get("name") in STRIP_TOOLS)]
        stripped = len(tools) - len(kept)
        if stripped:
            data["tools"] = kept
            changed = True
        if stripped != _last_strip_count:
            _last_strip_count = stripped
            log(f"stripped {stripped} tool schema(s), {len(kept)} remain")

    # Clamp temperature into [TEMP_FLOOR, TEMP_CEIL]. Default it to the floor
    # when absent so a request with no temperature still gets some entropy.
    temp = data.get("temperature")
    if isinstance(temp, (int, float)):
        clamped = min(max(temp, TEMP_FLOOR), TEMP_CEIL)
    else:
        clamped = TEMP_FLOOR
    if clamped != temp:
        data["temperature"] = clamped
        changed = True

    if isinstance(data.get("top_p"), (int, float)) and data["top_p"] > TOP_P_CEIL:
        data["top_p"] = TOP_P_CEIL
        changed = True

    # Suppress within-generation runaways. Only set when the request hasn't
    # asked for a stronger penalty already.
    if float(data.get("repeat_penalty", 0) or 0) < REPEAT_PENALTY:
        data["repeat_penalty"] = REPEAT_PENALTY
        changed = True
    if int(data.get("repeat_last_n", 0) or 0) < REPEAT_LAST_N:
        data["repeat_last_n"] = REPEAT_LAST_N
        changed = True

    return json.dumps(data).encode("utf-8") if changed else body


def _truncate_text(s: str, max_chars: int) -> str:
    if not isinstance(s, str) or len(s) <= max_chars:
        return s
    marker = f"\n...[truncated {len(s) - max_chars} chars]...\n"
    return s[: max_chars // 2] + marker + s[-max_chars // 2 :]


def _truncate_content(content, max_chars: int):
    """content is either a plain string or a list of Anthropic content
    blocks — truncate whatever text is in there, in place-equivalent
    (returns a new value, doesn't mutate)."""
    if isinstance(content, str):
        return _truncate_text(content, max_chars)
    if isinstance(content, list):
        out = []
        for b in content:
            if not isinstance(b, dict):
                out.append(b)
                continue
            b = dict(b)
            if isinstance(b.get("text"), str):
                b["text"] = _truncate_text(b["text"], max_chars)
            if isinstance(b.get("content"), str):  # tool_result content
                b["content"] = _truncate_text(b["content"], max_chars)
            out.append(b)
        return out
    return content


def _trim_for_classifier_context(data: dict) -> dict:
    """Fit the request under CLASSIFIER_CONTEXT_BUDGET_BYTES so a growing
    conversation never exceeds the classifier model's own (much smaller than
    meshllm's) context, in three escalating steps — most requests only need
    the first:
      1. Drop the oldest messages, keeping system + the last message (the
         actual action being judged).
      2. If system + the remaining message(s) alone still exceed budget
         (live-observed: a single Edit/Write judgment can embed an entire
         file's contents, or the system prompt itself can be large — dropping
         messages alone doesn't help either case), truncate the system prompt.
      3. If STILL over budget, truncate each remaining message's content too.
    No-op if already under budget."""
    messages = data.get("messages")
    if not isinstance(messages, list):
        return data

    def _size(sys_val, msgs) -> int:
        return len(json.dumps({"system": sys_val, "messages": msgs, "tools": data.get("tools")}))

    system = data.get("system")
    if _size(system, messages) <= CLASSIFIER_CONTEXT_BUDGET_BYTES:
        return data

    trimmed = list(messages)
    dropped = 0
    while len(trimmed) > 1 and _size(system, trimmed) > CLASSIFIER_CONTEXT_BUDGET_BYTES:
        trimmed.pop(0)
        dropped += 1
    if dropped:
        log(f"classifier request trimmed: dropped {dropped} oldest message(s)")

    if _size(system, trimmed) > CLASSIFIER_CONTEXT_BUDGET_BYTES:
        # `system` can be a plain string OR an array of content blocks — a
        # per-block cap (like message content gets below) could still leave
        # the total oversized if there are many blocks, since each one gets
        # capped independently, not the sum. Flatten to one string and
        # hard-cap THAT instead, which bounds the total regardless of the
        # original structure. (An earlier string-only truncation attempt
        # silently no-op'd on the array case, which is what Claude Code's
        # real auto-mode system prompt turned out to be — live-observed:
        # logged before==after size, still 109882B.)
        before = len(json.dumps(system)) if system else 0
        system = _truncate_text(_flatten_text(system), CLASSIFIER_CONTEXT_BUDGET_BYTES // 2)
        log(f"classifier request trimmed: system prompt {before}B -> "
            f"{len(json.dumps(system)) if system else 0}B (still over budget after dropping messages)")

    if _size(system, trimmed) > CLASSIFIER_CONTEXT_BUDGET_BYTES:
        per_msg_cap = max(500, CLASSIFIER_CONTEXT_BUDGET_BYTES // max(1, len(trimmed)) // 2)
        trimmed = [{**m, "content": _truncate_content(m.get("content"), per_msg_cap)}
                   if isinstance(m, dict) else m for m in trimmed]
        log(f"classifier request trimmed: message content capped at ~{per_msg_cap} chars each "
            f"(still over budget after dropping messages + system)")

    final_size = _size(system, trimmed)
    if final_size > CLASSIFIER_CONTEXT_BUDGET_BYTES:
        log(f"classifier request still {final_size}B after all trimming "
            f"(budget {CLASSIFIER_CONTEXT_BUDGET_BYTES}B) — proceeding anyway, may be slow")

    data["system"] = system
    data["messages"] = trimmed
    return data


# --- Anthropic Messages <-> OpenAI Chat Completions translation (PROTOCOL=openai) ---
#
# Claude Code only speaks the Anthropic Messages API. An "openai" upstream
# (e.g. meshllm) only speaks OpenAI-compatible /v1/chat/completions. Anthropic
# request/response shapes and streaming SSE event framing are ANTHROPIC'S OWN
# format, verified against https://platform.claude.com/docs/en/build-with-claude/streaming
# — not something the upstream produces natively, so it's built here by hand.


def _estimate_tokens(obj) -> int:
    """Same chars/4 estimate style as _count_tokens below — good enough for
    context-accounting heuristics, not meant to be exact."""
    return max(1, len(json.dumps(obj)) // 4)


def _flatten_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(b.get("text", "") for b in content
                        if isinstance(b, dict) and b.get("type") == "text")
    return ""


def _tool_result_text(block: dict) -> str:
    inner = block.get("content")
    if isinstance(inner, str):
        return inner
    if isinstance(inner, list):
        return "".join(b.get("text", "") for b in inner
                        if isinstance(b, dict) and b.get("type") == "text")
    return ""


def to_openai_request(data: dict) -> dict:
    """Anthropic-shaped (already rewrite_body()-processed) -> OpenAI chat-completions
    shaped. Builds a fresh dict, so Ollama-only fields rewrite_body() may have
    added (repeat_penalty, repeat_last_n) are simply never copied over."""
    messages = []
    system_text = _flatten_text(data.get("system"))
    if system_text:
        messages.append({"role": "system", "content": system_text})

    for msg in data.get("messages", []) or []:
        role, content = msg.get("role"), msg.get("content")
        if isinstance(content, str):
            messages.append({"role": role, "content": content})
            continue
        if not isinstance(content, list):
            continue

        if role == "user":
            tool_msgs, text_parts = [], []
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_result":
                    tool_msgs.append({
                        "role": "tool",
                        "tool_call_id": block.get("tool_use_id", ""),
                        "content": _tool_result_text(block) or
                                   ("[error]" if block.get("is_error") else ""),
                    })
                elif block.get("type") == "text":
                    text_parts.append(block.get("text", ""))
                # image / thinking / redacted_thinking: dropped, known limitation
            messages.extend(tool_msgs)  # tool outputs before any leftover user text
            if text_parts:
                messages.append({"role": "user", "content": "".join(text_parts)})

        elif role == "assistant":
            text_parts, tool_calls = [], []
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    text_parts.append(block.get("text", ""))
                elif block.get("type") == "tool_use":
                    tool_calls.append({
                        "id": block.get("id", ""),
                        "type": "function",
                        "function": {"name": block.get("name", ""),
                                     "arguments": json.dumps(block.get("input", {}))},
                    })
            am = {"role": "assistant", "content": "".join(text_parts) or None}
            if tool_calls:
                am["tool_calls"] = tool_calls
            messages.append(am)

    out = {"model": data.get("model"), "messages": messages,
           "stream": bool(data.get("stream", False))}
    if "temperature" in data:
        out["temperature"] = data["temperature"]
    if "top_p" in data:
        out["top_p"] = data["top_p"]

    max_tokens = data.get("max_tokens")
    if not isinstance(max_tokens, (int, float)) or max_tokens < MIN_MAX_TOKENS:
        max_tokens = MIN_MAX_TOKENS
    elif max_tokens > MAX_MAX_TOKENS:
        max_tokens = MAX_MAX_TOKENS
    out["max_tokens"] = int(max_tokens)

    tools = data.get("tools")
    if isinstance(tools, list) and tools:
        out["tools"] = [{"type": "function", "function": {
            "name": t.get("name"), "description": t.get("description", ""),
            "parameters": t.get("input_schema", {"type": "object", "properties": {}}),
        }} for t in tools if isinstance(t, dict)]

    tc = data.get("tool_choice")
    if isinstance(tc, dict):
        mapped = {"auto": "auto", "any": "required", "none": "none"}
        if tc.get("type") in mapped:
            out["tool_choice"] = mapped[tc["type"]]
        elif tc.get("type") == "tool" and tc.get("name"):
            out["tool_choice"] = {"type": "function", "function": {"name": tc["name"]}}

    return out


def to_anthropic_response(resp: dict, requested_model: str) -> dict:
    """Non-streaming OpenAI chat-completion response -> Anthropic Messages response."""
    choice = (resp.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    stop_reason = FINISH_REASON_MAP.get(choice.get("finish_reason"), "end_turn")

    content = []
    text = message.get("content")
    if text:
        content.append({"type": "text", "text": text})
    for tc in message.get("tool_calls") or []:
        fn = tc.get("function") or {}
        raw_args = fn.get("arguments") or "{}"
        try:
            parsed = json.loads(raw_args)
        except (ValueError, TypeError):
            log(f"malformed tool_call arguments from upstream: {raw_args[:200]!r}")
            parsed = {"_raw_arguments": raw_args}
        content.append({"type": "tool_use",
                         "id": tc.get("id") or f"toolu_{uuid.uuid4().hex[:24]}",
                         "name": fn.get("name", ""), "input": parsed})

    usage = resp.get("usage") or {}
    return {
        "id": resp.get("id") or f"msg_{uuid.uuid4().hex[:24]}",
        "type": "message", "role": "assistant", "model": requested_model,
        "content": content, "stop_reason": stop_reason, "stop_sequence": None,
        "usage": {"input_tokens": usage.get("prompt_tokens", 0),
                   "output_tokens": usage.get("completion_tokens", 0)},
    }


def to_ollama_native_request(data: dict) -> dict:
    """Anthropic-shaped (already rewrite_body()/_trim_for_classifier_context()
    processed) -> Ollama's native /api/chat shape. Reuses to_openai_request's
    message/system flattening (nearly identical shape — role/content pairs);
    the meaningful differences are the top-level `options` object (used here
    to set CLASSIFIER_NUM_GPU — 0 to force CPU-only when the classifier host's
    GPU has no headroom, -1 to let Ollama use the GPU on a dedicated host) and
    always requesting non-streaming (classifier replies are a few
    tokens; simpler to always block briefly than handle Ollama's differently-
    framed streaming format for something this size — see _relay_classifier
    for how a client's own `stream:true` request is still honored on the way
    back out, synthesized from this single blocking call).

    keep_alive is set on EVERY call, not just hangarbaycc.sh's one-time
    startup preload — Ollama's keep_alive is refreshed per-request, so
    without this every proxied call after the first would fall back to
    Ollama's own (much shorter) default, undoing the preload's setting and
    causing an unexpected cold reload mid-session (live-observed: `ollama ps`
    showed nothing loaded well into an active session, and the next call hit
    a cold-load-plus-prefill penalty that exceeded the classifier's request
    timeout). llama3.2:3b is small (~2 GB) enough that keeping it loaded for
    the session's duration is a fine tradeoff — "-1" here, not a bounded
    duration like hangarbaycc.sh used for the previous, much larger 14B
    classifier model."""
    openai_shaped = to_openai_request(data)
    return {
        "model": openai_shaped["model"],
        "messages": openai_shaped["messages"],
        "stream": False,
        "keep_alive": -1,
        "options": {"num_gpu": CLASSIFIER_NUM_GPU, "num_ctx": CLASSIFIER_NUM_CTX,
                    "num_predict": openai_shaped.get("max_tokens", MIN_MAX_TOKENS)},
    }


def ollama_native_to_anthropic_response(resp: dict, requested_model: str) -> dict:
    """Ollama /api/chat (non-streaming) response -> Anthropic Messages response."""
    message = resp.get("message") or {}
    text = message.get("content") or ""
    stop_reason = {"stop": "end_turn", "length": "max_tokens"}.get(
        resp.get("done_reason"), "end_turn")
    return {
        "id": f"msg_{uuid.uuid4().hex[:24]}",
        "type": "message", "role": "assistant", "model": requested_model,
        "content": [{"type": "text", "text": text}] if text else [],
        "stop_reason": stop_reason, "stop_sequence": None,
        "usage": {"input_tokens": resp.get("prompt_eval_count", 0),
                   "output_tokens": resp.get("eval_count", 0)},
    }


def _single_shot_anthropic_sse(anth: dict):
    """A complete non-streaming Anthropic response -> the minimal correct
    Anthropic SSE event sequence for it (one text block, no incremental
    deltas beyond the one chunk we actually have). Used only for classifier
    replies that request streaming — real streaming isn't worth building for
    a handful of tokens, but the response still needs to be valid SSE if the
    caller asked for it."""
    def sse(event, data):
        return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode("utf-8")

    usage = anth.get("usage") or {}
    yield sse("message_start", {"type": "message_start", "message": {
        "id": anth["id"], "type": "message", "role": "assistant",
        "model": anth["model"], "content": [],
        "stop_reason": None, "stop_sequence": None,
        "usage": {"input_tokens": usage.get("input_tokens", 0), "output_tokens": 1}}})

    text = "".join(b.get("text", "") for b in anth.get("content", [])
                    if isinstance(b, dict) and b.get("type") == "text")
    if text:
        yield sse("content_block_start", {"type": "content_block_start",
            "index": 0, "content_block": {"type": "text", "text": ""}})
        yield sse("content_block_delta", {"type": "content_block_delta",
            "index": 0, "delta": {"type": "text_delta", "text": text}})
        yield sse("content_block_stop", {"type": "content_block_stop", "index": 0})

    yield sse("message_delta", {"type": "message_delta",
        "delta": {"stop_reason": anth.get("stop_reason", "end_turn"), "stop_sequence": None},
        "usage": {"output_tokens": usage.get("output_tokens", 1)}})
    yield sse("message_stop", {"type": "message_stop"})


def _openai_error_to_anthropic(status: int, raw_body: bytes) -> dict:
    try:
        obj = json.loads(raw_body) if raw_body else {}
    except (ValueError, UnicodeDecodeError):
        obj = {}
    err = obj.get("error") if isinstance(obj, dict) else None
    message = (err or {}).get("message") if isinstance(err, dict) else None
    if not message:
        message = raw_body[:500].decode("utf-8", "replace") or f"upstream returned HTTP {status}"
    kind = {400: "invalid_request_error", 401: "authentication_error", 403: "permission_error",
            404: "not_found_error", 408: "timeout_error", 429: "rate_limit_error",
            500: "api_error", 503: "overloaded_error"}.get(status, "api_error")
    return {"type": "error", "error": {"type": kind, "message": message}}


class AnthropicStreamTranslator:
    """Consumes raw OpenAI-style SSE bytes (chat.completion.chunk frames), yields
    complete Anthropic Messages SSE event frames. Handles multiple concurrent
    tool calls per turn (each OpenAI tool_calls[].index maps to its own
    Anthropic content-block index) and fragmented (or single-shot) input_json
    argument deltas."""

    def __init__(self, requested_model: str, input_tokens_estimate: int):
        self.requested_model = requested_model
        self.input_tokens_estimate = input_tokens_estimate
        self._carry = b""
        self.started = False
        self.done = False
        self.next_index = 0
        self.open_block = None       # {"index", "kind": "text"|"tool_use", "openai_index"?}
        self.tool_index_map = {}     # openai tool_calls[].index -> anthropic block index
        self.saw_content = False
        self.stop_reason = None
        self.output_chars = 0

    @staticmethod
    def _sse(event: str, data: dict) -> bytes:
        return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode("utf-8")

    def feed(self, chunk: bytes):
        out = []
        self._carry += chunk
        *lines, self._carry = self._carry.split(b"\n")
        for line in lines:
            out.extend(self._feed_line(line.strip(b"\r")))
        return out

    def finish(self):
        out = []
        if self._carry.strip():
            out.extend(self._feed_line(self._carry.strip(b"\r")))
            self._carry = b""
        out.extend(self._close_and_finish())
        return out

    def _feed_line(self, line: bytes):
        if not line.startswith(b"data:"):
            return []
        payload = line[len(b"data:"):].strip()
        if payload == b"[DONE]":
            return self._close_and_finish()
        if not payload:
            return []
        try:
            obj = json.loads(payload)
        except (ValueError, UnicodeDecodeError):
            log(f"openai stream: skipping malformed data line: {payload[:200]!r}")
            return []
        if isinstance(obj, dict) and "error" in obj:
            return self._handle_error(obj)
        return self._handle_chunk(obj)

    def _ensure_started(self, obj: dict):
        if self.started:
            return []
        self.started = True
        msg_id = obj.get("id") or f"msg_{uuid.uuid4().hex[:24]}"
        return [self._sse("message_start", {"type": "message_start", "message": {
            "id": msg_id, "type": "message", "role": "assistant",
            "model": self.requested_model, "content": [],
            "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": self.input_tokens_estimate, "output_tokens": 1}}})]

    def _open_text_block(self):
        out = self._close_block()
        idx = self.next_index
        self.next_index += 1
        self.open_block = {"index": idx, "kind": "text"}
        out.append(self._sse("content_block_start", {"type": "content_block_start",
            "index": idx, "content_block": {"type": "text", "text": ""}}))
        return out

    def _open_tool_block(self, openai_index, call_id, name):
        out = self._close_block()
        idx = self.next_index
        self.next_index += 1
        self.tool_index_map[openai_index] = idx
        self.open_block = {"index": idx, "kind": "tool_use", "openai_index": openai_index}
        out.append(self._sse("content_block_start", {"type": "content_block_start",
            "index": idx, "content_block": {"type": "tool_use", "id": call_id,
                                              "name": name, "input": {}}}))
        return out

    def _close_block(self):
        if self.open_block is None:
            return []
        idx = self.open_block["index"]
        self.open_block = None
        return [self._sse("content_block_stop", {"type": "content_block_stop", "index": idx})]

    def _handle_chunk(self, obj: dict):
        out = self._ensure_started(obj)
        choices = obj.get("choices") or []
        if not choices:
            return out
        choice = choices[0]
        delta = choice.get("delta") or {}

        text = delta.get("content")
        if text:
            self.saw_content = True
            if self.open_block is None or self.open_block["kind"] != "text":
                out.extend(self._open_text_block())
            self.output_chars += len(text)
            out.append(self._sse("content_block_delta", {"type": "content_block_delta",
                "index": self.open_block["index"], "delta": {"type": "text_delta", "text": text}}))

        for tc in delta.get("tool_calls") or []:
            oi = tc.get("index", 0)
            fn = tc.get("function") or {}
            if oi not in self.tool_index_map:
                self.saw_content = True
                out.extend(self._open_tool_block(
                    oi, tc.get("id") or f"toolu_{uuid.uuid4().hex[:24]}", fn.get("name") or ""))
            elif self.open_block is None or self.open_block.get("openai_index") != oi:
                log(f"openai stream: out-of-order tool_call delta for index {oi}; dropping fragment")
                continue
            frag = fn.get("arguments")
            if frag:
                self.output_chars += len(frag)
                out.append(self._sse("content_block_delta", {"type": "content_block_delta",
                    "index": self.open_block["index"],
                    "delta": {"type": "input_json_delta", "partial_json": frag}}))

        if choice.get("finish_reason"):
            self.stop_reason = FINISH_REASON_MAP.get(choice["finish_reason"], "end_turn")
            out.extend(self._close_and_finish())
        return out

    def _handle_error(self, obj: dict):
        out = [] if self.started else self._ensure_started({})
        message = (obj.get("error") or {}).get("message", "upstream error")
        if self.open_block is None or self.open_block["kind"] != "text":
            out.extend(self._open_text_block())
        text = f"\n\n[proxy: upstream error — {message}]"
        self.output_chars += len(text)
        self.saw_content = True
        out.append(self._sse("content_block_delta", {"type": "content_block_delta",
            "index": self.open_block["index"], "delta": {"type": "text_delta", "text": text}}))
        self.stop_reason = "end_turn"
        out.extend(self._close_and_finish())
        return out

    def _close_and_finish(self):
        if self.done:
            return []
        out = [] if self.started else self._ensure_started({})
        out.extend(self._close_block())
        self.done = True
        stop_reason = self.stop_reason or "end_turn"
        self.stop_reason = stop_reason
        out.append(self._sse("message_delta", {"type": "message_delta",
            "delta": {"stop_reason": stop_reason, "stop_sequence": None},
            "usage": {"output_tokens": max(1, self.output_chars // 4)}}))
        out.append(self._sse("message_stop", {"type": "message_stop"}))
        return out


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send_json(self, obj: dict) -> None:
        payload = json.dumps(obj).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _count_tokens(self, body: bytes) -> None:
        """Serve /v1/messages/count_tokens locally: Ollama 404s it, and Claude
        Code's fallback probing can kill the session. A rough estimate is all
        the context accounting needs."""
        try:
            data = json.loads(body) if body else {}
        except (ValueError, UnicodeDecodeError):
            data = {}
        text = json.dumps([data.get(k) for k in ("system", "messages", "tools")])
        self._send_json({"input_tokens": max(1, len(text) // 4)})

    def _relay(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        body = rewrite_body(body)

        if self.command == "POST" and self.path.startswith("/v1/messages/count_tokens"):
            return self._count_tokens(body)
        is_gen = self.command == "POST" and self.path.startswith("/v1/messages")

        # Auto-mode classifier requests (named CLASSIFIER_TRIGGER_MODEL, e.g.
        # Claude Code's hardcoded "claude-sonnet-5" default) get their `model`
        # field rewritten to CLASSIFIER_MODEL and are routed to the
        # classifier's own upstream via Ollama's NATIVE /api/chat (to force
        # num_gpu=0 — see CLASSIFIER_NUM_CTX's comment) — checked first so it
        # pre-empts the openai translation path below.
        if is_gen and CLASSIFIER_MODEL:
            try:
                data = json.loads(body)
            except (ValueError, UnicodeDecodeError):
                data = None
            if isinstance(data, dict) and data.get("model") == CLASSIFIER_TRIGGER_MODEL:
                data["model"] = CLASSIFIER_MODEL
                data = _trim_for_classifier_context(data)
                return self._relay_classifier(data, length)

        if is_gen and PROTOCOL == "openai":
            return self._relay_openai(body, length)

        return self._relay_generic(body, length, UPSTREAM, is_gen)

    def _relay_generic(self, body: bytes, length: int, upstream: str, is_gen: bool):
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_BY_HOP}
        headers["Content-Length"] = str(len(body))

        conn = http.client.HTTPConnection(upstream, timeout=600)
        t0 = time.time()
        total, carry = 0, b""
        saw_content = False
        stop_reason = None
        status = None
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            status = resp.status

            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in HOP_BY_HOP:
                    self.send_header(k, v)
            # Stream the response — never buffer (SSE tool-call deltas).
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = resp.read(4096)
                if not chunk:
                    break
                total += len(chunk)
                if is_gen:
                    window = carry + chunk
                    if not saw_content and b"content_block_start" in window:
                        saw_content = True
                    m = re.search(rb'\\?"stop_reason\\?"\s*:\s*\\?"(\w+)', window)
                    if m:
                        stop_reason = m.group(1).decode()
                    carry = window[-64:]
                self.wfile.write(b"%X\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            if is_gen:
                note = "" if saw_content else "  <-- EMPTY RESPONSE (no content block)"
                log(f"POST {self.path} -> {status} {time.time() - t0:.1f}s "
                    f"req={length}B resp={total}B stop={stop_reason}{note} "
                    f"upstream={upstream}")
        except Exception as exc:  # upstream died mid-stream; best-effort close
            log(f"relay error on {self.command} {self.path} "
                f"(status={status}, {total}B relayed): {exc}")
        finally:
            conn.close()

    def _relay_classifier(self, data: dict, length: int):
        """Auto-mode classifier path: translate the (already model-rewritten,
        context-trimmed) Anthropic request to Ollama-native /api/chat, force
        CPU (num_gpu=0 — see CLASSIFIER_NUM_CTX's comment for why), and
        translate the response back. Always calls Ollama non-streaming
        (classifier replies are a handful of tokens — not worth handling
        Ollama's own streaming line-framing for this); if the ORIGINAL
        request asked for stream:true, synthesizes a minimal single-shot
        Anthropic SSE sequence from the one blocking response instead of
        real incremental streaming."""
        requested_model = data.get("model") or "unknown"
        want_streaming = bool(data.get("stream"))
        ollama_body = json.dumps(to_ollama_native_request(data)).encode("utf-8")

        # Short timeout on purpose: this is a safety classifier, not the main
        # conversation — if trimming somehow still leaves it too large to
        # answer quickly, failing fast (and falling back to Claude Code's own
        # "continue with other tasks" degradation) beats blocking the whole
        # session for minutes. Live-measured normal (warm) case is well under
        # 1s; 45s leaves headroom for an occasional cold reload (keep_alive=-1
        # in to_ollama_native_request should make that rare, but ml-server
        # restarting or the model getting evicted some other way isn't ruled
        # out) without going back to the original 120s that caused the
        # multi-minute stalls this whole area of the code exists to avoid.
        conn = http.client.HTTPConnection(CLASSIFIER_UPSTREAM, timeout=45)
        t0 = time.time()
        status = None
        stop_reason = None
        saw_content = False
        resp_bytes = 0
        try:
            conn.request("POST", "/api/chat", body=ollama_body,
                         headers={"Content-Type": "application/json"})
            resp = conn.getresponse()
            status = resp.status
            raw = resp.read()
            resp_bytes = len(raw)

            if status != 200:
                payload = json.dumps(_openai_error_to_anthropic(status, raw)).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                stop_reason = f"http_{status}"
            else:
                try:
                    ollama_json = json.loads(raw)
                except (ValueError, UnicodeDecodeError):
                    ollama_json = None
                if not isinstance(ollama_json, dict) or "message" not in ollama_json:
                    payload = json.dumps(_openai_error_to_anthropic(200, raw)).encode("utf-8")
                    self.send_response(502)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    stop_reason = "malformed_upstream"
                else:
                    anth = ollama_native_to_anthropic_response(ollama_json, requested_model)
                    saw_content = bool(anth.get("content"))
                    stop_reason = anth.get("stop_reason")
                    if not want_streaming:
                        payload = json.dumps(anth).encode("utf-8")
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(payload)))
                        self.end_headers()
                        self.wfile.write(payload)
                    else:
                        self.send_response(200)
                        self.send_header("Content-Type", "text/event-stream")
                        self.send_header("Transfer-Encoding", "chunked")
                        self.end_headers()
                        for frame in _single_shot_anthropic_sse(anth):
                            self.wfile.write(b"%X\r\n%s\r\n" % (len(frame), frame))
                        self.wfile.write(b"0\r\n\r\n")
                        self.wfile.flush()
        except Exception as exc:  # classifier upstream died; best-effort close
            log(f"relay error on {self.command} {self.path} "
                f"(status={status}, {resp_bytes}B relayed): {exc}")
        finally:
            conn.close()

        note = "" if saw_content else "  <-- EMPTY RESPONSE (no content block)"
        classifier_mode = "native-cpu" if CLASSIFIER_NUM_GPU == 0 else "native-gpu"
        log(f"POST {self.path} -> {status} {time.time() - t0:.1f}s "
            f"req={length}B resp={resp_bytes}B stop={stop_reason}{note} "
            f"upstream={CLASSIFIER_UPSTREAM} classifier={classifier_mode}")

    def _relay_openai(self, body: bytes, length: int):
        """PROTOCOL=openai path for POST /v1/messages: translate Anthropic ->
        OpenAI, forward to UPSTREAM/v1/chat/completions, translate the
        response (JSON or SSE stream) back to Anthropic shape."""
        try:
            data = json.loads(body) if body else {}
        except (ValueError, UnicodeDecodeError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        requested_model = data.get("model") or "unknown"
        streaming = bool(data.get("stream"))
        input_tokens_estimate = _estimate_tokens(
            [data.get(k) for k in ("system", "messages", "tools")])
        openai_body = json.dumps(to_openai_request(data)).encode("utf-8")

        headers = {"Content-Type": "application/json",
                   "Authorization": f"Bearer {OPENAI_UPSTREAM_TOKEN}"}

        conn = http.client.HTTPConnection(UPSTREAM, timeout=600)
        t0 = time.time()
        status = None
        stop_reason = None
        saw_content = False
        resp_bytes = 0
        # Held for the FULL request+response cycle (including draining a
        # streamed response) — meshllm is busy with this client that whole
        # time, and needs other requests to wait their turn rather than race
        # in and get instantly 429'd. See UPSTREAM_LOCK's module-level comment.
        with UPSTREAM_LOCK:
            try:
                conn.request("POST", "/v1/chat/completions", body=openai_body, headers=headers)
                resp = conn.getresponse()
                status = resp.status

                if status != 200:
                    raw = resp.read()
                    resp_bytes = len(raw)
                    payload = json.dumps(_openai_error_to_anthropic(status, raw)).encode("utf-8")
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    stop_reason = f"http_{status}"

                elif not streaming:
                    raw = resp.read()
                    resp_bytes = len(raw)
                    try:
                        upstream_json = json.loads(raw)
                    except (ValueError, UnicodeDecodeError):
                        upstream_json = None
                    if not isinstance(upstream_json, dict) or "choices" not in upstream_json:
                        payload = json.dumps(_openai_error_to_anthropic(200, raw)).encode("utf-8")
                        self.send_response(502)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(payload)))
                        self.end_headers()
                        self.wfile.write(payload)
                        stop_reason = "malformed_upstream"
                    else:
                        anth = to_anthropic_response(upstream_json, requested_model)
                        saw_content = bool(anth.get("content"))
                        stop_reason = anth.get("stop_reason")
                        payload = json.dumps(anth).encode("utf-8")
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(payload)))
                        self.end_headers()
                        self.wfile.write(payload)

                else:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    translator = AnthropicStreamTranslator(requested_model, input_tokens_estimate)
                    while True:
                        chunk = resp.read(4096)
                        if not chunk:
                            break
                        resp_bytes += len(chunk)
                        for frame in translator.feed(chunk):
                            self.wfile.write(b"%X\r\n%s\r\n" % (len(frame), frame))
                        self.wfile.flush()
                    for frame in translator.finish():
                        self.wfile.write(b"%X\r\n%s\r\n" % (len(frame), frame))
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                    saw_content = translator.saw_content
                    stop_reason = translator.stop_reason
            except Exception as exc:  # upstream died mid-stream; best-effort close
                log(f"relay error on {self.command} {self.path} "
                    f"(status={status}, {resp_bytes}B relayed): {exc}")
            finally:
                conn.close()

        note = "" if saw_content else "  <-- EMPTY RESPONSE (no content block)"
        log(f"POST {self.path} -> {status} {time.time() - t0:.1f}s "
            f"req={length}B resp={resp_bytes}B stop={stop_reason}{note} proto=openai")

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = _relay

    def log_message(self, *_):  # quiet; the ollama log is the source of truth
        pass


class QuietServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # Clients (Claude Code's connection pool) reset idle keep-alive
        # connections constantly; that's normal, not worth a traceback.
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, BrokenPipeError, TimeoutError)):
            return
        super().handle_error(request, client_address)


if __name__ == "__main__":
    print(f">> hangarbaycc-proxy: :{LISTEN_PORT} -> {UPSTREAM} "
          f"(protocol={PROTOCOL}, temperature -> [{TEMP_FLOOR}, {TEMP_CEIL}], "
          f"top_p <= {TOP_P_CEIL}, repeat_penalty -> {REPEAT_PENALTY}, "
          f"strip_tools = {sorted(STRIP_TOOLS) or 'none'}, "
          f"count_tokens served locally)", flush=True)
    QuietServer(("127.0.0.1", LISTEN_PORT), Proxy).serve_forever()

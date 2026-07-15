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
Defaults: 11435  127.0.0.1:11434  0.55  0.70  0.95  ""  ollama  ""  127.0.0.1:11434  claude-sonnet-5
"""
import http.client
import json
import re
import sys
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
        # classifier's own upstream via plain passthrough, regardless of
        # PROTOCOL — checked first so it pre-empts the openai translation
        # path below.
        if is_gen and CLASSIFIER_MODEL:
            try:
                data = json.loads(body)
            except (ValueError, UnicodeDecodeError):
                data = None
            if isinstance(data, dict) and data.get("model") == CLASSIFIER_TRIGGER_MODEL:
                data["model"] = CLASSIFIER_MODEL
                body = json.dumps(data).encode("utf-8")
                return self._relay_generic(body, len(body), CLASSIFIER_UPSTREAM, is_gen)

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

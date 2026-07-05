#!/usr/bin/env python3
"""
hangarbaycc-proxy.py — transparent reverse proxy in front of the Ollama server.

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

Usage:
    hangarbaycc-proxy.py [LISTEN_PORT] [UPSTREAM_HOSTPORT] [TEMP_FLOOR] [TEMP_CEIL]
                         [TOP_P_CEIL] [STRIP_TOOLS]
Defaults: 11435  127.0.0.1:11434  0.55  0.70  0.95  ""
"""
import http.client
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 11435
UPSTREAM = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1:11434"
TEMP_FLOOR = float(sys.argv[3]) if len(sys.argv) > 3 else 0.55
TEMP_CEIL = float(sys.argv[4]) if len(sys.argv) > 4 else 0.70
TOP_P_CEIL = float(sys.argv[5]) if len(sys.argv) > 5 else 0.95
STRIP_TOOLS = {t.strip() for t in (sys.argv[6] if len(sys.argv) > 6 else "").split(",") if t.strip()}
REPEAT_PENALTY = 1.2
REPEAT_LAST_N = 256

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

        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_BY_HOP}
        headers["Content-Length"] = str(len(body))

        conn = http.client.HTTPConnection(UPSTREAM, timeout=600)
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
                    f"req={length}B resp={total}B stop={stop_reason}{note}")
        except Exception as exc:  # upstream died mid-stream; best-effort close
            log(f"relay error on {self.command} {self.path} "
                f"(status={status}, {total}B relayed): {exc}")
        finally:
            conn.close()

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
          f"(temperature -> [{TEMP_FLOOR}, {TEMP_CEIL}], top_p <= {TOP_P_CEIL}, "
          f"repeat_penalty -> {REPEAT_PENALTY}, "
          f"strip_tools = {sorted(STRIP_TOOLS) or 'none'}, "
          f"count_tokens served locally)", flush=True)
    QuietServer(("127.0.0.1", LISTEN_PORT), Proxy).serve_forever()

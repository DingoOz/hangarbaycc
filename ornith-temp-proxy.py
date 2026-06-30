#!/usr/bin/env python3
"""
ornith-temp-proxy.py — transparent reverse proxy in front of the Ollama server.

Claude Code sends `temperature: 1.0` on every /v1/messages request, which
overrides Ornith's preferred sampling and makes a 9B model produce far more
malformed / hallucinated tool calls. Ollama honours the request value over the
Modelfile, and Claude Code has no temperature flag — so we clamp it here.

We clamp temperature into a *band* [TEMP_FLOOR, TEMP_CEIL] rather than pinning it
to a single low value. Pinning near-greedy (the old temp=0.4) keeps tool calls
clean but makes a small model prone to agentic repetition loops: when the context
keeps re-presenting an identical state, the argmax next-action reproduces that
state, which re-feeds the same context — a self-reinforcing fixed point. A band
keeps enough entropy to escape the loop while still cutting malformed tool calls.

We also inject `repeat_penalty` / `repeat_last_n` to suppress the *within-a-single-
generation* runaway (e.g. the same method emitted over and over). These are Ollama
sampling options; if the upstream Anthropic-compat adapter doesn't forward them to
the model they are simply ignored — harmless either way. Note they do NOT help the
across-turn agentic loop (penalties only apply within one decode); the temperature
band is the lever for that.

Everything else is forwarded verbatim to UPSTREAM. All other routes
(/api/version, /api/tags, model preload, ...) pass straight through, so
`ollama launch claude` can be pointed at this port instead of the real server.

Usage:
    ornith-temp-proxy.py [LISTEN_PORT] [UPSTREAM_HOSTPORT] [TEMP_FLOOR] [TEMP_CEIL]
Defaults: 11435  127.0.0.1:11434  0.55  0.70
"""
import http.client
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 11435
UPSTREAM = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1:11434"
TEMP_FLOOR = float(sys.argv[3]) if len(sys.argv) > 3 else 0.55
TEMP_CEIL = float(sys.argv[4]) if len(sys.argv) > 4 else 0.70
TOP_P_CEIL = 0.95
REPEAT_PENALTY = 1.2
REPEAT_LAST_N = 256

# Headers that must not be copied between hops.
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "content-length",
}


def rewrite_body(body: bytes) -> bytes:
    """Clamp temperature into a band, cap top_p, and inject anti-repetition
    options in a JSON body; pass anything else unchanged."""
    if not body:
        return body
    try:
        data = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return body
    if not isinstance(data, dict):
        return body
    changed = False

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

    def _relay(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        body = rewrite_body(body)

        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_BY_HOP}
        headers["Content-Length"] = str(len(body))

        conn = http.client.HTTPConnection(UPSTREAM, timeout=600)
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()

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
                self.wfile.write(b"%X\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except Exception as exc:  # upstream died mid-stream; best-effort close
            sys.stderr.write(f"[proxy] relay error: {exc}\n")
        finally:
            conn.close()

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = _relay

    def log_message(self, *_):  # quiet; the ollama log is the source of truth
        pass


if __name__ == "__main__":
    print(f">> ornith-temp-proxy: :{LISTEN_PORT} -> {UPSTREAM} "
          f"(temperature -> [{TEMP_FLOOR}, {TEMP_CEIL}], "
          f"repeat_penalty -> {REPEAT_PENALTY})", flush=True)
    ThreadingHTTPServer(("127.0.0.1", LISTEN_PORT), Proxy).serve_forever()

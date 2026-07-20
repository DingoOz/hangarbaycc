#!/usr/bin/env python3
"""searxng-mcp/server.py — MCP stdio server exposing a `web_search` tool
backed by a SearXNG instance's JSON API.

Written by hand against the official `mcp` SDK (installed into
searxng-mcp/.venv by hangarbaycc.sh's ensure_searxng()) rather than one of
the existing npm searxng-mcp packages, since this machine has no Node/npm and
the project already treats "vendor it, no extra toolchain" as the norm (see
grok-local-server.sh). Uses only the stdlib for HTTP (urllib) so the venv's
only real dependency is `mcp` itself.

SearXNG's JSON format is disabled by default (public instances get scraped
otherwise) — searxng-settings.yml (vendored alongside searxng-server.sh)
turns it on for this private, non-internet-facing instance.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

from mcp.server.fastmcp import FastMCP

# CLI arg takes precedence over the env var: grok's [mcp_servers] stdio config
# (config.toml) only documents `command`/`args`, no `env` table, so
# ensure_searxng() in hangarbaycc.sh passes the URL as argv[1] there. Claude
# Code's --mcp-config JSON does support `env`, which is used instead for that
# path — either way this script accepts both.
SEARXNG_URL = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SEARXNG_URL", "http://127.0.0.1:8889")).rstrip("/")
TIMEOUT = float(os.environ.get("SEARXNG_MCP_TIMEOUT", "15"))

mcp = FastMCP("searxng")


@mcp.tool()
def web_search(query: str, num_results: int = 5) -> str:
    """Search the web via a local SearXNG instance and return the top results.

    Args:
        query: The search query.
        num_results: Maximum number of results to return (default 5, capped at 20).
    """
    num_results = max(1, min(int(num_results), 20))
    params = urllib.parse.urlencode({"q": query, "format": "json"})
    url = f"{SEARXNG_URL}/search?{params}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.load(resp)
    except urllib.error.URLError as e:
        return f"Error: could not reach SearXNG at {SEARXNG_URL} ({e})."
    except json.JSONDecodeError as e:
        return f"Error: SearXNG response wasn't valid JSON ({e}). Is the JSON format enabled in settings.yml?"

    results = data.get("results", [])[:num_results]
    if not results:
        return f"No results for '{query}'."

    lines = []
    for i, r in enumerate(results, 1):
        title = r.get("title", "(no title)")
        link = r.get("url", "")
        snippet = (r.get("content") or "").strip()
        lines.append(f"{i}. {title}\n   {link}\n   {snippet}" if snippet else f"{i}. {title}\n   {link}")
    return "\n\n".join(lines)


if __name__ == "__main__":
    if not SEARXNG_URL:
        print("!! SEARXNG_URL is empty.", file=sys.stderr)
        sys.exit(1)
    mcp.run(transport="stdio")

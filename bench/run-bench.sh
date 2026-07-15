#!/usr/bin/env bash
#
# run-bench.sh — run the C/C++/Python task set against a local model and emit
# a pass/fail scorecard.
#
# Usage:
#   bench/run-bench.sh MODEL [HOSTPORT]
#
#   MODEL     e.g. ornith:latest, gpt-oss:20b (must be loadable by the server),
#             or meshllm/Qwen3-30B-A3B-Q4_K_M-layers for the LAN meshllm server.
#   HOSTPORT  Endpoint to hit. Default 127.0.0.1:11434 (the raw Ollama server =
#             the model's own sampling). Point it at 127.0.0.1:11435 instead to
#             bench THROUGH the temp proxy and measure a temp band. For meshllm,
#             pass its host:port, e.g. 192.168.1.16:9337.
#
#   Protocol is auto-detected from MODEL: a `meshllm/` prefix means an
#   OpenAI-compatible /v1/chat/completions endpoint; anything else assumes
#   Ollama's Anthropic-compat /v1/messages endpoint.
#
#   Example: bench/run-bench.sh "meshllm/Qwen3-30B-A3B-Q4_K_M-layers" 192.168.1.16:9337
#
# The server must already be running (hangarbaycc.sh starts one, or:
#   OLLAMA_CONTEXT_LENGTH=32768 ollama serve).
# Each task sends one prompt, extracts the fenced code block from the reply,
# and runs the task's check.sh on it. Results land in bench/results/.
#
set -uo pipefail

MODEL="${1:?usage: run-bench.sh MODEL [HOSTPORT]}"
HOSTPORT="${2:-127.0.0.1:11434}"
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_DIR="$BENCH_DIR/tasks"
RESULTS_DIR="$BENCH_DIR/results"
WORK="$(mktemp -d /tmp/hangarbaycc-bench.XXXXXX)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$RESULTS_DIR/${MODEL//[:\/]/_}-$STAMP.md"
mkdir -p "$RESULTS_DIR"

PROTO="anthropic"
[[ "$MODEL" == meshllm/* ]] && PROTO="openai"

if [[ "$PROTO" == "openai" ]]; then
  if ! curl -sf --max-time 3 "http://$HOSTPORT/v1/models" >/dev/null; then
    echo "!! No OpenAI-compatible endpoint at $HOSTPORT — check the meshllm server." >&2
    exit 1
  fi
else
  if ! curl -sf --max-time 3 "http://$HOSTPORT/api/version" >/dev/null; then
    echo "!! No Ollama endpoint at $HOSTPORT — start the server (or proxy) first." >&2
    exit 1
  fi
fi

echo "# hangarbaycc-bench: $MODEL" > "$OUT"
{
  echo ""
  echo "- endpoint: \`$HOSTPORT\`"
  echo "- date: $(date -Is)"
  echo "- bench shell env: ctx=${OLLAMA_CONTEXT_LENGTH:-?} kv=${OLLAMA_KV_CACHE_TYPE:-?} (server may differ if launched elsewhere)"
  echo ""
  echo "| task | lang | result | time | note |"
  echo "|---|---|---|---|---|"
} >> "$OUT"

pass=0 total=0
for dir in "$TASKS_DIR"/*/; do
  name="$(basename "$dir")"
  # dir name convention: NN-<lang>-<slug>, lang in {c,cpp,py}
  lang="$(echo "$name" | cut -d- -f2)"
  case "$lang" in
    c)   ext=c ;;
    cpp) ext=cpp ;;
    py)  ext=py ;;
    *) echo "!! skipping $name (unknown lang '$lang')" >&2; continue ;;
  esac
  total=$((total + 1))
  tdir="$WORK/$name"; mkdir -p "$tdir"
  t0=$(date +%s)

  payload="$(python3 - "$MODEL" "$dir/prompt.md" <<'PY'
import json, sys
prompt = open(sys.argv[2]).read().strip()
prompt += ("\n\nReply with exactly ONE fenced code block containing the "
           "complete program, and nothing else.")
print(json.dumps({"model": sys.argv[1], "max_tokens": 8192,
                  "messages": [{"role": "user", "content": prompt}]}))
PY
)"
  if [[ "$PROTO" == "openai" ]]; then
    resp="$(curl -s --max-time 900 "http://$HOSTPORT/v1/chat/completions" \
      -H 'content-type: application/json' -H 'Authorization: Bearer mesh' \
      -d "$payload")"
  else
    resp="$(curl -s --max-time 900 "http://$HOSTPORT/v1/messages" \
      -H 'content-type: application/json' -H 'x-api-key: ollama' \
      -H 'anthropic-version: 2023-06-01' -d "$payload")"
  fi

  note=""
  if ! printf '%s' "$resp" | python3 "$BENCH_DIR/extract-code.py" \
       > "$tdir/solution.$ext" 2>"$tdir/extract.err"; then
    result="NO CODE"
    note="$(head -c 120 "$tdir/extract.err" | tr '|\n' ' ')"
  elif check_out="$(bash "$dir/check.sh" "$tdir/solution.$ext" 2>"$tdir/check.err")"; then
    result="PASS"; pass=$((pass + 1))
  else
    result="FAIL"
    note="$(echo "$check_out" | head -1 | head -c 120 | tr '|' ' ')"
  fi
  dt=$(( $(date +%s) - t0 ))
  echo "| $name | $lang | $result | ${dt}s | $note |" >> "$OUT"
  echo ">> $name: $result (${dt}s) $note"
done

{
  echo ""
  echo "**Score: $pass / $total**"
} >> "$OUT"
echo ""
echo ">> Score: $pass/$total — scorecard: $OUT (solutions kept in $WORK)"

#!/usr/bin/env bash
#
# hangarbay-dictate.sh — voice dictation for HangarBayCC. Bind this to a DE
#                        hotkey: press once to start recording, press again
#                        to stop, transcribe (via whisper-server on the GPU
#                        host), and type the result into whatever window is
#                        focused (normally the Claude Code TUI).
#
# Usage:
#   hangarbay-dictate.sh [--stdout | --clipboard] [--server HOST:PORT]
#
#   --stdout      print the transcript instead of typing it
#   --clipboard   copy the transcript (wl-copy) instead of typing it
#   --server      whisper-server address; default resolution order is:
#                 --server flag > $HANGARBAY_WHISPER env var >
#                 ${XDG_RUNTIME_DIR:-/tmp}/hangarbay-whisper-endpoint (written
#                 by hangarbaycc.sh when it starts whisper) > ml-server:11436
#
# Requires on this (laptop) machine: one of pw-record/parecord/arecord to
# record; curl; python3 (stdlib only, for JSON parsing); one of wtype/ydotool
# to type into the focused window (ydotool also needs ydotoold running);
# optionally notify-send and wl-copy.
#
set -euo pipefail

MODE="type"
SERVER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stdout)    MODE="stdout"; shift ;;
    --clipboard) MODE="clipboard"; shift ;;
    --server)    SERVER="${2:?--server requires HOST:PORT}"; shift 2 ;;
    --server=*)  SERVER="${1#*=}"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^#//; s/^ //'; exit 0 ;;
    *) echo "!! Unknown argument: $1" >&2; exit 1 ;;
  esac
done

ENDPOINT_FILE="${XDG_RUNTIME_DIR:-/tmp}/hangarbay-whisper-endpoint"
if [[ -z "$SERVER" ]]; then
  SERVER="${HANGARBAY_WHISPER:-}"
fi
if [[ -z "$SERVER" && -f "$ENDPOINT_FILE" ]]; then
  SERVER="$(cat "$ENDPOINT_FILE")"
fi
SERVER="${SERVER:-ml-server:11436}"

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/hangarbay-dictate"
mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/rec.pid"
WAV_FILE="$STATE_DIR/rec.wav"

notify() {
  local msg="$1"
  echo ">> $msg" >&2
  command -v notify-send >/dev/null && notify-send "HangarBayCC Dictation" "$msg" || true
}

# --- toggle: is a recording already in progress? ------------------------------
if [[ -f "$PID_FILE" ]]; then
  REC_PID="$(cat "$PID_FILE")"
  if kill -0 "$REC_PID" 2>/dev/null; then
    # --- stop path: finalize the recording and transcribe ---------------------
    kill -INT "$REC_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$REC_PID" 2>/dev/null || break
      sleep 0.1
    done
    rm -f "$PID_FILE"

    if [[ ! -s "$WAV_FILE" ]]; then
      notify "no audio captured"
      exit 1
    fi
    WAV_BYTES="$(stat -c %s "$WAV_FILE" 2>/dev/null || stat -f %z "$WAV_FILE")"
    if [[ "$WAV_BYTES" -lt 32000 ]]; then
      notify "recording too short — try again and speak a bit longer"
      rm -f "$WAV_FILE"
      exit 1
    fi

    RESPONSE="$(curl -sf --max-time 60 "http://${SERVER}/inference" \
      -F "file=@${WAV_FILE}" \
      -F "response_format=json" \
      -F "temperature=0.0" \
      -F "temperature_inc=0.2" 2>/dev/null || true)"

    if [[ -z "$RESPONSE" ]]; then
      notify "transcription failed — server unreachable; audio kept at $WAV_FILE"
      exit 1
    fi

    TEXT="$(python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
text = data.get("text", "")
# Strip whisper non-speech markers regardless of case/bracket style, e.g.
# [BLANK_AUDIO], [silence], (Silence), [no_speech], [inaudible].
text = re.sub(r"[\[(]\s*(blank[_ ]audio|silence|no[_ ]speech|inaudible)\s*[\])]", "", text, flags=re.IGNORECASE)
print(" ".join(text.split()))
' <<<"$RESPONSE")"

    rm -f "$WAV_FILE"

    if [[ -z "$TEXT" ]]; then
      notify "empty transcript"
      exit 1
    fi

    case "$MODE" in
      stdout)
        printf '%s\n' "$TEXT"
        ;;
      clipboard)
        if command -v wl-copy >/dev/null; then
          printf '%s' "$TEXT" | wl-copy
          notify "transcript copied to clipboard"
        else
          echo "!! wl-copy not found." >&2
          printf '%s\n' "$TEXT"
        fi
        ;;
      type)
        if command -v wtype >/dev/null && wtype -- "$TEXT" 2>/dev/null; then
          :
        elif command -v ydotool >/dev/null && ydotool type -- "$TEXT" 2>/dev/null; then
          :
        elif command -v wl-copy >/dev/null; then
          printf '%s' "$TEXT" | wl-copy
          notify "typing failed (no working wtype/ydotool) — copied to clipboard, paste with Ctrl+Shift+V"
        else
          notify "typing failed and no clipboard tool available — transcript: $TEXT"
        fi
        ;;
    esac
    exit 0
  else
    rm -f "$PID_FILE"
  fi
fi

# --- start path: probe the server, then start recording -----------------------
if ! curl -sf --max-time 2 "http://${SERVER}/" >/dev/null 2>&1; then
  notify "whisper server unreachable at $SERVER — is dictation enabled? (hangarbaycc.sh --dictate)"
  exit 1
fi

RECORDER=""
if command -v pw-record >/dev/null; then
  RECORDER=(pw-record --rate=16000 --channels=1 --format=s16 "$WAV_FILE")
elif command -v parecord >/dev/null; then
  RECORDER=(parecord --rate=16000 --channels=1 --format=s16le --file-format=wav "$WAV_FILE")
elif command -v arecord >/dev/null; then
  RECORDER=(arecord -f S16_LE -r 16000 -c 1 "$WAV_FILE")
else
  echo "!! No recorder found (need pw-record, parecord, or arecord)." >&2
  exit 1
fi

rm -f "$WAV_FILE"
setsid nohup "${RECORDER[@]}" >/tmp/hangarbay-dictate-rec.log 2>&1 &
echo $! > "$PID_FILE"
disown

notify "recording... (press the hotkey again to stop)"

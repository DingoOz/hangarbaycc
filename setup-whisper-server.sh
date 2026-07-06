#!/usr/bin/env bash
#
# setup-whisper-server.sh — one-time provisioning of whisper.cpp (CUDA build)
#                            on the GPU host, for HangarBayCC's optional voice
#                            dictation feature.
#
# Usage:
#   ./setup-whisper-server.sh [HOST]     HOST defaults to 'ml-server'; anything
#                                         `ssh HOST` accepts works. Runs the
#                                         whole setup on HOST over SSH.
#
# Idempotent: re-running skips the clone (does a `git pull` instead) and skips
# the model download if the file is already there.
#
# Disk note: builds and models live under ~/whisper.cpp on the target host,
# NOT in the Ollama model store (/var/lib/ollama/models) — that store holds
# Ollama manifests only. Only ONE model is ever downloaded (small.en-q8_0 by
# default); this script never speculatively pulls multiple sizes, since the
# target host may be short on disk.
#
set -euo pipefail

HOST="${1:-ml-server}"
MODEL="${WHISPER_MODEL:-small.en-q8_0}"
MIN_FREE_MB=3000

echo ">> Provisioning whisper.cpp on '$HOST' (model: $MODEL)..."

if ! ssh -o ConnectTimeout=5 "$HOST" true; then
  echo "!! Could not reach '$HOST' over SSH." >&2
  echo "!! Check the host is up and 'ssh $HOST' works by hand." >&2
  exit 1
fi

ssh "$HOST" MODEL="$MODEL" MIN_FREE_MB="$MIN_FREE_MB" bash -s <<'REMOTE'
set -euo pipefail

echo ">> [remote] Preflight checks..."
if ! command -v nvidia-smi >/dev/null || ! nvidia-smi >/dev/null 2>&1; then
  echo "!! nvidia-smi failed on this host — GPU unavailable." >&2
  exit 1
fi
for tool in git cmake make gcc; do
  if ! command -v "$tool" >/dev/null; then
    echo "!! Missing build tool: $tool. Install it first (e.g. sudo apt install $tool)." >&2
    exit 1
  fi
done
NVCC=""
for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-12/bin/nvcc "$(command -v nvcc 2>/dev/null || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then NVCC="$candidate"; break; fi
done
if [[ -z "$NVCC" ]]; then
  echo "!! No nvcc found (checked /usr/local/cuda/bin, /usr/local/cuda-12/bin, PATH)." >&2
  echo "!! Install the CUDA toolkit (e.g. sudo apt install nvidia-cuda-toolkit) first." >&2
  exit 1
fi
echo ">> Using nvcc: $NVCC"

FREE_MB="$(df -Pk "$HOME" | awk 'NR==2{print int($4/1024)}')"
if [[ "$FREE_MB" -lt "$MIN_FREE_MB" ]]; then
  echo "!! Only ${FREE_MB}MB free on this host's disk — need ~${MIN_FREE_MB}MB for" >&2
  echo "!! the whisper.cpp CUDA build + model. Free up space first." >&2
  exit 1
fi
echo ">> Disk OK: ${FREE_MB}MB free."

WHISPER_DIR="$HOME/whisper.cpp"
if [[ -d "$WHISPER_DIR/.git" ]]; then
  echo ">> [remote] Updating existing whisper.cpp checkout..."
  git -C "$WHISPER_DIR" pull --ff-only
else
  echo ">> [remote] Cloning whisper.cpp..."
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$WHISPER_DIR"
fi

echo ">> [remote] Building with CUDA (this GPU is Blackwell/sm_120; nvcc here"
echo ">> cannot codegen it natively, so we build PTX-only and let the driver"
echo ">> JIT it at first load — a one-time delay, not a per-request cost)..."
cd "$WHISPER_DIR"
cmake -B build -DGGML_CUDA=1 \
  -DCMAKE_CUDA_COMPILER="$NVCC" \
  -DCMAKE_CUDA_ARCHITECTURES=89-virtual
cmake --build build -j --config Release

if [[ ! -x build/bin/whisper-server ]]; then
  echo "!! Build finished but build/bin/whisper-server is missing." >&2
  exit 1
fi

mkdir -p models
MODEL_FILE="models/ggml-${MODEL}.bin"
if [[ ! -f "$MODEL_FILE" ]]; then
  echo ">> [remote] Downloading model: $MODEL..."
  if ! sh models/download-ggml-model.sh "$MODEL"; then
    echo "!! Quantized download failed; falling back to fp16 + local quantize." >&2
    BASE="${MODEL%-q8_0}"
    sh models/download-ggml-model.sh "$BASE"
    ./build/bin/whisper-quantize "models/ggml-${BASE}.bin" "$MODEL_FILE" q8_0
    rm -f "models/ggml-${BASE}.bin"
  fi
else
  echo ">> [remote] Model already present: $MODEL_FILE"
fi

echo ">> [remote] Smoke test (transcribing samples/jfk.wav)..."
if [[ ! -f samples/jfk.wav ]]; then
  bash ./models/download-ggml-model.sh --help >/dev/null 2>&1 || true
  echo "!! samples/jfk.wav missing from the checkout — skipping smoke test." >&2
else
  ./build/bin/whisper-cli -m "$MODEL_FILE" -f samples/jfk.wav 2>&1 | tee /tmp/whisper-smoke-test.log
  if ! grep -qi "ask not what your country" /tmp/whisper-smoke-test.log; then
    echo "!! Smoke test transcript didn't contain the expected JFK line — check /tmp/whisper-smoke-test.log" >&2
    exit 1
  fi
  if ! grep -qi "CUDA" /tmp/whisper-smoke-test.log; then
    echo "!! No CUDA device mentioned in the log — build may have fallen back to CPU. Check /tmp/whisper-smoke-test.log" >&2
  fi
  echo ">> Smoke test passed (transcript matched, see /tmp/whisper-smoke-test.log for full output)."
fi

echo ">> Disk after build/download: $(df -Pk "$HOME" | awk 'NR==2{print int($4/1024)"MB free"}')"
echo ">> Setup complete. hangarbaycc.sh's --dictate flag can now start whisper-server."
REMOTE

echo ">> Done. Run ./hangarbaycc.sh --remote $HOST --dictate (or answer 'y' at the dictation prompt)."

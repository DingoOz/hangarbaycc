# HangarBayCC --remote mode: client-side test checklist

Run this from a Claude Code session **on the laptop**, against ml-server as
the remote GPU host. Everything below is unverified from the ml-server side
(no second machine was available there) — this is the real first test of the
SSH-specific code paths.

## 0. Prerequisites check

```bash
which ollama claude python3 ssh   # all must be present on the laptop
ssh -o ConnectTimeout=5 ml-server true && echo "ssh OK"
```

If `ssh ... true` prompts for a password: it'll work, but the launcher makes
**4 separate SSH connections** per run (preflight, GPU check, systemd stop,
store-detection + server-start use 2 more) — expect several password prompts
unless key-based auth is set up. If it's painful, set up a key first:

```bash
ssh-copy-id ml-server
```

## 1. Clone and get the repo

```bash
git clone https://github.com/DingoOz/hangarbaycc.git
cd hangarbaycc
```

## 2. Basic connectivity + help

```bash
./hangarbaycc.sh --help
```

Expect the usage text and a clean exit (code 0), no ssh calls yet.

## 3. Preflight failure path (sanity-check the error handling)

```bash
./hangarbaycc.sh --remote nonexistent-host-xyz
```

Expect: a clear "Could not reach 'nonexistent-host-xyz' over SSH" error with
the ssh-copy-id hint, exit before any model-selection prompt appears.

## 4. Real run — smallest model first (ornith, 32K, q8_0)

```bash
./hangarbaycc.sh --remote ml-server
```

Answer: `1` (ornith:latest), `1` (32K), `2` (q8_0). Watch for, in order:

1. `>> Remote mode: Ollama server on 'ml-server'; ...`
2. Model store line: `>> Model: ornith:latest (store: /var/lib/ollama/models on ml-server)`
   — confirms the SSH-based store-detection heredoc correctly inspected
   ml-server's filesystem, not the laptop's.
3. `>> Stopping any existing server on ml-server...` — may prompt for a sudo
   password (that's the `ssh -t` systemd-stop step; only happens if ml-server's
   systemd `ollama` unit was active).
4. `>> Starting ollama serve on ml-server...` — should return promptly (a few
   seconds), not hang. If it hangs past ~30s you'll get a timeout error with a
   firewall/log hint instead of an infinite wait.
5. `>> Preloading...` then an `ollama ps` table showing `100% GPU`.
6. `>> Starting temperature proxy (:11435 -> ml-server:11434, ...)` — confirms
   the **proxy's upstream is ml-server**, not localhost.
7. Claude Code launches normally. Ask it something trivial ("write a hello
   world in C, compile and run it") and confirm it responds and can use
   tools (Bash/Edit/Write) — this exercises the full proxy round-trip to the
   remote model.
8. Exit Claude Code (Ctrl-D or `/exit`). Confirm the final message:
   `>> To restore the system Ollama service on ml-server: ssh -t ml-server sudo systemctl start ollama`

## 5. Verify state after exit

From the laptop:
```bash
pgrep -af hangarbaycc-proxy   # should be EMPTY — proxy killed on exit
```
From ml-server (or via ssh from the laptop):
```bash
ssh ml-server 'ollama ps'    # model should still show loaded (kept warm)
ssh ml-server 'curl -s http://127.0.0.1:11434/api/ps'
```

## 6. Things that would indicate a real bug (not expected, but check)

- Model store detection returns empty / "not found" even though the model
  exists on ml-server → the SSH heredoc's `\$HOME` escaping broke, or the
  remote login shell isn't bash-compatible for `[[ ]]`.
- The launcher hangs indefinitely at "Starting ollama serve" or "Preloading"
  → either the bounded `wait_for_http` retry logic isn't working, or
  ml-server's firewall is blocking port 11434 from the laptop's subnet
  (check `ssh ml-server sudo ufw status`, or equivalent).
- Claude Code's replies come back garbled/malformed tool calls at a much
  higher rate than a local session → possible network latency interacting
  badly with something (unlikely, but worth flagging if seen).
- After Claude Code exits, `hangarbaycc-proxy` is still running → the EXIT
  trap didn't fire (check how the laptop's shell/terminal handled the exit).

## 7. Second run — bigger model (gpt-oss:20b, 128K, q8_0)

Repeat step 4 with `4` / `3` / `2`. This is the "real" daily-driver config per
the bench results (gpt-oss 8/8 vs ornith 4/8). Confirm the fit-table numbers
in the script header still hold (`ollama ps` should show ~12.2 GB, 100% GPU).

## 8. Report back

For each step, note: did it work as described, or what differed? Particularly
useful: the exact text of step 4.2 (store line) and 4.6 (proxy upstream line)
copy-pasted, since those two lines are the clearest proof the remote plumbing
is actually hitting ml-server and not silently falling back to localhost.

## 9. Voice dictation

Only relevant with `--remote`. Do this after the basic remote-mode checks
above pass.

1. **Disk check before setup:** `ssh ml-server df -h /` — note free space
   (ml-server has been observed at ~97% full; the setup script aborts early
   if free space is under ~3 GB rather than failing mid-build).
2. **One-time setup:** `./setup-whisper-server.sh ml-server`. Expect: CUDA
   toolkit found (`nvcc`), a successful `cmake`/build (watch for the Blackwell
   PTX note — `-DCMAKE_CUDA_ARCHITECTURES=89-virtual`, not a native `sm_120`
   failure), the model downloaded, and a smoke-test transcript of
   `samples/jfk.wav` containing "ask not what your country" and a `CUDA`
   mention in the log.
3. **Disk check after setup:** `ssh ml-server df -h /` again — confirm the
   build + model didn't eat an unexpectedly large chunk of the remaining
   space.
4. **Launch with dictation:** `./hangarbaycc.sh --remote ml-server --dictate`
   (or answer `y` at the "Enable voice dictation?" prompt). Watch for, in
   order, after the existing spill-guard "Fully on GPU" line:
   - `>> Starting whisper-server on ml-server (:11436, NNNN MiB free)...`
   - `>> Dictation ready: bind a hotkey to .../hangarbay-dictate.sh ...`
5. **Verify placement:** `ssh ml-server nvidia-smi` shows both the Ollama
   runner and `whisper-server` processes, total VRAM well under 16 GB, no
   spill reported by the launcher.
6. **Manual round trip (no mic needed):** copy a WAV sample to the laptop and
   `curl -sf http://ml-server:11436/inference -F file=@sample.wav -F
   response_format=json` — expect JSON with a `text` field.
7. **Hotkey end-to-end:** bind `hangarbay-dictate.sh` to a hotkey (or run it
   directly from a terminal twice). First run: recording-started
   notification. Speak a sentence. Second run: transcript appears — typed
   into the focused window if using the default mode, printed with
   `--stdout`, or copied to the clipboard with `--clipboard`.
8. **Injection path:** note which of `wtype` / `ydotool` / clipboard-fallback
   actually fired — GNOME on Wayland is expected to fail `wtype` and need
   `ydotool` + `ydotoold` running.
9. **Negative paths:**
   - Run `hangarbay-dictate.sh` while whisper-server is stopped → immediate
     "server unreachable" notification, no recording started.
   - Start and immediately stop (sub-second) → "recording too short" message.
   - Record silence → "empty transcript" message, nothing typed.
10. **After exit:** `ssh ml-server pgrep -x whisper-server` → still running
    (left warm, like Ollama). Confirm the next launch's cleanup step
    (`pkill -x whisper-server`) reaps it before the new session starts.
11. **VRAM-skip path:** temporarily set a very high threshold
    (`WHISPER_MIN_FREE_MIB` in `hangarbaycc.sh`, or load a bigger
    context/model first) and confirm the launcher warns and skips dictation
    without aborting the Claude Code session.

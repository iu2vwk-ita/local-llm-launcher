# Local LLM Launcher

Windows scripts to run GGUF models locally with [llama.cpp](https://github.com/ggml-org/llama.cpp)
and point AI coding tools (Claude Code, OpenCode, the Pi agent) at them.

Everything is plain batch / PowerShell / Node - no build step and no dependencies beyond the
llama.cpp release binaries and Node.js (only for the proxy).

Author: **IU2VWK** - <https://iu2vwk.com>

## What's inside

| File | Purpose |
|---|---|
| `launch-models.bat` | **Double-click launcher**: scans `models\`, shows a menu, starts the chosen model |
| `llama-launcher.ps1` | The scanner/launcher behind it; also non-interactive with `-Model` |
| `switch-model.bat` | Quick switch from a terminal: `switch-model.bat <model.gguf> [ctx] [port]` |
| `server-optimized.bat.example` | Reference tuned flag set (RTX 3080 10 GB) - copy and edit |
| `llama-proxy.js` | `:1235 -> :1234` proxy that merges consecutive `system`/`user` messages (fixes "System message must be at the beginning" and "roles must alternate") |
| `claude-local.ps1` | Launch Claude Code through [claude-code-router](https://github.com/musistudio/claude-code-router) against the local server |
| `start-router.ps1` | Start `llama-server` in **router mode** (several models from `models.ini`) and launch the Pi agent |
| `models.ini.example` | Router-mode presets - copy to `models.ini` |

## Layout

Put the scripts next to your `llama-server.exe`, with models in `models\`:

```
G:\LLAMA\
  llama-server.exe
  llama.dll
  ggml-cuda.dll
  ...            (rest of the llama.cpp release)
  launch-models.bat
  llama-launcher.ps1
  llama-proxy.js
  ...
  models\
    my-model.gguf
```

All scripts resolve paths from their own location, so any folder works.

## Quick start

1. Download a llama.cpp Windows build (CUDA for NVIDIA, Vulkan for AMD/Intel) from
   <https://github.com/ggml-org/llama.cpp/releases> and extract it into e.g. `G:\LLAMA`.
2. Copy the scripts from this repo into the same folder.
3. Start a model:
   - **Double-click `launch-models.bat`** and pick a number from the menu, or
   - from a terminal:
     ```
     llama-launcher.ps1 -Model my-model.gguf -Context 32768   # direct
     llama-launcher.ps1 -List                                 # just scan
     switch-model.bat my-model.gguf 32768                     # quick switch
     ```
   The server is then at `http://127.0.0.1:1234`.
4. (Optional) Point OpenCode at the proxy so consecutive system/user messages are merged:
   `llama-launcher.ps1` starts `llama-proxy.js` for you; otherwise run `node llama-proxy.js`
   and use `http://127.0.0.1:1235/v1` as the base URL.
5. (Optional) Claude Code: configure `~/.claude-code-router/config.json` with a provider
   pointing at `http://127.0.0.1:1234/v1`, then run `claude-local.ps1`.

## The launcher menu

`llama-launcher.ps1` scans `models\*.gguf` (skips `mmproj` vision projectors), reads the
`general.architecture` field from each GGUF header, and shows:

```
  [ 1] my-model.gguf                                   4,97 GB  qwen35
  [ 2] Spark-X2.5-4B-Q8_0.gguf                         4,07 GB  spark2_5
```

Pick a number and it starts `llama-server` (killing any previous one).

## Model compatibility

The GGUF architecture must be supported by **your** llama.cpp build. If you see
`unknown model architecture: '...'`, your binaries are older than the model:

- update to a build that includes it (nightly builds get new architectures first),
- replace `llama*.dll`, `ggml*.dll`, the `*.exe` launchers and the CUDA runtime DLLs.

Example: `Spark-X2.5` (`spark2_5`) needs llama.cpp **b10809 or newer**; older builds
(e.g. b10428) fail with `unknown model architecture: 'spark2_5'`.

## Notes

- `-ngl` defaults to `auto` and `--fit` is `on` in recent builds, so VRAM is filled
  automatically. Leave `-Context` at 0 to let llama.cpp pick the context size too.
- The scripts keep flags minimal. For long context add `-c <n>`, or `-ctk q4_0 -ctv q4_0`
  to halve the KV cache.

## License

MIT - see [LICENSE](LICENSE). (c) IU2VWK - <https://iu2vwk.com>

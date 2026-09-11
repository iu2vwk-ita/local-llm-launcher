# Local LLM Launcher

Windows scripts to run GGUF models locally with [llama.cpp](https://github.com/ggml-org/llama.cpp)
and point AI coding tools (Claude Code, OpenCode, the Pi agent) at them.

Everything is plain batch / PowerShell / Node - no build step and no dependencies beyond the
llama.cpp release binaries and Node.js (only for the proxy).

Author: **IU2VWK** - <https://iu2vwk.com>

## Main launcher

**Double-click `Avvia Modelli.bat`** (runs `Avvia-Modelli.ps1`).

It scans the model folders, reads the real GGUF metadata (architecture, layers, GQA/MoE,
quantization) and computes the launch parameters from the VRAM/RAM you declare.

Menu:

| Key | Action |
|---|---|
| `[1-9]` | start a model |
| `[K]` | close the active server(s) |
| `[H]` | set hardware (VRAM / RAM / cores) |
| `[B]` | benchmark a model (`llama-bench`) |
| `[Q]` | quit |

When starting a model it also lets you pick the **profile**, the **context size** (tokens),
the **KV cache type** (`f16` / `q8_0` / `q4_0`), the run mode and the reasoning effort.
It starts `llama-server` on `:1234` and keeps the menu open so you can stop it again.

> The launcher UI is in Italian.

Settings (VRAM/RAM/cores, extra model folders) live in `launcher.config.json`, created next
to the script.

## Other files

| File | Purpose |
|---|---|
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
  Avvia Modelli.bat
  Avvia-Modelli.ps1
  llama-proxy.js
  ...
  models\
    my-model.gguf
```

Scripts resolve paths from their own location; extra model folders can be added in
`launcher.config.json` (`ExtraDirs`).

## Model compatibility

The GGUF architecture must be supported by **your** llama.cpp build. If you see
`unknown model architecture: '...'`, your binaries are older than the model:

- update to a build that includes it (nightly builds get new architectures first),
- replace `llama*.dll`, `ggml*.dll`, the `*.exe` launchers and the CUDA runtime DLLs.

Example: `Spark-X2.5` (`spark2_5`) needs llama.cpp **b10809 or newer**; older builds
(e.g. b10428) fail with `unknown model architecture: 'spark2_5'`.

## Notes

- `-ngl` defaults to `auto` and `--fit` is `on` in recent builds, so VRAM is filled
  automatically.
- For long context prefer a lighter KV cache (`q8_0` or `q4_0`).

## License

MIT - see [LICENSE](LICENSE). (c) IU2VWK - <https://iu2vwk.com>

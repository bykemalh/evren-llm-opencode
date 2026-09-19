# evren-llm-opencode

Installs the EVREN LLM provider into [OpenCode](https://opencode.ai) with a single command.
Works on Windows (CMD and PowerShell) and Linux/macOS (Bash/Zsh).

[Türkçe dokümantasyon](README.md)

---

## Quick Install

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/bykemalh/evren-llm-opencode/main/evren-opencode.sh | bash
```

### Windows — PowerShell

```powershell
irm "https://raw.githubusercontent.com/bykemalh/evren-llm-opencode/main/evren-opencode.ps1" | iex
```

> Run PowerShell as your normal user, not Administrator.

### Windows — CMD

CMD scripts cannot be piped directly. Download and run in two steps:

```cmd
curl -fsSL "https://raw.githubusercontent.com/bykemalh/evren-llm-opencode/main/evren-opencode.cmd" -o "%TEMP%\evren-opencode.cmd" && call "%TEMP%\evren-opencode.cmd"
```

---

## Uninstall

Reverses every change the installer made: removes the `evren` provider block from `opencode.jsonc` and deletes the `EVREN_LLM_API_KEY` environment variable and the `.evren-key` file. All other providers and settings are left intact.

```bash
# Linux / macOS
./evren-opencode.sh --uninstall
```

```powershell
# Windows PowerShell
.\evren-opencode.ps1 --uninstall
```

```cmd
:: Windows CMD
evren-opencode.cmd --uninstall
```

---

## What the Installer Does

1. **API key** — Prompts for your key securely (hidden input), validates the `evren_llm_...` format. Writes it to two places: shell RC files (`~/.bashrc`, `~/.zshrc`, `~/.profile`, fish config — for terminal/curl use) and `~/.config/opencode/.evren-key` (`chmod 600` — the file OpenCode actually reads).
2. **Terms of Service** — Fetches the EVREN terms from the API, displays them, and asks for confirmation. Skips this step if you have already accepted.
3. **Config merge** — Reads the existing `~/.config/opencode/opencode.jsonc`, adds or updates the `evren` provider block, and leaves everything else untouched. Creates the file from scratch if it does not exist. Takes a timestamped backup before writing. Writes conservative per-model `limit` (context/output) values so OpenCode's default 32k output request doesn't cause "max_tokens too large" / needless rate-limit pressure. Sets `small_model` to `evren/deepseek-v4-flash` if unset (light tasks like titles don't load the main model).
4. **Verification** — Runs `opencode models` both normally and with the env var unset (GUI/IDE simulation) to confirm the provider is recognised.

### Config merge behaviour

| Situation | Result |
|-----------|--------|
| `opencode.jsonc` does not exist | Created from scratch |
| `evren` block is absent | Added; other providers kept |
| `evren` block already exists | Updated in place |
| `model` field is already set | Left unchanged |
| `model` field is not set | Set to `evren/glm-5.3` |

---

## Requirements

| | Linux / macOS | Windows |
|---|---|---|
| curl | required | built-in (Windows 10+) |
| JSON tool | python3 **or** jq | PowerShell built-in |
| OpenCode | recommended (not required to run the script) | recommended |

Get your API key at [evren.ssyz.org.tr/api-keys](https://evren.ssyz.org.tr/api-keys).

---

## Available Models

Full model list and details: [evren.ssyz.org.tr/llm/models](https://evren.ssyz.org.tr/llm/models)

| Model ID | Display name |
|----------|-------------|
| `evren/glm-5.3` | GLM 5.3 (default) |
| `evren/deepseek-v4-flash` | DeepSeek V4 Flash |
| `evren/qwen3.8-flash-next` | Qwen 3.8 Flash Next |
| `evren/gemma-4-31b` | Gemma 4 31B |
| `evren/qwen3-vl-30b` | Qwen3 VL 30B |
| `evren/auto` | EVREN Auto |

---

## API Key Format

Keys follow this pattern:

```
evren_llm_<alphanumeric>
```

Obtain yours at [evren.ssyz.org.tr/api-keys](https://evren.ssyz.org.tr/api-keys).

---

## Config File Location

| Platform | Path |
|----------|------|
| Linux / macOS | `~/.config/opencode/opencode.jsonc` |
| Windows | `%USERPROFILE%\.config\opencode\opencode.jsonc` |

The key is never written to this file. The config reads it via a file reference
(so launches from GUI/IDE/desktop — which never source `.bashrc` — keep working;
the old `{env:...}` reference resolved to an empty string there and produced "API key missing" errors):

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "evren/glm-5.3",
  "small_model": "evren/deepseek-v4-flash",
  "provider": {
    "evren": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "EVREN LLM",
      "options": {
        "baseURL": "https://evren-llmapi.ssyz.org.tr/v1",
        "apiKey": "{file:~/.config/opencode/.evren-key}"
      },
      "models": {
        "glm-5.3":            { "name": "GLM 5.3", "limit": { "context": 200000, "output": 16384 } },
        "deepseek-v4-flash":  { "name": "DeepSeek V4 Flash", "limit": { "context": 128000, "output": 8192 } },
        "qwen3.8-flash-next": { "name": "Qwen 3.8 Flash Next", "limit": { "context": 128000, "output": 8192 } },
        "gemma-4-31b":        { "name": "Gemma 4 31B", "limit": { "context": 128000, "output": 8192 } },
        "qwen3-vl-30b":       { "name": "Qwen3 VL 30B", "limit": { "context": 128000, "output": 8192 } },
        "auto":               { "name": "EVREN Auto", "limit": { "context": 128000, "output": 8192 } }
      }
    }
  }
}
```

The real key lives in `~/.config/opencode/.evren-key` (`chmod 600`).
The `EVREN_LLM_API_KEY` environment variable is additionally written for direct `curl` use in terminals.

---

## After Installation

```bash
# List available models
opencode models

# Quick smoke test
opencode run --model evren/glm-5.3 "Just reply: EVREN OK"
```

The environment variable takes effect in new terminal sessions. If you need it immediately in the current session, source your shell config (`source ~/.bashrc`, etc.) or open a new terminal. **OpenCode itself needs no terminal restart** because it reads the key from the `.evren-key` file.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `opencode` not found | Install from [opencode.ai](https://opencode.ai) |
| API key rejected | Check the format: must start with `evren_llm_` |
| "API key missing" / 401 on Linux | Re-run the installer; verify `~/.config/opencode/.evren-key` exists and `apiKey` in the config is `{file:~/.config/opencode/.evren-key}` (check with `opencode debug config`). The old `{env:...}` reference resolves to empty in GUI/IDE launches that never source `.bashrc` |
| `Rate limit exceeded. Try again in 5 seconds.` (429 `rate_limit_exceeded`) | The EVREN API applies a ~5s cooldown on rapid sequential requests. Run one task at a time in OpenCode, avoid parallel agents/sessions; on 429 wait a few seconds and retry. `small_model` (`evren/deepseek-v4-flash`) offloads side work like titles from the main model |
| `max_tokens is too large` | Use the `limit.output` values written by the script (this repo is current); if you hand-edited the config, add per-model `limit: {context, output}` |
| Terms API unreachable | Check your internet connection and key validity |
| Config parse error | Restore the `.bak-...` backup file |
| Env variable not visible in terminal | Open a new terminal or `source ~/.bashrc` (only needed for direct `curl` use; OpenCode works via the file reference) |

---

## License

This repository is licensed under the [MIT License](LICENSE).

Use of the EVREN LLM API is subject to the [EVREN Terms of Service](https://evren.ssyz.org.tr).

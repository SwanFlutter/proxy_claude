# LLM Proxy Hub (`proxy_claude`)

A production-ready **Windows desktop app (Flutter)** that runs a **local LLM proxy & model manager**:

- Embedded **REST proxy** (OpenAI-compatible) built with `shelf`/`shelf_router` — no sidecar process, single `.exe`.
- Aggregates **OpenRouter, Groq, Google Gemini (free tier)** and **any custom provider** (Base URL + API Key + custom headers).
- Fetches `/models` from every provider, **detects free models** (`:free` ids, zero pricing, provider free-tier flags) and exposes a merged OpenAI-style `/v1/models`.
- **Cloudflare Tunnel** integration: auto-downloads `cloudflared.exe`, runs token-based tunnels (your domain) or quick tunnels (`trycloudflare.com`), shows the public URL.
- **API-key security** on the local proxy (`Authorization: Bearer <key>` or `X-API-Key`) so the tunnel URL is useless without credentials.
- **Auto-sync + failover**: re-fetches model lists every N minutes, removes deleted models, adds new free models, and on `401/403/404/408/429/5xx/timeout/network` errors retries the next sibling model → other providers → configured default model.
- Material 3 UI (dark/light), dashboard, provider manager, model explorer, live logs, system-tray background running.

### Why an embedded Dart (shelf) backend?

| Option | Packaging | Streaming SSE | Testability | Verdict |
|---|---|---|---|---|
| **Embedded `shelf` + `shelf_router`** | one `.exe`, no runtime | native Dart `Stream` piping | same VM as app, `MockClient` | ✅ **chosen** |
| `dart:io HttpServer` raw | same | manual header/chunk handling | same | shelf adds auth/CORS middleware for free |
| Go/Node sidecar | second binary + IPC plumbing | good | separate toolchain | heavy for this use case |

## Project layout

```
lib/
  main.dart                 bootstrap (settings, cache, providers)
  app.dart                  window + tray management
  core/                     utils, free-model filter
  models/                   ProviderConfig, ModelInfo, AppSettings, LogEntry
  services/
    settings_service.dart   prefs + secure storage (keys never in prefs)
    upstream_client.dart    OpenAI-compatible client (list models / chat)
    model_registry.dart     routing cache, sync diff, persistence
    chat_proxy_core.dart    failover chain builder + chat executor (pure, tested)
    proxy_server.dart       shelf routes: /health, /v1/models, /v1/chat/completions
    tunnel_manager.dart     cloudflared locate/download/spawn/health
  state/controllers.dart    Riverpod notifiers (proxy/tunnel/sync/settings)
  ui/                       app shell, dashboard, providers, models, logs, settings
test/
  free_model_filter_test.dart   free detection + model parsing
  failover_test.dart            failover chain + retry behaviour (MockClient)
  widget_test.dart              dashboard state widget tests
build_windows.bat              release build + cloudflared bundling
```

## Setup

### 1. Build / run

```bash
flutter pub get
flutter run -d windows          # debug
build_windows.bat               # release + bundled cloudflared.exe
```

### 2. Configure providers (Providers tab)

The Providers tab is a **catalog**: pick a provider → *Connect* → paste the key → *Connect*.
Connected presets switch to *Manage* (same dialog: test connection, advanced base URL /
paths / headers, remove). All presets are OpenAI-compatible and work with the proxy core
unchanged:

| Provider | Base URL (preset) | API key from |
|---|---|---|
| OpenRouter | `https://openrouter.ai/api/v1` | openrouter.ai/settings/keys |
| Google Gemini | `…/v1beta/openai` (free tier) | aistudio.google.com/apikey |
| Groq | `https://api.groq.com/openai/v1` (free tier) | console.groq.com/keys |
| OpenAI | `https://api.openai.com/v1` | platform.openai.com/api-keys |
| Anthropic | `https://api.anthropic.com/v1/openai` | console.anthropic.com |
| DeepSeek | `https://api.deepseek.com/v1` | platform.deepseek.com |
| Mistral | `https://api.mistral.ai/v1` | console.mistral.ai |
| Together AI | `https://api.together.xyz/v1` | api.together.xyz |
| Cerebras | `https://api.cerebras.ai/v1` | cloud.cerebras.ai |
| xAI (Grok) | `https://api.x.ai/v1` | console.x.ai |
| Hugging Face | `https://router.huggingface.co/v1` | huggingface.co/settings/tokens |
| Custom | your URL + headers | your service |

**Secret storage:** API keys, the tunnel token and the local proxy key are kept in
SharedPreferences with base64 obfuscation (never serialized into the settings JSON nor
committed anywhere). The project constraint allows "SharedPreferences *or*
flutter_secure_storage"; the secure-storage plugin was dropped because its Windows
implementation requires the Visual Studio "C++ ATL for v143" component. To harden later:
install that component in VS Installer, add `flutter_secure_storage` back, and swap the
secret read/write calls in `lib/services/settings_service.dart` (they are isolated there
for exactly this purpose).

### 3. Cloudflare Tunnel

**Quick tunnel (zero config, random URL):** Settings → Tunnel mode `Quick` → Connect. The app shows the `https://xxxx.trycloudflare.com` URL.

**Your own domain (recommended):**
1. Create a tunnel in the Cloudflare Zero Trust dashboard and copy its **token**.
2. Settings → Tunnel mode `Token` → paste token → Save.
3. In the Cloudflare dashboard, map your public hostname (e.g. `llm-proxy.yourdomain.com`) to the tunnel (service type `HTTP`, URL `localhost:8080`).
4. Type that hostname into *Public hostname* so the app can display it.
5. Connect. `cloudflared` runs with the token in the **environment** (`TUNNEL_TOKEN`), not argv, so it isn't visible in the process list. SSL is terminated by Cloudflare.

If `cloudflared.exe` is missing, the app auto-downloads the official binary into the app-data `bin/` folder (or use *Download cloudflared*). You can also pre-bundle it next to the app exe via `build_windows.bat`.

### 4. Use the proxy

```bash
KEY=<your local proxy key from Dashboard/Settings>

# list models (free only)
curl http://127.0.0.1:8080/v1/models?free=true -H "Authorization: Bearer $KEY"

# chat (OpenAI-compatible, streaming works)
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"deepseek/deepseek-r1:free","stream":true,
       "messages":[{"role":"user","content":"hi"}]}'
```

Point any OpenAI SDK at `base_url=http://127.0.0.1:8080/v1`. Model routing:
- exact model id → its owning provider;
- `providerId/modelId` → force a provider;
- unknown/absent model → first free model of each enabled provider;
- on failure → same-provider alternates → other providers (free first) → default model (Settings).

### 5. Use with Claude Code (Windows)

The proxy speaks the **Anthropic Messages API** on the same port (`POST /v1/messages`,
including tool_use ⇄ tool_calls translation and SSE streaming), so Claude Code can use
it directly.

Point Claude Code at the proxy in `%USERPROFILE%\.claude\settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8080",
    "ANTHROPIC_AUTH_TOKEN": "<your local proxy key from the app>",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "nvidia/nemotron-3.5-lightning:free",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "nvidia/nemotron-3.5-lightning:free",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "cohere/north-mini-code:free"
  },
  "CLAUDE_CODE_MAX_CONTEXT_TOKENS": 1000000
}
```

- Unknown Claude model names (`claude-sonnet-4-…`) automatically fall back to the
  free-first failover chain; a `[1m]` context suffix on model names is stripped.
- `claude_proxy_env.bat` shows the environment-variable route for a single shell.
- Context-overflow 400s (small free models vs Claude Code's big system prompt) are
  treated as model-specific and retried on the next failover candidate.

### 6. Security notes

- The proxy binds `127.0.0.1` by default; enable *Bind 0.0.0.0* only on trusted LANs.
- Keep *Require API key* ON — the tunnel makes the port world-reachable.
- `GET /health` is the only unauthenticated route (for probes).

## Tests & build

```bash
flutter test                    # filter + failover + widget tests
build_windows.bat               # → build\windows\x64\runner\Release\proxy_claude.exe
```

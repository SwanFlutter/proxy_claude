# LLM Proxy Hub (`proxy_claude`)

A production-ready **Windows desktop app (Flutter)** that runs a **local LLM proxy & model manager**:

- Embedded **REST proxy** (OpenAI-compatible) built with `shelf`/`shelf_router` — no sidecar process, single `.exe`.
- Aggregates **OpenRouter, Groq, Google Gemini (free tier)** and **any custom provider** (Base URL + API Key + custom headers).
- Fetches `/models` from every provider, **detects free models** (`:free` ids, zero pricing, provider free-tier flags) and exposes a merged OpenAI-style `/v1/models`. **Known providers register free models only** — their paid catalogue never enters the pool. A **custom** provider is yours: it registers what it returns or what you declare, free *or* paid (e.g. a gateway with a $5/day credit). Tick **“Use only the models listed above”** to freeze a custom provider to your hand-written list (`/models` is then never called).
- **Cloudflare Tunnel** integration: auto-downloads `cloudflared.exe`, runs token-based tunnels (your domain) or quick tunnels (`trycloudflare.com`), shows the public URL.
- **API-key security** on the local proxy (`Authorization: Bearer <key>` or `X-API-Key`) so the tunnel URL is useless without credentials.
- **Auto-sync + failover**: re-fetches model lists every N minutes, removes deleted models, adds new free models, and on `401/403/404/408/429/5xx/timeout/network` errors retries the next sibling model → other providers → configured default model.
- **One virtual model — `auto`**: every model of every connected provider behind a single model id, so no client ever has to choose. `auto` ranks models by estimated capability (strong / balanced / light), reads the incoming request, and starts at the fitting tier — then escalates to stronger models on failure. `auto:strong` / `auto:fast` pin the tier; `<provider>/auto` restricts it to one provider.
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
  core/                     utils, free-model filter, model_router (auto routing)
  models/                   ProviderConfig, ModelInfo, AppSettings, LogEntry
  services/
    settings_service.dart   prefs + secure storage (keys never in prefs)
    upstream_client.dart    OpenAI-compatible client (list models / chat)
    model_registry.dart     routing cache, sync diff, persistence
    chat_proxy_core.dart    auto + failover chain builder, chat executor (pure, tested)
    proxy_server.dart       shelf routes: /health, /v1/models, /v1/chat/completions
    tunnel_manager.dart     cloudflared locate/download/spawn/health
  state/controllers.dart    Riverpod notifiers (proxy/tunnel/sync/settings)
  ui/                       app shell, dashboard, providers, models, logs, settings
test/
  free_model_filter_test.dart   free detection + model parsing
  failover_test.dart            failover chain + retry behaviour (MockClient)
  auto_router_test.dart         capability tiers, cost order, task routing, `auto`
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

# list models — `auto` is always first; ?all=true adds the raw upstream ids
curl http://127.0.0.1:8080/v1/models -H "Authorization: Bearer $KEY"

# chat (OpenAI-compatible, streaming works) — one model name for everything
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"auto","stream":true,
       "messages":[{"role":"user","content":"hi"}]}'
```

Point any OpenAI SDK at `base_url=http://127.0.0.1:8080/v1`. Model routing:
- **`auto` (recommended)** → every model of every enabled provider, ranked by
  capability; the request is classified so trivial prompts run on a small model
  and complex ones start on the strongest one;
- exact model id → its owning provider;
- `providerId/modelId` → force a provider;
- unknown / stale model names → the `auto` chain (after the configured default model);
- on failure → next candidate in the chain (upwards first) → other providers → default model.

### The `auto` model

| Name | Meaning |
|---|---|
| `auto` | smart routing: classify the request, start at the matching tier |
| `auto:strong` (or `strong`, `best`) | always start at the strongest tier |
| `auto:fast` (or `fast`, `cheap`) | always start at the lightest tier |
| `coarena/auto`, `openrouter/auto`, … | auto routing restricted to one provider |

Candidate order inside `auto`:

1. **tier** — closest tier to the target; equidistant candidates are ordered
   strong→weak, so failures escalate instead of degrading;
2. **cost class** — free ▸ hand-declared gateway model ▸ known-paid. Known-paid
   models of *public* providers are only appended as a final safety net
   (`AutoChain.maxPaidCandidates = 2`) so a huge paid catalogue can never crowd
   out the models that actually answer. Models belonging to a **custom provider
   are treated as consented** — you added them and you pay for them, so they
   compete by capability with no cap;
3. **estimated capability score** — parameter size (`235b`, `8b`), family
   generation (`gpt-6` > `gpt-4`, `kimi-k3` > `kimi-k2`), flagship tokens
   (`max`, `pro`, `opus`, `r1`) vs. cheap tokens (`flash`, `lite`, `mini`,
   `haiku`), and context length. A `-flash` variant of a new generation is never
   treated as the strongest tier.

Every request logs the decision (`auto · task=moderate tier=balanced (…)` on the
Logs page) and replies with `x-proxy-auto-tier` / `x-proxy-auto-task` headers, so
a wrong guess is easy to spot and the chain repairs it automatically.

Settings → **Model Routing**:
- *Serve the virtual `auto` model* — advertise it in `/v1/models`;
- *Smart task routing* — off ⇒ `auto` always starts at the strongest tier;
- *Advertise only `auto`* — hide upstream ids from model discovery entirely
  (explicit real ids keep working, they are simply not listed).

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
    "ANTHROPIC_MODEL": "auto",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "auto:strong",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "auto",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "auto:fast"
  },
  "CLAUDE_CODE_MAX_CONTEXT_TOKENS": 1000000
}
```

That is the whole setup: **`auto` is the only model name you configure**, and the
proxy decides per request which provider/model actually serves it. Use
`auto:strong` for the heavy tiers and `auto:fast` for background/small calls, or
set all four variables to plain `auto` and let the classifier do everything.

- Unknown Claude model names (`claude-sonnet-4-…`) automatically fall back to the
  `auto` chain; a `[1m]` context suffix on model names is stripped.
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

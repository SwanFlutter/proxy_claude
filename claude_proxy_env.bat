@echo off
REM ─────────────────────────────────────────────────────────────────────────────
REM Point Claude Code at the local LLM Proxy Hub.
REM
REM Usage:  call claude_proxy_env.bat   (then run `claude` in the same shell)
REM
REM The proxy key below is your LOCAL key from the app's Dashboard/Settings —
REM it is NOT your OpenRouter key. OpenRouter credentials live inside the app.
REM ─────────────────────────────────────────────────────────────────────────────
setlocal

REM Local proxy endpoint + key (auth: Bearer / x-api-key)
set "ANTHROPIC_BASE_URL=http://127.0.0.1:8080"
set "ANTHROPIC_AUTH_TOKEN=REPLACE_WITH_YOUR_LOCAL_PROXY_KEY"

REM Model routing through the proxy — one virtual model, nothing to pick:
REM   auto        = smart routing over every connected provider
REM   auto:strong = always start at the strongest tier (opus-class work)
REM   auto:fast   = always start at the lightest tier (background/small calls)
REM Unknown Claude model names also fall back to the auto chain.
set "ANTHROPIC_MODEL=auto"
set "ANTHROPIC_SMALL_FAST_MODEL=auto:fast"
set "ANTHROPIC_DEFAULT_OPUS_MODEL=auto:strong"
set "ANTHROPIC_DEFAULT_SONNET_MODEL=auto"
set "ANTHROPIC_DEFAULT_HAIKU_MODEL=auto:fast"

REM Keep the proxy app running while you use Claude Code.
claude %*

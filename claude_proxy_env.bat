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

REM Model routing through the proxy:
REM  - main model  → any model id the proxy serves (see GET /v1/models)
REM  - small/fast  → used by Claude Code for background tasks; pick a FREE one
REM Unknown Claude model names automatically fall back to free models.
set "ANTHROPIC_MODEL=google/gemma-4-31b-it:free"
set "ANTHROPIC_SMALL_FAST_MODEL=baidu/ernie-5.5-flash-preview:free"

REM Keep the proxy app running while you use Claude Code.
claude %*

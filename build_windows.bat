@echo off
REM ─────────────────────────────────────────────────────────────────────────────
REM LLM Proxy Hub — Windows release build
REM Builds the Flutter Windows app and bundles cloudflared.exe next to it.
REM ─────────────────────────────────────────────────────────────────────────────
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo [1/4] flutter pub get
flutter pub get || goto :err

echo [2/4] flutter analyze (informational)
flutter analyze || echo (analyze reported issues — continuing)

echo [3/4] flutter build windows --release
flutter build windows --release || goto :err

set "OUT=build\windows\x64\runner\Release"
if not exist "%OUT%" set "OUT=build\windows\runner\Release"
if not exist "%OUT%" (
  echo Cannot locate build output directory.
  goto :err
)

echo [4/4] Bundling cloudflared.exe into %OUT%
if not exist "cloudflared\cloudflared.exe" (
  echo cloudflared not cached — downloading...
  if not exist cloudflared mkdir cloudflared
  powershell -NoProfile -Command "Invoke-WebRequest -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile 'cloudflared\cloudflared.exe'" || goto :err
)
copy /Y "cloudflared\cloudflared.exe" "%OUT%\cloudflared.exe" || goto :err

echo.
echo ============================================================
echo  Build OK:  %OUT%\proxy_claude.exe
echo  Bundled:   %OUT%\cloudflared.exe
echo ============================================================
goto :eof

:err
echo.
echo BUILD FAILED.
exit /b 1

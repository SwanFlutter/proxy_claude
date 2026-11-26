# LLM Proxy Hub — build targets (run from the project root, Git Bash / make)

FLUTTER := flutter
OUT_DIR := build/windows/x64/runner/Release
CFD_DIR := cloudflared
CFD_URL := https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe

.PHONY: get icon analyze test build bundle all clean

get:
	$(FLUTTER) pub get

icon:
	dart run tool/gen_icon.dart

analyze:
	$(FLUTTER) analyze

test:
	$(FLUTTER) test

build:
	$(FLUTTER) build windows --release

bundle:
	@mkdir -p $(CFD_DIR)
	@test -f $(CFD_DIR)/cloudflared.exe || curl -L -o $(CFD_DIR)/cloudflared.exe $(CFD_URL)
	@cp $(CFD_DIR)/cloudflared.exe $(OUT_DIR)/cloudflared.exe

all: get analyze test build bundle
	@echo "Done → $(OUT_DIR)/proxy_claude.exe"

clean:
	$(FLUTTER) clean

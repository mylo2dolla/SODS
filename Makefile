.PHONY: help dev build start spectrum flash-esp32dev flash-esp32c3 verify

help:
	@echo "sods commands:"
	@echo "  make dev           # start sods spine (watch)"
	@echo "  make build         # build sods spine"
	@echo "  make start         # start sods spine (prod)"
	@echo "  make spectrum      # open spectrum UI"
	@echo "  make flash-esp32dev # open ESP Web Tools for ESP32"
	@echo "  make flash-esp32c3  # open ESP Web Tools for ESP32-C3"

PI_LOGGER ?= http://pi-logger.local:8088
PORT ?= 9123

DEV_CMD = cd $(CURDIR)/cli/sods && npm run dev -- --pi-logger $(PI_LOGGER) --port $(PORT)


dev:
	@cd $(CURDIR)/cli/sods && npm install
	@$(DEV_CMD)

build:
	@cd $(CURDIR)/cli/sods && npm install
	@cd $(CURDIR)/cli/sods && npm run build

start:
	@cd $(CURDIR)/cli/sods && npm install
	@cd $(CURDIR)/cli/sods && npm run build
	@node $(CURDIR)/cli/sods/dist/cli.js start --pi-logger $(PI_LOGGER) --port $(PORT)

spectrum:
	@$(CURDIR)/tools/sods spectrum

flash-esp32dev:
	@$(CURDIR)/firmware/node-agent/tools/flash-esp32dev.sh

flash-esp32c3:
	@$(CURDIR)/firmware/node-agent/tools/flash-esp32c3.sh

verify:
	@$(CURDIR)/tools/verify.sh

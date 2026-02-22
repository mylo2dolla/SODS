set shell := ["/bin/bash", "-c"]

help:
  @echo "sods commands:"
  @echo "  just dev" 
  @echo "  just build" 
  @echo "  just start" 
  @echo "  just spectrum" 
  @echo "  just flash-esp32dev" 
  @echo "  just flash-esp32c3" 
  @echo "  just verify" 

AUX_HOST := "pi-aux.local"
PI_LOGGER := "http://{{AUX_HOST}}:9101"
PORT := "9123"

dev:
  cd {{justfile_directory()}}/cli/sods && npm install
  cd {{justfile_directory()}}/cli/sods && npm run dev -- --pi-logger {{PI_LOGGER}} --port {{PORT}}

build:
  cd {{justfile_directory()}}/cli/sods && npm install
  cd {{justfile_directory()}}/cli/sods && npm run build

start:
  cd {{justfile_directory()}}/cli/sods && npm install
  cd {{justfile_directory()}}/cli/sods && npm run build
  node {{justfile_directory()}}/cli/sods/dist/cli.js start --pi-logger {{PI_LOGGER}} --port {{PORT}}

spectrum:
  {{justfile_directory()}}/tools/sods spectrum

flash-esp32dev:
  {{justfile_directory()}}/firmware/node-agent/tools/flash-esp32dev.sh

flash-esp32c3:
  {{justfile_directory()}}/firmware/node-agent/tools/flash-esp32c3.sh

verify:
  {{justfile_directory()}}/tools/verify.sh

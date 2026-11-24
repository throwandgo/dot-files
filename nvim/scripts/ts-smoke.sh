#!/usr/bin/env bash
# Smoke-tests the TypeScript setup (lua/typescript/smoke.lua) in a headless nvim.
# Exits non-zero on failure; results also show in :checkhealth typescript.
set -o errexit -o errtrace -o nounset -o pipefail

exec nvim -n --headless -c "lua require('typescript.smoke').run()"

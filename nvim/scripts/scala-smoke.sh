#!/usr/bin/env bash
# Smoke-tests the Scala/Java LSP setup (lua/scala/smoke.lua) in a headless nvim.
# Exits non-zero on failure; results also show in :checkhealth scala.
set -o errexit -o errtrace -o nounset -o pipefail

exec nvim --headless -c "lua require('scala.smoke').run()"

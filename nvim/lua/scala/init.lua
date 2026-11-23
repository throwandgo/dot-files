-- Safeguards for the Scala/Java LSP setup (plugins/scala.lua, plugins/java.lua):
--   guards  loud notifications when a patch stops applying or a server misbehaves
--   health  :checkhealth scala
--   smoke   :ScalaSmokeTest, also run after :Lazy update / :Lazy sync
--   reaper  stops Metals/jdtls whose files haven't been visible for vim.g.lsp_reaper_minutes
local M = {}

function M.setup()
  require("scala.guards").setup()
  require("scala.smoke").setup()
  require("scala.reaper").setup()
end

return M

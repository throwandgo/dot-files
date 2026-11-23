-- Safeguards for the Scala/Java LSP setup (plugins/scala.lua, plugins/java.lua):
--   guards  loud notifications when a patch stops applying or a server misbehaves
--   health  :checkhealth scala
--   smoke   :ScalaSmokeTest, also run after :Lazy update / :Lazy sync
local M = {}

function M.setup()
  require("scala.guards").setup()
  require("scala.smoke").setup()
end

return M

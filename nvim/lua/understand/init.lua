-- Code-understanding helpers (keymaps under `ga`):
--   gai/gao  incoming/outgoing calls (LazyVim)   gap/gac  supertypes/subtypes tree
--   gau      super method                        gaL      local source of a dependency file
--   gaP      .proto definition of generated code (Scala/Java)
--   gaR      Scala/Java usages of a .proto definition (proto)
local M = {}

function M.setup()
  require("understand.local_source").setup()

  vim.keymap.set("n", "gaL", function()
    require("understand.local_source").jump()
  end, { desc = "Local Source of Dependency" })

  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("understand_keys", { clear = true }),
    pattern = { "scala", "java", "sbt", "proto" },
    callback = function(ev)
      if ev.match == "proto" then
        vim.keymap.set("n", "gaR", function()
          require("understand.proto").usages()
        end, { buffer = ev.buf, desc = "Scala/Java Usages" })
      else
        vim.keymap.set("n", "gaP", function()
          require("understand.proto").goto_proto()
        end, { buffer = ev.buf, desc = "Goto .proto Definition" })
      end
    end,
  })
end

return M

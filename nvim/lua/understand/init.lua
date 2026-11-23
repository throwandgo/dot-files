-- Code-understanding helpers (keymaps under `ga`):
--   gai/gao  incoming/outgoing calls (LazyVim)   gap/gac  supertypes/subtypes tree
--   gau      super method                        gas      source of truth (see M.source)
--   gr       in .proto files: protos + Scala/Java code using the definition
local M = {}

local function first_location(results)
  for _, r in pairs(results or {}) do
    local loc = r.result and (vim.islist(r.result) and r.result[1] or r.result)
    if loc and (loc.uri or loc.targetUri) then
      return loc, r.context and r.context.client_id
    end
  end
end

-- Keeps going past the definition to the file you can actually read and change:
--   generated ScalaPB/protoc code   -> the .proto it was generated from
--   dependency jar (Metals/jdtls)   -> the monorepo file the jar was built from
function M.source()
  local word = vim.fn.expand("<cword>")
  local function resolve(jumped)
    local buf = vim.api.nvim_get_current_buf()
    if require("understand.proto").buf_is_generated(buf) then
      return require("understand.proto").goto_proto(word)
    end
    local local_source = require("understand.local_source")
    if #local_source.find(buf) > 0 then
      return local_source.jump()
    end
    if not jumped then
      vim.notify(("No definition found for %s"):format(word), vim.log.levels.WARN, { title = "Source" })
    end
  end

  local buf = vim.api.nvim_get_current_buf()
  if #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/definition" }) == 0 then
    return resolve(false)
  end
  vim.lsp.buf_request_all(buf, "textDocument/definition", function(client)
    return vim.lsp.util.make_position_params(0, client.offset_encoding)
  end, function(results)
    vim.schedule(function()
      if vim.api.nvim_get_current_buf() ~= buf then
        return -- the user moved on while the server was busy
      end
      local loc, client_id = first_location(results)
      local client = loc and vim.lsp.get_client_by_id(client_id)
      if client then
        vim.lsp.util.show_document(loc, client.offset_encoding, { focus = true })
      end
      resolve(client ~= nil)
    end)
  end)
end

-- `gr`: LSP references, except in .proto files where the interesting references are the code
-- generated from it (buf_ls only knows other protos).
function M.references()
  if vim.bo.filetype == "proto" then
    return require("understand.proto").usages()
  end
  Snacks.picker.lsp_references()
end

function M.setup()
  require("understand.local_source").setup()
  vim.keymap.set("n", "gas", M.source, { desc = "Source of Truth (def → .proto / local src)" })
end

return M

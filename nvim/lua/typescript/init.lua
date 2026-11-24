-- TypeScript/JavaScript tooling (plugins/typescript.lua):
--   tsgo        TypeScript 7's native language server (home-manager: ~/.local/share/tsgo)
--   eslint      vscode-eslint-language-server, filtered through eslint-suppressions.json
--   prettierd   format on save, only where the repo has a prettier config
--   health      :checkhealth typescript
--   smoke       :TsSmokeTest, also run after :Lazy update / :Lazy sync
-- All three come from nix with their own node, so they start no matter where nvim was launched
-- (mise only puts node on PATH inside repos that pin it).
local M = {}

M.tsgo = vim.fn.expand("~/.local/share/tsgo/bin/tsc")
-- Absolute, so Mason's bin dir (prepended to PATH) can't swap in a node-less copy.
M.eslint = vim.fn.expand("~/.nix-profile/bin/vscode-eslint-language-server")

-- ESLint applies bulk suppressions (eslint-suppressions.json) only in its CLI; the Node API that
-- editor servers use ignores them, so editors show violations CI accepts. This mirrors
-- SuppressionsService.applySuppressions: per file and rule, when the number of errors is within
-- the suppressed count, all of that rule's messages are dropped.
local suppression_files = {} ---@type table<string, string|false> dir -> nearest suppressions file
local suppressions = {} ---@type table<string, { stamp: string, data: table }>

local function suppressions_file(dir)
  if suppression_files[dir] == nil then
    suppression_files[dir] = vim.fs.find("eslint-suppressions.json", { path = dir, upward = true })[1] or false
  end
  return suppression_files[dir]
end

local function load(file)
  local st = vim.uv.fs_stat(file)
  if not st then
    return nil
  end
  local stamp = ("%d.%d.%d"):format(st.mtime.sec, st.mtime.nsec, st.size)
  local cached = suppressions[file]
  if not cached or cached.stamp ~= stamp then
    local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"))
    cached = { stamp = stamp, data = ok and type(data) == "table" and data or {} }
    suppressions[file] = cached
  end
  return cached.data
end

---@param items lsp.Diagnostic[]
---@param fname string absolute path of the linted file
---@return lsp.Diagnostic[]
function M.unsuppressed(items, fname)
  local file = suppressions_file(vim.fs.dirname(fname))
  local rel = file and vim.fs.relpath(vim.fs.dirname(file), fname)
  local rules = rel and (load(file) or {})[rel]
  if type(rules) ~= "table" then
    return items
  end
  local errors = {}
  for _, d in ipairs(items) do
    if d.code and (d.severity or 1) == 1 then
      errors[d.code] = (errors[d.code] or 0) + 1
    end
  end
  local hidden = {}
  for rule, n in pairs(errors) do
    if type(rules[rule]) == "table" and n <= (rules[rule].count or 0) then
      hidden[rule] = true
    end
  end
  if vim.tbl_isempty(hidden) then
    return items
  end
  return vim.tbl_filter(function(d)
    return not hidden[d.code]
  end, items)
end

-- "<client id>:<buf>" once ESLint has linted the buffer, i.e. its typed program is loaded.
local linted = {}

M.eslint_handlers = {
  ["textDocument/diagnostic"] = function(err, result, ctx)
    if not err then
      linted[ctx.client_id .. ":" .. ctx.bufnr] = true
    end
    if result and result.kind == "full" and result.items then
      result.items = M.unsuppressed(result.items, vim.uri_to_fname(ctx.params.textDocument.uri))
    end
    return vim.lsp.diagnostic.on_diagnostic(err, result, ctx)
  end,
  ["textDocument/publishDiagnostics"] = function(err, params, ctx)
    params.diagnostics = M.unsuppressed(params.diagnostics, vim.uri_to_fname(params.uri))
    return vim.lsp.diagnostic.on_publish_diagnostics(err, params, ctx)
  end,
}

local function apply_code_action(client, buf, kind, timeout)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = vim.api.nvim_buf_line_count(buf), character = 0 },
    },
    context = { only = { kind }, diagnostics = {} },
  }
  local res = client:request_sync("textDocument/codeAction", params, timeout or 5000, buf)
  for _, action in ipairs(res and res.result or {}) do
    if not action.edit and client:supports_method("codeAction/resolve") then
      local resolved = client:request_sync("codeAction/resolve", action, 5000, buf)
      action = resolved and resolved.result or action
    end
    if action.edit then
      vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
    end
  end
end

-- Drops unused imports, then lets ESLint order them per the repo's rules (import/order etc.).
-- TypeScript's own organizeImports sorts differently and would fight the linter, so it's only
-- used where ESLint isn't running.
function M.organize_imports()
  local buf = vim.api.nvim_get_current_buf()
  local ts = vim.lsp.get_clients({ bufnr = buf, name = "tsgo" })[1]
  local eslint = vim.lsp.get_clients({ bufnr = buf, name = "eslint" })[1]
  if ts then
    apply_code_action(ts, buf, eslint and "source.removeUnusedImports" or "source.organizeImports")
  end
  if eslint then
    eslint:request_sync("workspace/executeCommand", {
      command = "eslint.applyAllFixes",
      arguments = { { uri = vim.uri_from_bufnr(buf), version = vim.lsp.util.buf_versions[buf] } },
    }, 10000, buf)
  end
end

-- ESLint's fix-all on save (import/order, perfectionist sorting, ...), like VSCode's
-- codeActionsOnSave. Warm, it takes ~250ms in ~/web. Until the buffer's first lint lands the
-- typed program is still loading (~30s cold), so the save goes ahead unfixed instead of waiting.
function M.eslint_fix(buf)
  local eslint = vim.lsp.get_clients({ bufnr = buf, name = "eslint" })[1]
  if vim.g.eslint_fix_on_save == false or not eslint or not linted[eslint.id .. ":" .. buf] then
    return
  end
  apply_code_action(eslint, buf, "source.fixAll.eslint", 2000)
end

function M.setup()
  require("typescript.smoke").setup()
end

return M

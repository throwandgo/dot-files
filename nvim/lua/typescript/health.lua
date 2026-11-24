-- :checkhealth typescript
local M = {}

local h = vim.health

local function version(cmd)
  local r = vim.system(cmd, { text = true }):wait(5000)
  return r.code == 0 and vim.trim(r.stdout or "") or nil
end

local function check_servers()
  local ts = require("typescript")
  h.start("Servers (nix-provided; no node on PATH needed)")
  local tsgo = version({ ts.tsgo, "--version" })
  if tsgo then
    h.ok(("tsgo: %s (%s)"):format(tsgo, vim.uv.fs_realpath(ts.tsgo)))
  else
    h.error("tsgo missing: " .. ts.tsgo, { "home-manager switch (home/base.nix: .local/share/tsgo)" })
  end
  if vim.fn.executable(ts.eslint) == 1 then
    h.ok("eslint: " .. vim.uv.fs_realpath(ts.eslint))
  else
    h.error("eslint server missing: " .. ts.eslint, { "home-manager switch (unstable.vscode-langservers-extracted)" })
  end
  local prettierd = vim.fn.exepath("prettierd")
  if prettierd == "" then
    h.error("prettierd not on PATH; TS/JS files won't format", { "home-manager switch (unstable.prettierd)" })
  elseif prettierd:find("/mason/", 1, true) then
    h.warn(
      "prettierd resolves to Mason's copy, which needs node on PATH: " .. prettierd,
      { ":MasonUninstall prettierd" }
    )
  else
    h.ok("prettierd: " .. prettierd)
  end

  for _, name in ipairs({ "vtsls", "ts_ls" }) do
    if vim.lsp.is_enabled(name) then
      h.error(name .. " is enabled and will run next to tsgo", { "Set servers." .. name .. ".enabled = false" })
    end
  end
  for _, name in ipairs({ "tsgo", "eslint" }) do
    if not vim.lsp.is_enabled(name) then
      h.warn(name .. " isn't enabled yet (it is once a file loads nvim-lspconfig)")
    end
  end
end

local function check_clients()
  h.start("Running clients")
  local any = false
  for _, c in ipairs(vim.lsp.get_clients()) do
    if c.name == "tsgo" or c.name == "eslint" then
      any = true
      local pid = c.rpc and c.rpc.pid
      local rss = pid and tonumber(vim.trim(vim.fn.system({ "ps", "-o", "rss=", "-p", tostring(pid) })))
      h.ok(
        ("%s at %s, %d buffers%s"):format(
          c.name,
          vim.fn.fnamemodify(c.root_dir or "?", ":~"),
          vim.tbl_count(c.attached_buffers),
          rss and (", %dMB"):format(rss / 1024) or ""
        )
      )
    end
  end
  if not any then
    h.info("None (open a TS/JS file)")
  end
end

local function check_smoke()
  local smoke = require("typescript.smoke")
  h.start("Smoke test")
  local last = smoke.last_result()
  if not last then
    return h.warn("Never run", { ":TsSmokeTest" })
  end
  local when = os.date("%Y-%m-%d %H:%M", last.time)
  if not last.ok then
    h.error(("Failed on %s"):format(when), vim.list_extend(vim.deepcopy(last.failures), { "Log: " .. smoke.log }))
  elseif last.lock ~= smoke.lock_hash() then
    h.warn(("Passed on %s, but plugins or servers changed since"):format(when), { ":TsSmokeTest" })
  else
    h.ok(("Passed on %s in %ds"):format(when, last.seconds or 0))
  end
end

function M.check()
  check_servers()
  check_clients()
  check_smoke()
end

return M

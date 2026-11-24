-- End-to-end check of the TypeScript setup (tsgo, ESLint, prettierd) against a throwaway fixture,
-- plus a read-only pass over a real repo with typed ESLint (vim.g.ts_smoke_repo, default ~/web).
-- Runs in a separate headless nvim:
--   :TsSmokeTest               (background; also runs after :Lazy update / :Lazy sync)
--   nvim/scripts/ts-smoke.sh   (foreground; exits non-zero on failure)
local M = {}

M.log = vim.fn.stdpath("state") .. "/ts-smoke.log"
M.result_file = vim.fn.stdpath("state") .. "/ts-smoke.json"

local TIMEOUT_MS = 5 * 60 * 1000
local TITLE = "TypeScript smoke test"

local function compiler_options(extra)
  return vim.tbl_extend("force", {
    strict = true,
    target = "es2022",
    module = "esnext",
    moduleResolution = "bundler",
    jsx = "react-jsx",
    noEmit = true,
    paths = { ["@/*"] = { "./src/*" } },
  }, extra or {})
end

-- A miniature yarn monorepo: root tsconfig plus an app whose own tsconfig remaps `@/*`, as
-- ~/web's kiosk and edge apps do.
local files = {
  ["repo/package.json"] = { vim.json.encode({ name = "ts-smoke", private = true, workspaces = { "apps/*" } }) },
  ["repo/yarn.lock"] = {},
  ["repo/.prettierrc"] = { vim.json.encode({ singleQuote = true, printWidth = 100, trailingComma = "all" }) },
  ["repo/eslint-suppressions.json"] = {
    vim.json.encode({ ["src/legacy.ts"] = { ["no-debugger"] = { count = 2 }, ["no-console"] = { count = 1 } } }),
  },
  ["repo/tsconfig.json"] = {
    vim.json.encode({ compilerOptions = compiler_options(), include = { "src" }, exclude = { "apps" } }),
  },
  ["repo/src/util/greet.ts"] = {
    "export function greet(name: string, loud: boolean): string {",
    "  return loud ? name.toUpperCase() : name;",
    "}",
  },
  ["repo/src/main.ts"] = {
    "import { greet } from '@/util/greet';",
    "",
    "export const hello = greet('world', true);",
    "export const broken: number = 'nope';",
  },
  ["repo/src/missing.ts"] = { "export const again = greet('again', false);" },
  ["repo/src/unused.ts"] = { "import { greet } from '@/util/greet';", "", "export const z = 1;" },
  ["repo/src/util/names.ts"] = { "export const a = 1;", "export const b = 2;", "export const c = 3;" },
  ["repo/src/multi.ts"] = {
    "import {",
    "  a,",
    "  b,",
    "  c,",
    "} from './util/names';",
    "",
    "export const s = a + c;",
  },
  ["repo/src/messy.ts"] = { 'const a = {b: "x"}', "export default a" },
  ["repo/apps/kiosk/package.json"] = { vim.json.encode({ name = "kiosk", private = true }) },
  ["repo/apps/kiosk/tsconfig.json"] = {
    vim.json.encode({ compilerOptions = compiler_options(), include = { "src" } }),
  },
  ["repo/apps/kiosk/src/env.ts"] = { "export const kioskEnv = 'kiosk';" },
  ["repo/apps/kiosk/src/index.ts"] = { "import { kioskEnv } from '@/env';", "", "export const which = kioskEnv;" },
  -- No prettier config here: saving must not run prettier.
  ["plain/data.json"] = { '{"a":   1}' },
}

-- Identifies the plugin + server versions a result applies to.
function M.lock_hash()
  local lock = vim.fn.stdpath("config") .. "/lazy-lock.json"
  local lines = vim.fn.filereadable(lock) == 1 and vim.fn.readfile(lock) or {}
  local ts = require("typescript")
  local servers = (vim.uv.fs_realpath(ts.tsgo) or "") .. (vim.uv.fs_realpath(ts.eslint) or "")
  return vim.fn.sha256(table.concat(lines, "\n") .. servers .. vim.fn.exepath("prettierd"))
end

---@return { ok: boolean, failures: string[], time: integer, seconds: integer, lock: string }|nil
function M.last_result()
  if vim.fn.filereadable(M.result_file) == 0 then
    return nil
  end
  local ok, result = pcall(vim.json.decode, table.concat(vim.fn.readfile(M.result_file), "\n"))
  return ok and result or nil
end

local running = false

-- Runs the smoke test in a background nvim and notifies with the result.
function M.spawn()
  if running then
    return vim.notify("Already running", vim.log.levels.INFO, { title = TITLE })
  end
  running = true
  vim.notify("Running in the background (usually under a minute)", vim.log.levels.INFO, { title = TITLE })
  local log = assert(io.open(M.log, "w"))
  local function write(_, data)
    if data then
      log:write(data)
    end
  end
  vim.system({ vim.v.progpath, "-n", "--headless", "-c", "lua require('typescript.smoke').run()" }, {
    stdout = write,
    stderr = write,
  }, function(r)
    log:close()
    vim.schedule(function()
      running = false
      local result = M.last_result()
      if r.code == 0 and result and result.ok then
        vim.notify(("Passed in %ds"):format(result.seconds), vim.log.levels.INFO, { title = TITLE })
      else
        local failures = result and not result.ok and result.failures or { "exit code " .. r.code }
        vim.notify(
          ("FAILED:\n- %s\n\nLog: %s"):format(table.concat(failures, "\n- "), M.log),
          vim.log.levels.ERROR,
          { title = TITLE }
        )
      end
    end)
  end)
end

local function out(msg)
  io.stdout:write(os.date("%H:%M:%S ") .. msg .. "\n")
  io.stdout:flush()
end

local function client(buf, name)
  return vim.lsp.get_clients({ bufnr = buf, name = name })[1]
end

local function attached(buf, name, ms)
  vim.wait(ms, function()
    local c = client(buf, name)
    return c ~= nil and c.initialized
  end, 50)
  return client(buf, name)
end

local function request(buf, method, params)
  local res = vim.lsp.buf_request_sync(buf, method, params, 20000) or {}
  for _, r in pairs(res) do
    if r.result then
      return r.result
    end
  end
end

local function at(buf, line, word)
  local text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
  return {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = { line = line, character = assert(text:find(word, 1, true)) - 1 },
  }
end

local function target_of(result)
  local loc = vim.islist(result) and result[1] or result
  return loc and vim.uri_to_fname(loc.targetUri or loc.uri) or ""
end

local function steps(dir, check)
  local ts = require("typescript")
  local repo = dir .. "/repo"
  local function open(rel)
    vim.cmd.edit(repo .. "/" .. rel)
    return vim.api.nvim_get_current_buf()
  end

  local main = open("src/main.ts")
  local tsgo = attached(main, "tsgo", 30000)
  if not check(tsgo ~= nil, "tsgo attaches to main.ts") then
    return
  end
  check(tsgo.config.cmd[1] == ts.tsgo, ("tsgo runs %s (got %s)"):format(ts.tsgo, tsgo.config.cmd[1]))
  check(tsgo.root_dir == repo, ("tsgo root is the lockfile root (got %s)"):format(tsgo.root_dir))
  for _, name in ipairs({ "vtsls", "ts_ls" }) do
    check(#vim.lsp.get_clients({ name = name }) == 0, ("no %s client"):format(name))
  end
  check(vim.fn.maparg(" co", "n", false, true).desc == "Organize imports", "<leader>co organizes imports")

  local diag = vim.wait(20000, function()
    return #vim.diagnostic.get(main, { lnum = 3, severity = vim.diagnostic.severity.ERROR }) > 0
  end, 50)
  check(diag, "type error reported on main.ts:4")

  local hover = request(main, "textDocument/hover", at(main, 2, "greet"))
  local text = hover and (hover.contents.value or hover.contents) or ""
  check(text:find("greet(name: string, loud: boolean): string", 1, true) ~= nil, "hover shows greet's signature")

  local def = request(main, "textDocument/definition", at(main, 2, "greet"))
  check(target_of(def):match("src/util/greet%.ts$") ~= nil, "definition through the @/ alias lands in greet.ts")

  local hints = request(main, "textDocument/inlayHint", {
    textDocument = vim.lsp.util.make_text_document_params(main),
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 4, character = 0 } },
  }) or {}
  local labels = table.concat(
    vim.tbl_map(function(h)
      local label = type(h.label) == "table" and h.label[1].value or h.label
      return (label:gsub(":%s*$", ""))
    end, hints),
    " "
  )
  check(labels == "name loud", ("inlay hints: literal parameter names only (got %q)"):format(labels))

  local rename =
    request(main, "textDocument/rename", vim.tbl_extend("force", at(main, 2, "greet"), { newName = "salute" }))
  local renamed, aliased = {}, false
  for _, change in ipairs(rename and rename.documentChanges or {}) do
    renamed[#renamed + 1] = vim.fs.basename(vim.uri_to_fname(change.textDocument.uri))
    for _, edit in ipairs(change.edits) do
      aliased = aliased or edit.newText:find(" as ", 1, true) ~= nil
    end
  end
  for uri, edits in pairs(rename and rename.changes or {}) do
    renamed[#renamed + 1] = vim.fs.basename(vim.uri_to_fname(uri))
    for _, edit in ipairs(edits) do
      aliased = aliased or edit.newText:find(" as ", 1, true) ~= nil
    end
  end
  table.sort(renamed)
  check(
    table.concat(renamed, " ") == "greet.ts main.ts unused.ts" and not aliased,
    ("rename at a usage renames the definition, no alias (got %s%s)"):format(
      table.concat(renamed, " "),
      aliased and ", aliased" or ""
    )
  )

  local missing = open("src/missing.ts")
  attached(missing, "tsgo", 10000)
  local actions = {}
  vim.wait(20000, function()
    local params = at(missing, 0, "greet")
    params.range = { start = params.position, ["end"] = params.position }
    params.context = { diagnostics = vim.lsp.diagnostic.from(vim.diagnostic.get(missing)), only = { "quickfix" } }
    params.position = nil
    actions = request(missing, "textDocument/codeAction", params) or {}
    return #actions > 0
  end, 500)
  local titles = table.concat(
    vim.tbl_map(function(a)
      return a.title
    end, actions),
    "; "
  )
  check(
    titles:match("Add import from [\"']([%.@])/util/greet") ~= nil,
    ("auto-import quickfix (got %q)"):format(titles)
  )

  local unused = open("src/unused.ts")
  attached(unused, "tsgo", 10000)
  ts.organize_imports()
  local first = vim.api.nvim_buf_get_lines(unused, 0, 1, false)[1]
  check(not first:find("import", 1, true), ("organize imports drops the unused import (got %q)"):format(first))

  local multi = open("src/multi.ts")
  attached(multi, "tsgo", 10000)
  ts.organize_imports()
  local mlines = table.concat(vim.api.nvim_buf_get_lines(multi, 0, -1, false), "\n")
  check(
    not mlines:find("b,", 1, true) and mlines:find("\n  a,\n  c\n", 1, true) ~= nil,
    ("organize imports keeps 2-space indentation (got %q)"):format(mlines)
  )

  local kiosk = open("apps/kiosk/src/index.ts")
  attached(kiosk, "tsgo", 10000)
  local kdef = request(kiosk, "textDocument/definition", at(kiosk, 2, "kioskEnv"))
  local kimport = request(kiosk, "textDocument/definition", at(kiosk, 0, "'@/env'"))
  check(
    target_of(kdef):match("apps/kiosk/src/env%.ts$") ~= nil
      or target_of(kimport):match("apps/kiosk/src/env%.ts$") ~= nil,
    ("per-app tsconfig resolves @/env to the app (got %s)"):format(target_of(kimport))
  )
  check(#vim.lsp.get_clients({ name = "tsgo" }) == 1, "one tsgo serves the whole monorepo")

  local conform = require("conform")
  local messy = open("src/messy.ts")
  local names = vim.tbl_map(function(f)
    return f.name
  end, conform.list_formatters_to_run(messy))
  check(
    vim.deep_equal(names, { "prettierd" }),
    ("prettierd formats TS in a prettier repo (got %s)"):format(vim.inspect(names))
  )
  conform.format({ bufnr = messy, async = false, timeout_ms = 15000 })
  local formatted = table.concat(vim.api.nvim_buf_get_lines(messy, 0, -1, false), "\n")
  check(
    formatted == "const a = { b: 'x' };\nexport default a;",
    ("prettier applies the repo's .prettierrc (got %q)"):format(formatted)
  )
  vim.cmd.edit(dir .. "/plain/data.json")
  local plain = vim.tbl_map(function(f)
    return f.name
  end, conform.list_formatters_to_run(0))
  check(not vim.tbl_contains(plain, "prettierd"), "no prettier where the repo has no prettier config")

  -- Bulk suppressions: no-debugger (2 errors, 2 allowed) disappears with its warnings; no-console
  -- (2 errors, 1 allowed) is over budget and stays, like the CLI.
  local E, W = 1, 2
  local raw = {
    { code = "no-debugger", severity = E },
    { code = "no-debugger", severity = E },
    { code = "no-debugger", severity = W },
    { code = "no-console", severity = E },
    { code = "no-console", severity = E },
    { code = "eqeqeq", severity = E },
  }
  local kept = vim.tbl_map(function(d)
    return d.code
  end, ts.unsuppressed(raw, repo .. "/src/legacy.ts"))
  check(
    table.concat(kept, " ") == "no-console no-console eqeqeq",
    ("eslint-suppressions.json applied like the CLI (got %s)"):format(table.concat(kept, " "))
  )
  check(#ts.unsuppressed(raw, repo .. "/src/main.ts") == #raw, "files without suppressions keep every diagnostic")

  -- Typed ESLint against a real repo: the nix server must load the repo's eslint + config.
  local real = vim.fn.expand(vim.g.ts_smoke_repo or "~/web")
  local sfile = real .. "/eslint-suppressions.json"
  if vim.fn.filereadable(sfile) == 0 then
    return out("skip ESLint on a real repo: no " .. sfile)
  end
  local target
  local suppressed = vim.tbl_keys(vim.json.decode(table.concat(vim.fn.readfile(sfile), "\n")))
  table.sort(suppressed)
  for _, rel in ipairs(suppressed) do
    if rel:match("%.tsx?$") and vim.fn.filereadable(real .. "/" .. rel) == 1 then
      target = real .. "/" .. rel
      break
    end
  end
  if not target then
    return
  end
  local pulled = {}
  vim.api.nvim_create_autocmd("LspRequest", {
    callback = function(ev)
      local r = ev.data.request
      local c = vim.lsp.get_client_by_id(ev.data.client_id)
      if r.type == "complete" and r.method == "textDocument/diagnostic" and c and c.name == "eslint" then
        pulled[ev.buf] = true
      end
    end,
  })
  vim.cmd.edit(target)
  local buf = vim.api.nvim_get_current_buf()
  local eslint = attached(buf, "eslint", 30000)
  if not check(eslint ~= nil, ("eslint attaches in %s"):format(vim.fn.fnamemodify(real, ":~"))) then
    return
  end
  check(eslint.config.cmd[1] == ts.eslint, "eslint runs the nix server")
  check(
    eslint.handlers["textDocument/diagnostic"] == ts.eslint_handlers["textDocument/diagnostic"],
    "suppressions filter installed"
  )
  check(
    vim.wait(180000, function()
      return pulled[buf]
    end, 100),
    ("eslint lints %s (typed rules)"):format(vim.fs.basename(target))
  )
  check(client(buf, "tsgo") ~= nil and client(buf, "tsgo").root_dir == real, "tsgo attaches at the repo root")

  -- Save runs ESLint's fixes, then prettier; checked by swapping the first two imports.
  local names = vim.tbl_map(
    function(f)
      return f.name
    end,
    vim.tbl_filter(function(f)
      return f.active
    end, LazyVim.format.resolve(buf))
  )
  check(
    table.concat(names, ",") == "eslint: fix all,conform.nvim",
    ("save runs ESLint fixes, then prettier (got %s)"):format(table.concat(names, ","))
  )
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local imports = {}
  for i, l in ipairs(lines) do
    if l:match("^import .* from '.*';$") then
      imports[#imports + 1] = i
    end
  end
  if #imports >= 2 and imports[2] == imports[1] + 1 then
    local a, b = imports[1], imports[2]
    vim.api.nvim_buf_set_lines(buf, a - 1, b, false, { lines[b], lines[a] })
    pulled[buf] = false
    vim.wait(30000, function()
      return pulled[buf]
    end, 50)
    local t0 = vim.uv.hrtime()
    ts.eslint_fix(buf)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    local now = vim.api.nvim_buf_get_lines(buf, a - 1, b, false)
    check(
      vim.deep_equal(now, { lines[a], lines[b] }),
      ("ESLint fix-all restores import order (%dms, got %s)"):format(ms, table.concat(now, " | "))
    )
  end
  vim.bo[buf].modified = false
end

-- Entry point for the headless nvim.
function M.run()
  -- lazy.nvim finishes loading (and LazyVim wires LSP) only once startup is done.
  if vim.v.vim_did_enter == 0 then
    return vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = vim.schedule_wrap(M.run) })
  end
  if not vim.g.did_very_lazy then
    vim.g.did_very_lazy = true
    vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy", modeline = false })
  end

  local start = os.time()
  local failures = {}
  local function check(ok, msg)
    out((ok and "ok   " or "FAIL ") .. msg)
    if not ok then
      table.insert(failures, msg)
    end
    return ok
  end

  local base = vim.fn.stdpath("cache") .. "/ts-smoke"
  local dir = base .. "/" .. start
  for rel, lines in pairs(files) do
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. rel), "p")
    vim.fn.writefile(lines, dir .. "/" .. rel)
  end
  dir = assert(vim.uv.fs_realpath(dir))
  vim.fn.chdir(dir)
  out("fixture " .. dir)

  local timer = assert(vim.uv.new_timer())
  timer:start(TIMEOUT_MS, 0, function()
    io.stdout:write("FAIL timed out\n")
    os.exit(2)
  end)
  local ok, err = xpcall(steps, debug.traceback, dir, check)
  if not ok then
    check(false, "error: " .. tostring(err))
  end
  timer:stop()

  for _, c in ipairs(vim.lsp.get_clients()) do
    c:stop()
  end
  vim.wait(10000, function()
    return #vim.lsp.get_clients() == 0
  end)
  for _, c in ipairs(vim.lsp.get_clients()) do
    c:stop(true)
  end
  vim.fn.chdir(vim.env.HOME)
  vim.fn.delete(base, "rf")

  local result = {
    ok = #failures == 0,
    failures = failures,
    time = start,
    seconds = os.time() - start,
    lock = M.lock_hash(),
  }
  vim.fn.writefile({ vim.json.encode(result) }, M.result_file)
  out(("%s in %ds"):format(result.ok and "PASSED" or "FAILED", result.seconds))
  vim.cmd(result.ok and "qall!" or "cquit 1")
end

function M.setup()
  vim.api.nvim_create_user_command(
    "TsSmokeTest",
    M.spawn,
    { desc = "Smoke-test tsgo/ESLint/prettier in the background" }
  )
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("ts_smoke", { clear = true }),
    pattern = { "LazyUpdate", "LazySync" },
    callback = function()
      vim.defer_fn(M.spawn, 2000)
    end,
  })
end

return M

-- Impact map: which definitions did the change touch, and who uses them outside the change?
-- Changed lines -> innermost enclosing definitions (treesitter) -> one indexed zoekt search for all
-- their names, minus files in the change itself. Works in a review tab (PR vs merge-base) or on any
-- branch (working tree vs merge-base with origin/development).
local util = require("review.util")

local M = {}

local EXT = { scala = "scala", sc = "scala", java = "java", proto = "proto" }

-- One pattern per entry; invalid ones (grammar drift) are skipped individually.
local PATTERNS = {
  scala = {
    "(class_definition name: (_) @name) @def",
    "(object_definition name: (_) @name) @def",
    "(trait_definition name: (_) @name) @def",
    "(enum_definition name: (_) @name) @def",
    "(function_definition name: (_) @name) @def",
    "(function_declaration name: (_) @name) @def",
    "(val_definition pattern: (identifier) @name) @def",
    "(val_declaration name: (_) @name) @def",
    "(given_definition name: (_) @name) @def",
    "(type_definition name: (_) @name) @def",
  },
  java = {
    "(class_declaration name: (_) @name) @def",
    "(interface_declaration name: (_) @name) @def",
    "(enum_declaration name: (_) @name) @def",
    "(record_declaration name: (_) @name) @def",
    "(method_declaration name: (_) @name) @def",
    "(field_declaration declarator: (variable_declarator name: (_) @name)) @def",
  },
  proto = {
    "(message (message_name) @name) @def",
    "(enum (enum_name) @name) @def",
    "(service (service_name) @name) @def",
    "(rpc (rpc_name) @name) @def",
    "(field (identifier) @name) @def",
    "(enum_field (identifier) @name) @def",
  },
}

-- Too common to say anything about impact.
local GENERIC = {}
for _, n in ipairs({
  "apply",
  "unapply",
  "main",
  "toString",
  "equals",
  "hashCode",
  "copy",
  "build",
  "builder",
  "create",
  "get",
  "set",
  "run",
  "close",
  "start",
  "stop",
  "init",
  "value",
  "values",
  "name",
  "test",
  "this",
  "config",
  "logger",
  "log",
  "self",
  "default",
  "empty",
  "update",
  "delete",
  "handle",
  "process",
}) do
  GENERIC[n] = true
end

local queries = {}
local function query(lang)
  if queries[lang] == nil then
    local ok_lang = pcall(vim.treesitter.language.add, lang)
    local valid = {}
    for _, p in ipairs(ok_lang and PATTERNS[lang] or {}) do
      if pcall(vim.treesitter.query.parse, lang, p) then
        valid[#valid + 1] = p
      end
    end
    queries[lang] = #valid > 0 and vim.treesitter.query.parse(lang, table.concat(valid, "\n")) or false
  end
  return queries[lang] or nil
end

local function is_test(path)
  return path:match("/src/test/")
    or path:match("/src/it/")
    or path:match("Spec%.scala$")
    or path:match("Tests?%.java$")
    or path:match("IT%.java$")
end

--- New-side changed lines per file from a -U0 diff.
---@return table<string, integer[]>
function M.parse_diff(diff)
  local ret, file = {}, nil
  for line in vim.gsplit(diff, "\n") do
    local path = line:match("^%+%+%+ b/(.+)$")
    if path then
      file = path
      ret[file] = ret[file] or {}
    elseif line:match("^%+%+%+ ") then
      file = nil -- deleted file
    elseif file then
      local c, d = line:match("^@@ %-%S+ %+(%d+),?(%d*) @@")
      if c then
        c, d = tonumber(c), tonumber(d ~= "" and d or "1")
        for l = c, c + math.max(d, 1) - 1 do
          ret[file][#ret[file] + 1] = math.max(l, 1)
        end
      end
    end
  end
  return ret
end

--- Innermost definition names enclosing each changed line.
---@param root string
---@param changed table<string, integer[]>
---@return string[] names, table<string, {loc: string, span: integer}> origin
function M.definitions(root, changed)
  local names, origin = {}, {}
  local proto = require("understand.proto")
  for path, lnums in pairs(changed) do
    local lang = EXT[path:match("%.(%w+)$") or ""]
    local q = lang and not is_test(path) and query(lang)
    local fd = q and io.open(vim.fs.joinpath(root, path))
    if fd then
      local src = fd:read("*a")
      fd:close()
      local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
      local tree = ok and parser:parse()[1]
      local defs = {}
      for _, match in tree and q:iter_matches(tree:root(), src, 0, -1) or function() end do
        local def, name
        for id, nodes in pairs(match) do
          local node = nodes[#nodes] or nodes
          if q.captures[id] == "def" then
            def = node
          elseif q.captures[id] == "name" then
            name = node
          end
        end
        if def and name then
          local s, _, e = def:range()
          local nrow = name:range()
          defs[#defs + 1] = { s = s, e = e, span = e - s, name = vim.treesitter.get_node_text(name, src), row = nrow }
        end
      end
      local lines = lang == "proto" and vim.split(src, "\n") or nil
      for _, l in ipairs(lnums) do
        local best
        for _, d in ipairs(defs) do
          if d.s <= l - 1 and l - 1 <= d.e and (not best or d.span < best.span) then
            best = d
          end
        end
        if best then
          local list = lines and proto.usage_names(best.name, lines[best.row + 1] or "") or { best.name }
          for _, n in ipairs(list) do
            if not origin[n] and #n >= 4 and not GENERIC[n] and n:match("^[%a_][%w_]*$") then
              origin[n] = { loc = ("%s:%d"):format(path, best.row + 1), span = best.span }
              names[#names + 1] = n
            end
          end
        end
      end
    end
  end
  table.sort(names)
  return names, origin
end

local MAX = 150

function M.open()
  util.run(function()
    local st = require("review").active()
    local root = st and st.root or vim.fs.root(0, ".git") or vim.fn.getcwd()
    local base = st and st.merge_base or "origin/development"
    local diff = util.sh({ "git", "diff", "-U0", "--no-color", "--no-ext-diff", "--merge-base", base }, { cwd = root })
    local changed = M.parse_diff(diff)
    local names, origin = M.definitions(root, changed)
    if #names == 0 then
      return util.notify("No changed Scala/Java/proto definitions to trace")
    end
    if #names > MAX then
      util.notify(("Tracing the first %d of %d changed definitions"):format(MAX, #names), vim.log.levels.WARN)
      names = vim.list_slice(names, 1, MAX)
    end
    local patterns = {}
    for _, n in ipairs(names) do
      patterns[n] = "%f[%w_]" .. n .. "%f[^%w_]"
    end
    require("search.zoekt").grep({
      title = ("Impact: uses of %d changed definitions (outside the change)"):format(#names),
      search = [[\b(]] .. table.concat(names, "|") .. [[)\b]],
      terms = [[case:yes f:\.(scala|java|sbt|proto)$]],
      glob = { "*.scala", "*.java", "*.sbt", "*.proto" },
      live = false,
      cwd = root,
      matcher = { sort_empty = true },
      -- most specific definitions first: a changed method's callers before a whole class's importers
      sort = { fields = { "rank", "sym", "file", "idx" } },
      transform = function(item)
        if changed[item.file] then
          return false
        end
        for _, n in ipairs(names) do
          if item.line and item.line:find(patterns[n]) then
            item.sym = n
            break
          end
        end
        item.sym = item.sym or "?"
        local o = origin[item.sym]
        item.rank = o and o.span or math.huge
        item.comment = o and o.loc
      end,
      format = function(item, picker)
        local ret = { { ("%-28s"):format(item.sym), "SnacksPickerLabel" }, { " " } }
        return vim.list_extend(ret, Snacks.picker.format.file(item, picker))
      end,
    })
  end)
end

return M

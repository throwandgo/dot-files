-- Transitive type hierarchy (supertypes/subtypes) as a tree in a snacks picker. Works with any
-- server implementing textDocument/prepareTypeHierarchy (Metals, jdtls).
local M = {}

M.max_depth = 8
M.max_items = 500

-- Supertypes every class has; they bury the interesting ones.
M.noise = { "Any", "AnyRef", "AnyVal", "Object", "Product", "Serializable", "Equals", "Record" }

---@alias understand.Direction "supertypes"|"subtypes"

---@class understand.HierarchyNode
---@field item lsp.TypeHierarchyItem
---@field depth integer

-- Collects the hierarchy depth-first, in display order. Calls cb(nodes, err) when done.
---@param client vim.lsp.Client
---@param buf integer
---@param params lsp.TextDocumentPositionParams
---@param direction understand.Direction
---@param cb fun(nodes: understand.HierarchyNode[]?, err: string?)
function M.collect(client, buf, params, direction, cb)
  local method = "typeHierarchy/" .. direction
  client:request("textDocument/prepareTypeHierarchy", params, function(err, roots)
    if err or not roots or #roots == 0 then
      return cb(nil, err and err.message or "no type at the cursor")
    end
    local children, seen, count, pending = {}, {}, 0, 0
    local function key(item)
      return item.uri .. ":" .. item.selectionRange.start.line .. ":" .. item.name
    end
    local function finish()
      local nodes = {}
      local function walk(item, depth)
        table.insert(nodes, { item = item, depth = depth })
        for _, child in ipairs(children[key(item)] or {}) do
          walk(child, depth + 1)
        end
      end
      for _, root in ipairs(roots) do
        walk(root, 0)
      end
      cb(nodes)
    end
    local function expand(item, depth)
      seen[key(item)] = true
      if depth >= M.max_depth or count >= M.max_items then
        return
      end
      pending = pending + 1
      client:request(method, { item = item }, function(_, result)
        local kids = {}
        for _, child in ipairs(result or {}) do
          local noise = direction == "supertypes" and vim.tbl_contains(M.noise, child.name)
          if not noise and not seen[key(child)] and count < M.max_items then
            count = count + 1
            table.insert(kids, child)
            expand(child, depth + 1)
          end
        end
        table.sort(kids, function(a, b)
          return a.name < b.name
        end)
        children[key(item)] = kids
        pending = pending - 1
        if pending == 0 then
          finish()
        end
      end, buf)
    end
    for _, root in ipairs(roots) do
      expand(root, 0)
    end
    if pending == 0 then
      finish()
    end
  end, buf)
end

local function format(item)
  local node = item.node ---@type understand.HierarchyNode
  local kind = vim.lsp.protocol.SymbolKind[node.item.kind] or "Unknown"
  local icon = LazyVim.config.icons.kinds[kind] or ""
  local ret = {
    { string.rep("  ", node.depth) },
    { icon, "SnacksPickerIcon" .. kind },
    { node.item.name, node.depth == 0 and "SnacksPickerLabel" or "SnacksPickerFile" },
  }
  if node.item.detail and node.item.detail ~= "" then
    table.insert(ret, { " " .. node.item.detail, "SnacksPickerComment" })
  end
  table.insert(ret, { "  " .. vim.fn.fnamemodify(item.file, ":~:."), "SnacksPickerDir" })
  return ret
end

---@param direction understand.Direction
function M.pick(direction)
  local buf = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = buf, method = "textDocument/prepareTypeHierarchy" })[1]
  if not client then
    vim.notify("No attached language server supports type hierarchy", vim.log.levels.WARN, { title = "Hierarchy" })
    return
  end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  M.collect(client, buf, params, direction, function(nodes, err)
    if not nodes then
      vim.notify(("Type hierarchy: %s"):format(err), vim.log.levels.WARN, { title = "Hierarchy" })
      return
    end
    local items = {}
    for _, node in ipairs(nodes) do
      local file = vim.uri_to_fname(node.item.uri)
      local pos = node.item.selectionRange.start
      table.insert(items, {
        text = node.item.name .. " " .. file,
        file = file,
        pos = { pos.line + 1, pos.character },
        node = node,
      })
    end
    if #items == 1 then
      vim.notify(("%s has no %s"):format(nodes[1].item.name, direction), vim.log.levels.INFO, { title = "Hierarchy" })
      return
    end
    Snacks.picker.pick({
      title = (direction == "supertypes" and "Supertypes of " or "Subtypes of ") .. nodes[1].item.name,
      items = items,
      format = format,
      sort = { fields = { "score:desc", "idx" } },
      matcher = { sort_empty = false },
      jump = { tagstack = true, reuse_win = true },
    })
  end)
end

-- The method this one overrides/implements.
function M.super_method()
  local names = vim.tbl_map(function(c)
    return c.name
  end, vim.lsp.get_clients({ bufnr = 0 }))
  if vim.tbl_contains(names, "metals") then
    require("metals").goto_super_method()
  elseif vim.tbl_contains(names, "jdtls") then
    require("jdtls").super_implementation()
  else
    M.pick("supertypes")
  end
end

return M

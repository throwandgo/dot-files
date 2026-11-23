-- Review comments (GitHub threads, agent findings) drawn as wrapped, bordered boxes under the lines
-- they refer to, like GitHub's inline comments. End-of-line virtual text can't wrap, so long
-- comments ran off screen. The diagnostics stay (signs, ]d, pickers); only their text moves here.
local M = {}

local ns = vim.api.nvim_create_namespace("review.notes")
local fill_ns = vim.api.nvim_create_namespace("review.notes.fill")
local SEV = { "Error", "Warn", "Info", "Hint" }
local MAX_WIDTH = 100

local function define_hls()
  local function get(name)
    return vim.api.nvim_get_hl(0, { name = name, link = false })
  end
  local fg = get("Normal").fg
  -- a float's background sets the box apart from the code; the border carries the severity colour
  local bg = get("NormalFloat").bg or get("Normal").bg
  for _, s in ipairs(SEV) do
    local accent = get("Diagnostic" .. s).fg
    vim.api.nvim_set_hl(0, "ReviewNote" .. s, { fg = fg, bg = bg })
    vim.api.nvim_set_hl(0, "ReviewNoteBorder" .. s, { fg = accent, bg = bg })
    vim.api.nvim_set_hl(0, "ReviewNoteTitle" .. s, { fg = accent, bg = bg, bold = true })
  end
end
define_hls()
vim.api.nvim_create_autocmd("ColorScheme", { callback = define_hls })

--- Word-wrap `text` to `width` display columns; paragraphs and blank lines are kept.
local function wrap(text, width)
  local out = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in para:gmatch("%S+") do
      while vim.api.nvim_strwidth(word) > width do
        if line ~= "" then
          out[#out + 1], line = line, ""
        end
        out[#out + 1], word = vim.fn.strcharpart(word, 0, width), vim.fn.strcharpart(word, width)
      end
      if line == "" then
        line = word
      elseif vim.api.nvim_strwidth(line) + 1 + vim.api.nvim_strwidth(word) <= width then
        line = line .. " " .. word
      else
        out[#out + 1], line = line, word
      end
    end
    out[#out + 1] = line
  end
  while out[#out] == "" do
    out[#out] = nil
  end
  return out
end

--- Text width of the widest window showing `buf`.
local function text_width(buf)
  local width = 0
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(w)[1]
    if info then
      width = math.max(width, info.width - info.textoff)
    end
  end
  return width > 0 and width or 80
end

--- Draw `notes` in `buf`. Each note: { lnum = 0-based anchor, severity, parts = { {head, text} } }.
function M.render(buf, notes)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local avail = text_width(buf)
  table.sort(notes, function(a, b)
    return a.lnum < b.lnum
  end)
  for _, note in ipairs(notes) do
    local lnum = math.min(note.lnum, vim.api.nvim_buf_line_count(buf) - 1)
    local indent = vim.api.nvim_buf_call(buf, function()
      return vim.fn.indent(lnum + 1)
    end)
    if indent > avail / 2 then
      indent = 0
    end
    local box = math.min(MAX_WIDTH, avail - indent - 1)
    local inner = math.max(20, box - 4)
    local sev = SEV[note.severity] or "Info"
    local body_hl, border_hl, title_hl = "ReviewNote" .. sev, "ReviewNoteBorder" .. sev, "ReviewNoteTitle" .. sev
    local pad = { string.rep(" ", indent) }
    local virt = {}
    -- ╭─ title ───╮ (first part) or ├─ title ───┤ (replies), body lines │ text │, then ╰────╯
    local function rule(l, title, r)
      local t = " " .. title .. " "
      return {
        pad,
        { l .. "─", border_hl },
        { t, title_hl },
        { string.rep("─", math.max(0, box - 3 - vim.api.nvim_strwidth(t))) .. r, border_hl },
      }
    end
    for i, part in ipairs(note.parts) do
      virt[#virt + 1] = rule(i == 1 and "╭" or "├", part.head, i == 1 and "╮" or "┤")
      for _, l in ipairs(wrap(part.text, inner)) do
        virt[#virt + 1] = {
          pad,
          { "│ ", border_hl },
          { l .. string.rep(" ", inner - vim.api.nvim_strwidth(l)), body_hl },
          { " │", border_hl },
        }
      end
    end
    virt[#virt + 1] = { pad, { "╰" .. string.rep("─", box - 2) .. "╯", border_hl } }
    vim.api.nvim_buf_set_extmark(buf, ns, lnum, 0, { virt_lines = virt })
    note.height = #virt
  end
  M.fill_partners(buf, notes)
end

--- Line in `a` shown beside line `l` of `b` (1-based; 0 = above the first line), from `hunks`.
local function partner_line(hunks, l)
  local offset = 0
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = unpack(h)
    if cb > 0 and l >= sb and l < sb + cb then
      return ca == 0 and sa or sa + math.min(l - sb, ca - 1)
    elseif (cb > 0 and sb + cb <= l) or (cb == 0 and sb < l) then
      offset = offset + ca - cb
    else
      break
    end
  end
  return l + offset
end

--- Diff mode doesn't count virtual lines, so blocks under lines of `buf` push its side out of
--- step with the other side. Pad the other side with as many blank lines at the matching line.
function M.fill_partners(buf, notes)
  local diff = vim.text and vim.text.diff or vim.diff
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.wo[w].diff then
      for _, ow in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(w))) do
        local ob = vim.api.nvim_win_get_buf(ow)
        if ob ~= buf and vim.wo[ow].diff then
          vim.api.nvim_buf_clear_namespace(ob, fill_ns, 0, -1)
          local function text(b)
            return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n") .. "\n"
          end
          local hunks = diff(text(ob), text(buf), { result_type = "indices" })
          local last = vim.api.nvim_buf_line_count(ob)
          for _, note in ipairs(notes) do
            if note.height then
              local l = math.min(partner_line(hunks, note.lnum + 1), last)
              local blank = {}
              for i = 1, note.height do
                blank[i] = { { "" } }
              end
              vim.api.nvim_buf_set_extmark(ob, fill_ns, math.max(l - 1, 0), 0, {
                virt_lines = blank,
                virt_lines_above = l == 0,
              })
            end
          end
        end
      end
    end
  end
end

return M

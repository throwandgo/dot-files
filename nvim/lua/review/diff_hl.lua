-- GitHub-style diff colours for diffview: the old side red, the new side green, changed words
-- strongly tinted, and folded unchanged runs as a thin rule instead of a solid band. tokyonight's DiffChange is ~3% off the background and both sides share one
-- blue, so changed lines were near-invisible and old vs new indistinguishable.
local M = {}

local function blend(fg, bg, alpha)
  local function ch(c, shift)
    return bit.band(bit.rshift(c, shift), 0xff)
  end
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    out = out + bit.lshift(math.floor(ch(fg, shift) * alpha + ch(bg, shift) * (1 - alpha) + 0.5), shift)
  end
  return out
end

function M.define()
  local bg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg or 0x222436
  -- GitHub's diff hues: saturated enough to stay red/green when blended into a blue-ish background
  local red, green = 0xf85149, 0x3fb950
  vim.api.nvim_set_hl(0, "ReviewDiffOldLine", { bg = blend(red, bg, 0.18) })
  vim.api.nvim_set_hl(0, "ReviewDiffOldText", { bg = blend(red, bg, 0.45) })
  vim.api.nvim_set_hl(0, "ReviewDiffNewLine", { bg = blend(green, bg, 0.18) })
  vim.api.nvim_set_hl(0, "ReviewDiffNewText", { bg = blend(green, bg, 0.45) })
  local dim = vim.api.nvim_get_hl(0, { name = "LineNr", link = false }).fg
  vim.api.nvim_set_hl(0, "ReviewDiffFold", { fg = dim })
end

--- Text of a folded run of unchanged lines; 'fillchars' fold:─ draws the rest of the rule.
function M.foldtext()
  return ("──── ⋯ %d unchanged lines "):format(vim.v.foldend - vim.v.foldstart + 1)
end

--- diffview `view_post_layout` hook: per-side groups (left = merge base, right = PR head).
function M.apply(view)
  local w = view.winopts and view.winopts.diff2
  if not w then
    return
  end
  local fill = vim.o.fillchars:gsub("fold:[^,]*,?", "")
  fill = (fill == "" and "" or fill:gsub(",?$", ",")) .. "fold:─"
  for _, side in ipairs({ w.a, w.b }) do
    side.foldtext = "v:lua.require'review.diff_hl'.foldtext()"
    side.fillchars = fill
  end
  w.a.winhl = {
    "DiffAdd:ReviewDiffOldLine",
    "DiffDelete:DiffviewDiffDeleteDim",
    "DiffChange:ReviewDiffOldLine",
    "DiffText:ReviewDiffOldText",
    "DiffTextAdd:ReviewDiffOldText",
    "Folded:ReviewDiffFold",
  }
  w.b.winhl = {
    "DiffAdd:ReviewDiffNewLine",
    "DiffDelete:DiffviewDiffDeleteDim",
    "DiffChange:ReviewDiffNewLine",
    "DiffText:ReviewDiffNewText",
    "DiffTextAdd:ReviewDiffNewText",
    "Folded:ReviewDiffFold",
  }
end

M.define()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("review.diff_hl", { clear = true }),
  callback = M.define,
})

return M

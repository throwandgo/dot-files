-- Extends the LazyVim root spec for Codeium.
-- See: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/extras/ai/codeium.lua.
return {
  {
    "Exafunction/codeium.nvim",
    cmd = "Codeium",
    opts = {
      enable_cmp_source = vim.g.ai_cmp,
      virtual_text = {
        enabled = not vim.g.ai_cmp,
        key_bindings = {
          accept = "<Tab>", -- handled by nvim-cmp / blink.cmp
          next = "<M-]>",
          prev = "<M-[>",
        },
      },
    },
  },
}

-- Only the deviations from LazyVim's blink.cmp defaults.
return {
  "saghen/blink.cmp",
  opts = {
    keymap = { preset = "default" }, -- <C-y> accepts, <CR> is always a newline
    cmdline = { enabled = false },
  },
}

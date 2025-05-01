return {
  {
    "tpope/vim-fugitive",
    cond = function()
      local handle = io.popen("git rev-parse --is-inside-work-tree 2>/dev/null")
      if not handle then
        return false
      end

      local result = handle:read("*a")
      handle:close()
      return result and result:match("true") ~= nil
    end,
  },
}

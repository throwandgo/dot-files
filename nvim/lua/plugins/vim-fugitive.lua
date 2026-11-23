-- Git in Vim (:G blame, :Gdiffsplit, ...) plus :GBrowse via rhubarb. Loaded on first use.
return {
  "tpope/vim-fugitive",
  dependencies = { "tpope/vim-rhubarb" },
  cmd = { "G", "Git", "GBrowse", "Gdiffsplit", "Gvdiffsplit", "Gedit", "Gread", "Gwrite", "GMove", "GDelete" },
}

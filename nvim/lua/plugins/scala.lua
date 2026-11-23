-- Metals tuned for large sbt/Gradle monorepos (layered on LazyVim's lang.scala extra).
local build_root = require("utils.build_root")

-- Java in Gradle/Maven builds belongs to jdtls (lang.java extra); Metals only takes Java that
-- lives inside an sbt build, which jdtls can't import.
local function metals_root(path)
  if path:match("%.java$") then
    if build_root.find(path, { gradle = true, maven = true }) then
      return nil
    end
    return build_root.find(path, { sbt = true })
  end
  return build_root.find(path, { sbt = true, gradle = true })
end

local function metals_status()
  local parts = {}
  for _, var in ipairs({ "metals_status", "metals_bsp_status" }) do
    local s = vim.g[var]
    if s and s ~= "" then
      table.insert(parts, s)
    end
  end
  return table.concat(parts, " ")
end

return {
  {
    "scalameta/nvim-metals",
    opts = function(_, metals_config)
      local settings = metals_config.settings
      -- Import without waiting on the "Import build?" prompt, which is easy to miss and leaves the
      -- server running with no build targets.
      -- (nvim-metals documents this as "autoImportBuild", which Metals silently ignores.)
      settings.autoImportBuilds = "all"
      -- Builds with both build.sbt and settings.gradle (e.g. member) otherwise block on a
      -- "which build tool?" prompt.
      settings.targetBuildTool = "sbt"
      settings.serverProperties = { "-Xmx6G", "-XX:+UseStringDeduplication" }

      -- Surfaces import/indexing/compile progress in the statusline (see lualine below).
      metals_config.init_options.statusBarProvider = "on"

      -- The Metals launcher appends $JAVA_OPTS to its JVM flags, so a project .envrc exporting
      -- heavy app settings (-Xms4g, -XX:MaxNewSize=356m, -Dplay.*) leaks into every server. sbt
      -- spawned through BSP still gets them via SBT_OPTS so its heap stays as large as before.
      metals_config.cmd_env = {
        JAVA_OPTS = "",
        JAVA_FLAGS = "",
        SBT_OPTS = vim.env.SBT_OPTS or vim.env.JAVA_OPTS,
      }

      metals_config.find_root_dir = function(_, bufname)
        return metals_root(bufname)
      end

      return metals_config
    end,
    config = function(_, metals_config)
      -- nvim-metals also re-reads $JAVA_OPTS itself and forwards it as -J flags; keep only the
      -- workspace's .jvmopts.
      local jvmopts = require("metals.jvmopts")
      jvmopts.java_opts = jvmopts.java_opts_from_file
      -- Real Metals settings missing from nvim-metals' allowlist (it warns on unknown keys).
      local valid = require("metals.config").valid_metals_settings
      for _, key in ipairs({ "autoImportBuilds", "targetBuildTool" }) do
        if not vim.tbl_contains(valid, key) then
          table.insert(valid, key)
        end
      end

      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("nvim-metals", { clear = true }),
        pattern = { "scala", "sbt", "java" },
        callback = function(ev)
          if vim.bo[ev.buf].buftype ~= "" or not metals_root(vim.api.nvim_buf_get_name(ev.buf)) then
            return
          end
          -- initialize_or_attach resolves the root from the current buffer.
          vim.api.nvim_buf_call(ev.buf, function()
            require("metals").initialize_or_attach(metals_config)
          end)
        end,
      })
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    optional = true,
    opts = function(_, opts)
      table.insert(opts.sections.lualine_x, 1, {
        metals_status,
        cond = function()
          return metals_status() ~= ""
        end,
      })
    end,
  },
}

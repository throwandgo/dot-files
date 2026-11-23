-- jdtls for Gradle/Maven Java (layered on LazyVim's lang.java extra). Java inside sbt builds is
-- left to Metals (see plugins/scala.lua).
local build_root = require("utils.build_root")
local jdk = require("scala.jdk")

return {
  {
    "mfussenegger/nvim-jdtls",
    opts = function(_, opts)
      local guards = require("scala.guards")
      -- The default root markers include gradlew (nested in some subprojects) and .git (the whole
      -- monorepo); anchor on settings.gradle/pom.xml instead.
      opts.root_dir = build_root.jdtls_root
      opts.project_name = jdk.jdtls_project_name

      -- Recent jdtls releases need a newer Java than the projects use just to start; home-manager
      -- provides it.
      if (opts.cmd[1] or "") == "" then
        guards.problem(
          "jdtls-cmd",
          "jdtls isn't on PATH (Mason not loaded yet, or jdtls not installed): :MasonInstall jdtls"
        )
      end
      if vim.fn.executable(jdk.jdtls_java) == 1 then
        table.insert(opts.cmd, 2, "--java-executable=" .. jdk.jdtls_java)
      end
      guards.check_jdtls_jdk()

      -- jdtls would otherwise build projects and run Gradle on its own JDK instead of the JDK the
      -- CLI builds use.
      local project_jdk = jdk.project_jdk()
      local major = jdk.major(project_jdk)
      if major then
        opts.settings = vim.tbl_deep_extend("force", opts.settings or {}, {
          java = {
            configuration = { runtimes = { { name = "JavaSE-" .. major, path = project_jdk, default = true } } },
            import = { gradle = { java = { home = project_jdk } } },
          },
        })
      end

      -- Explain crashes (e.g. exit 13 after a Mason upgrade outpaces the jdtls JDK).
      local user_jdtls = opts.jdtls
      opts.jdtls = function(config)
        if type(user_jdtls) == "function" then
          config = user_jdtls(config) or config
        elseif type(user_jdtls) == "table" then
          config = vim.tbl_deep_extend("force", config, user_jdtls)
        end
        config.on_exit = guards.jdtls_on_exit(jdk.jdtls_project_name(config.root_dir))
        return config
      end

      guards.gate_jdtls()
      return opts
    end,
  },
  {
    "mason-org/mason.nvim",
    optional = true,
    opts = function()
      require("scala.guards").watch_mason()
    end,
  },
}

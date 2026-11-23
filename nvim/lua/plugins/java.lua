-- jdtls for Gradle/Maven Java (layered on LazyVim's lang.java extra). Java inside sbt builds is
-- left to Metals (see plugins/scala.lua).
local build_root = require("utils.build_root")

-- Provided by home-manager (home/base.nix); recent jdtls releases need Java 25 just to start.
local jdtls_java = vim.fn.expand("~/.local/share/jdtls-jdk/bin/java")

local function project_jdk()
  if vim.env.JAVA_HOME and vim.env.JAVA_HOME ~= "" then
    return vim.env.JAVA_HOME
  end
  if vim.fn.executable("/usr/libexec/java_home") == 1 then
    local home = vim.trim(vim.fn.system({ "/usr/libexec/java_home" }))
    if vim.v.shell_error == 0 then
      return home
    end
  end
end

local function jdtls_root(path)
  return build_root.find(path, { gradle = true, maven = true })
end

return {
  {
    "mfussenegger/nvim-jdtls",
    opts = function(_, opts)
      -- The default root markers include gradlew (nested in some subprojects) and .git (the whole
      -- monorepo); anchor on settings.gradle/pom.xml instead.
      opts.root_dir = jdtls_root
      -- Basenames collide across the repo (several build-logic/ and java/ roots), which would
      -- make unrelated projects share one jdtls workspace.
      opts.project_name = function(root_dir)
        return root_dir and vim.fn.fnamemodify(root_dir, ":~"):gsub("^~/", ""):gsub("[/~]", "_")
      end

      if vim.fn.executable(jdtls_java) == 1 then
        table.insert(opts.cmd, 2, "--java-executable=" .. jdtls_java)
      end
      -- jdtls would otherwise build projects and run Gradle on its own JDK 25 instead of the JDK
      -- the CLI builds use.
      local jdk = project_jdk()
      local release = jdk and vim.fn.filereadable(jdk .. "/release") == 1 and vim.fn.readfile(jdk .. "/release") or {}
      local major
      for _, line in ipairs(release) do
        major = major or line:match('^JAVA_VERSION="(%d+)')
      end
      if major then
        opts.settings = vim.tbl_deep_extend("force", opts.settings or {}, {
          java = {
            configuration = { runtimes = { { name = "JavaSE-" .. major, path = jdk, default = true } } },
            import = { gradle = { java = { home = jdk } } },
          },
        })
      end

      -- LazyVim attaches jdtls to every Java buffer, and nvim-jdtls falls back to the .git root
      -- when root_dir is nil. Skip those buffers instead (Metals owns Java in sbt builds).
      local jdtls = require("jdtls")
      if not jdtls._root_gated then
        local start_or_attach = jdtls.start_or_attach
        jdtls.start_or_attach = function(config, ...)
          if config.root_dir then
            return start_or_attach(config, ...)
          end
        end
        jdtls._root_gated = true
      end
      return opts
    end,
  },
}

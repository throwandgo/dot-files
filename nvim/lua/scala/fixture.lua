-- A miniature monorepo reproducing the layouts that broke root detection before.
local M = {}

local files = {
  -- Aggregating sbt build; modules/app also looks like a standalone build (it has project/), as
  -- finance/payment/payment-service does, and must still resolve to sbt/.
  ["sbt/build.sbt"] = {
    'ThisBuild / scalaVersion := "2.13.18"',
    'lazy val app = project in file("./modules/app")',
  },
  ["sbt/project/build.properties"] = { "sbt.version=1.12.11" },
  ["sbt/project/plugins.sbt"] = { "// meta-build marker" },
  ["sbt/modules/app/build.sbt"] = { 'name := "app"' },
  ["sbt/modules/app/project/plugins.sbt"] = { "// standalone-looking subproject" },
  ["sbt/modules/app/src/main/scala/smoke/Main.scala"] = {
    "package smoke",
    "",
    "object Main {",
    "  val xs: List[Int] = List(1, 2)",
    "  def run(): String = Helper.greet",
    "  val total = xs.sum",
    "}",
  },
  ["sbt/modules/app/src/main/scala/smoke/Helper.scala"] = {
    "package smoke",
    "",
    "object Helper extends Greeter {",
    '  def greet: String = "hi"',
    "}",
  },
  ["sbt/modules/app/src/main/scala/smoke/Greeter.scala"] = {
    "package smoke",
    "",
    "trait Greeter {",
    "  def greet: String",
    "}",
  },
  ["sbt/modules/app/src/main/java/smoke/Util.java"] = {
    "package smoke;",
    "",
    "public class Util {}",
  },
  ["maven/pom.xml"] = {
    '<project xmlns="http://maven.apache.org/POM/4.0.0">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>smoke</groupId>",
    "  <artifactId>smoke</artifactId>",
    "  <version>1</version>",
    "  <properties><maven.compiler.release>21</maven.compiler.release></properties>",
    "</project>",
  },
  ["maven/src/main/java/smoke/App.java"] = {
    "package smoke;",
    "",
    "public class App {",
    "  public static void main(String[] args) {}",
    "}",
  },
  ["loose/Loose.scala"] = { "object Loose" },
}

-- path -> { metals = expected root, jdtls = expected root } (relative to the fixture)
M.expected = {
  ["sbt/modules/app/src/main/scala/smoke/Main.scala"] = { metals = "sbt" },
  ["sbt/modules/app/src/main/java/smoke/Util.java"] = { metals = "sbt" },
  ["sbt/build.sbt"] = { metals = "sbt" },
  ["maven/src/main/java/smoke/App.java"] = { jdtls = "maven" },
  ["loose/Loose.scala"] = {},
}

---@param dir string
---@return string dir
function M.create(dir)
  for rel, lines in pairs(files) do
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
  end
  -- Bounds the root search like the real repo's .git does.
  vim.fn.mkdir(dir .. "/.git", "p")
  return dir
end

-- Checks build_root against M.expected.
---@return string[] failures
function M.check_roots(dir)
  local build_root = require("utils.build_root")
  local failures = {}
  for rel, want in pairs(M.expected) do
    for _, server in ipairs({ "metals", "jdtls" }) do
      local got = build_root[server .. "_root"](dir .. "/" .. rel)
      local expected = want[server] and (dir .. "/" .. want[server]) or nil
      if got ~= expected then
        table.insert(
          failures,
          ("%s root for %s: got %s, expected %s"):format(
            server,
            rel,
            got and got:sub(#dir + 2) or "nil",
            want[server] or "nil"
          )
        )
      end
    end
  end
  table.sort(failures)
  return failures
end

return M

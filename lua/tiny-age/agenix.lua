local Common = require("tiny-age.common")
local Process = require("tiny-age.process")

local M = {}

function M.from_file(rules)
  rules = Common.normalize_path(rules)
  local directory = vim.fs.dirname(rules):gsub("/$", "") .. "/"

  return function(path)
    local name = path:sub(#directory + 1)
    local output = Process.run({
      "nix-instantiate",
      "--eval",
      "--strict",
      "--json",
      "--option",
      "allow-import-from-derivation",
      "false",
      "--argstr",
      "rules_file",
      rules,
      "--argstr",
      "secret_name",
      name,
      "--expr",
      "{ rules_file, secret_name }: (builtins.getAttr secret_name (import (builtins.toPath rules_file))).publicKeys",
    })

    return vim.json.decode(output)
  end
end

return M

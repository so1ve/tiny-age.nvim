local Common = require("tiny-age.common")
local Process = require("tiny-age.process")

local M = {}

local function split_path(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  return parts
end

local function relative_path(base, target)
  local base_parts = split_path(base)
  local target_parts = split_path(target)

  local common = 0
  local limit = math.min(#base_parts, #target_parts)
  while common < limit and base_parts[common + 1] == target_parts[common + 1] do
    common = common + 1
  end

  local parts = {}
  for _ = common + 1, #base_parts do
    table.insert(parts, "..")
  end
  for i = common + 1, #target_parts do
    table.insert(parts, target_parts[i])
  end

  return table.concat(parts, "/")
end

function M.from_file(rules)
  rules = Common.normalize_path(rules)
  local directory = vim.fs.dirname(rules)

  return function(path)
    local name = relative_path(directory, Common.normalize_path(path))
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

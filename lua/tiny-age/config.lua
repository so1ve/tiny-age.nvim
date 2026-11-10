local M = {}

local defaults = {
  age = "age",
  suffixes = { ".age" },
  identities = {},
  recipients = {},
  new_file_armor = true,
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
  local options = vim.deepcopy(vim.tbl_extend("force", defaults, opts or {}))

  for _, suffix in ipairs(options.suffixes) do
    if suffix == "" then
      error("tiny-age: suffixes must not be empty strings")
    end
  end

  M.options = options
end

return M

local M = {}

M.defaults = {
  age = "age",
  suffixes = { ".age" },
  identities = {},
  recipients = {},
  recipient_files = {},
  encrypt_to_identity = false,
  new_file_armor = true,
}

M.options = vim.deepcopy(M.defaults)

local LIST_OPTIONS = { "suffixes", "identities", "recipients", "recipient_files" }

local function normalize_list(name, value)
  if type(value) == "string" then
    if value == "" then
      error(("tiny-age: `%s` must only contain non-empty strings"):format(name))
    end

    return { value }
  end

  if type(value) ~= "table" then
    error(("tiny-age: `%s` must be a string or list of strings"):format(name))
  end

  for _, item in ipairs(value) do
    if type(item) ~= "string" or item == "" then
      error(("tiny-age: `%s` must only contain non-empty strings"):format(name))
    end
  end

  return vim.deepcopy(value)
end

local function validate(options)
  if type(options.age) ~= "string" or options.age == "" then
    error("tiny-age: `age` must be a non-empty string")
  end

  if type(options.encrypt_to_identity) ~= "boolean" then
    error("tiny-age: `encrypt_to_identity` must be a boolean")
  end

  if type(options.new_file_armor) ~= "boolean" then
    error("tiny-age: `new_file_armor` must be a boolean")
  end
end

function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("tiny-age: setup() expects a table")
  end

  local options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  for _, name in ipairs(LIST_OPTIONS) do
    options[name] = normalize_list(name, options[name])
  end

  validate(options)
  M.options = options
end

return M

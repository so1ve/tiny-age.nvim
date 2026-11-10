local api = vim.api

local Age = require("tiny-age.age")
local Common = require("tiny-age.common")
local Config = require("tiny-age.config")
local Filesystem = require("tiny-age.filesystem")

local M = {}
local write_group = api.nvim_create_augroup("tiny-age.write", { clear = true })

local function set_private_options(buf)
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
  vim.bo[buf].fixendofline = false
end

local function write(buf, path)
  path = Common.normalize_path(path)
  local text = Common.lines_to_text(buf)

  if text:find("\0", 1, true) then
    error("tiny-age: binary content cannot be encrypted safely")
  end

  local ciphertext = Age.encrypt(path, text, vim.b[buf].tiny_age_armored)
  Filesystem.atomic_write(path, ciphertext)
  vim.bo[buf].modified = false
end

local function attach_write_command(buf)
  api.nvim_clear_autocmds({ group = write_group, buffer = buf })
  api.nvim_create_autocmd("BufWriteCmd", {
    group = write_group,
    buffer = buf,
    callback = function(event)
      write(buf, event.match)
    end,
  })
end

local function setup_buffer(buf, armored)
  vim.bo[buf].buftype = "acwrite"
  vim.b[buf].tiny_age_armored = armored
  attach_write_command(buf)
end

local function set_filetype(buf, path, lines)
  local filetype = vim.filetype.match({
    filename = Common.decrypted_name(path, Config.options.suffixes),
    contents = lines,
  })

  if filetype then
    vim.bo[buf].filetype = filetype
  end
end

local function show_read_error(buf, path, message)
  local lines = {
    "Could not decrypt " .. vim.fs.basename(path),
    "",
  }
  vim.list_extend(lines, vim.split(message, "\n", { plain = true }))

  api.nvim_clear_autocmds({ group = write_group, buffer = buf })
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nowrite"
  vim.bo[buf].filetype = ""
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.schedule(function()
    vim.notify("tiny-age: could not decrypt " .. path .. "\n" .. message, vim.log.levels.ERROR)
  end)
end

local function new(buf, path)
  set_private_options(buf)
  setup_buffer(buf, Config.options.new_file_armor)
  set_filetype(buf, path, { "" })
  vim.bo[buf].endofline = true
end

local function read(buf, path)
  set_private_options(buf)

  local ok, plaintext, armored = pcall(function()
    local armored = Filesystem.is_armored(path)
    if armored == nil then
      return nil
    end
    local plaintext = Age.decrypt(path)
    if plaintext:find("\0", 1, true) then
      error("decrypted content is binary and cannot be edited safely")
    end
    return plaintext, armored
  end)

  if not ok then
    show_read_error(buf, path, plaintext)
    return
  end

  if plaintext == nil then
    new(buf, path)
    return
  end

  local lines, endofline = Common.text_to_lines(plaintext)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].endofline = endofline
  vim.bo[buf].modified = false

  setup_buffer(buf, armored)
  set_filetype(buf, path, lines)
end

function M.open(path)
  path = Common.normalize_path(path)
  local buf = vim.fn.bufadd(path)
  read(buf, path)
  api.nvim_set_current_buf(buf)
end

function M.setup()
  local patterns = {}
  for _, suffix in ipairs(Config.options.suffixes) do
    table.insert(patterns, "*" .. suffix)
  end

  local group = api.nvim_create_augroup("tiny-age", { clear = true })

  if #patterns > 0 then
    api.nvim_create_autocmd("BufReadCmd", {
      group = group,
      pattern = patterns,
      callback = function(event)
        read(event.buf, api.nvim_buf_get_name(event.buf))
      end,
    })

    api.nvim_create_autocmd("BufNewFile", {
      group = group,
      pattern = patterns,
      callback = function(event)
        new(event.buf, api.nvim_buf_get_name(event.buf))
      end,
    })
  end

  api.nvim_create_user_command("AgeEdit", function(event)
    M.open(event.args)
  end, {
    nargs = 1,
    complete = "file",
    desc = "Edit an age-encrypted file",
    force = true,
  })
end

return M

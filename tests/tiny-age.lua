vim.opt.runtimepath:prepend(vim.fn.getcwd())

local bit = require("bit")
local uv = vim.uv

local Config = require("tiny-age.config")
local TinyAge = require("tiny-age")

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function run(cmd, stdin)
  local result = vim.system(cmd, { stdin = stdin, text = false }):wait()
  if result.code ~= 0 then
    error(("command failed (%d): %s\n%s"):format(result.code, table.concat(cmd, " "), result.stderr or ""))
  end

  return result.stdout or ""
end

local function read_file(path)
  local fd = assert(uv.fs_open(path, "r", 0))
  local stat = assert(uv.fs_fstat(fd))
  local data = assert(uv.fs_read(fd, stat.size, 0))
  assert(uv.fs_close(fd))
  return data
end

local function file_mode(path)
  return bit.band(assert(uv.fs_stat(path)).mode, tonumber("777", 8))
end

local age_bin = vim.env.AGE_BIN or vim.fn.exepath("age")
assert(age_bin ~= "", "age is required; set AGE_BIN or add age to PATH")

local function create_encrypted(path, recipient, content, armor)
  local cmd = {
    age_bin,
    "--encrypt",
    "--recipient",
    recipient,
    "--output",
    path,
  }

  if armor then
    table.insert(cmd, 2, "--armor")
  end

  run(cmd, content)
end

local function decrypt(path, identity)
  return run({
    age_bin,
    "--decrypt",
    "--identity",
    identity,
    path,
  })
end

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local keygen_bin = vim.fs.joinpath(vim.fs.dirname(age_bin), "age-keygen")
local keygen = vim.system({ keygen_bin }, { text = true }):wait()
assert(keygen.code == 0, keygen.stderr)

local identity = vim.fn.join(vim.split(vim.trim(keygen.stdout), "\n"), "\n") .. "\n"
local recipient = assert(keygen.stderr:match("(age1[%w]+)"), "could not read generated recipient")
local identity_path = vim.fs.joinpath(root, "identity.txt")
assert(vim.fn.writefile(vim.split(identity, "\n", { plain = true }), identity_path) == 0)
assert(uv.fs_chmod(identity_path, tonumber("600", 8)))

TinyAge.setup({
  age = age_bin,
  identities = { identity_path },
  recipients = { recipient },
})
assert(not pcall(TinyAge.setup, { suffixes = { "" } }), "empty suffixes are rejected")

local encrypted_path = vim.fs.joinpath(root, "settings.yaml.age")
create_encrypted(encrypted_path, recipient, "name: first\n", true)
assert(uv.fs_chmod(encrypted_path, tonumber("640", 8)))

vim.cmd.edit(vim.fn.fnameescape(encrypted_path))

local buf = vim.api.nvim_get_current_buf()
assert_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "name: first" }, "decrypted content")
assert_equal(vim.bo[buf].filetype, "yaml", "filetype from decrypted filename")
assert_equal(vim.bo[buf].buftype, "acwrite", "buffer type")
assert_equal(vim.bo[buf].swapfile, false, "swapfile is disabled")
assert_equal(vim.bo[buf].undofile, false, "undofile is disabled")
assert_equal(vim.bo[buf].modified, false, "buffer starts unmodified")

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "name: second", "enabled: true" })
vim.cmd.write()

assert_equal(vim.bo[buf].modified, false, "buffer is unmodified after writing")
assert_equal(decrypt(encrypted_path, identity_path), "name: second\nenabled: true\n", "round-trip content")

local ciphertext = read_file(encrypted_path)
assert(ciphertext:find("-----BEGIN AGE ENCRYPTED FILE-----", 1, true), "armor is preserved")
assert(not ciphertext:find("name: second", 1, true), "plaintext is not written to disk")
assert_equal(file_mode(encrypted_path), tonumber("640", 8), "mode is preserved")

local empty_path = vim.fs.joinpath(root, "empty.age")
create_encrypted(empty_path, recipient, "", true)
vim.cmd.edit(vim.fn.fnameescape(empty_path))
vim.cmd.write()
assert_equal(decrypt(empty_path, identity_path), "", "empty plaintext stays empty")

local newline_path = vim.fs.joinpath(root, "newline.age")
create_encrypted(newline_path, recipient, "\n", true)
vim.cmd.edit(vim.fn.fnameescape(newline_path))
vim.cmd.write()
assert_equal(decrypt(newline_path, identity_path), "\n", "a single newline is preserved")

local no_eol_path = vim.fs.joinpath(root, "no-eol.age")
create_encrypted(no_eol_path, recipient, "value without newline", true)
vim.cmd.edit(vim.fn.fnameescape(no_eol_path))
vim.cmd.write()
assert_equal(decrypt(no_eol_path, identity_path), "value without newline", "missing final newline is preserved")

local custom_path = vim.fs.joinpath(root, "secret with spaces.enc")
create_encrypted(custom_path, recipient, "custom suffix\n", false)
vim.cmd("AgeEdit " .. vim.fn.fnameescape(custom_path))
assert_equal(
  vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false),
  { "custom suffix" },
  "AgeEdit handles files without an .age suffix"
)
vim.cmd.write()
assert(not read_file(custom_path):find("-----BEGIN AGE ENCRYPTED FILE-----", 1, true), "binary armor is preserved")

TinyAge.setup({
  age = age_bin,
  identities = { identity_path },
  encrypt_to_identity = true,
})

assert_equal(Config.options.recipients, {}, "setup resets omitted list options")

local new_path = vim.fs.joinpath(root, "new-secret.age")
vim.cmd.edit(vim.fn.fnameescape(new_path))
buf = vim.api.nvim_get_current_buf()
assert_equal(vim.bo[buf].buftype, "acwrite", "new age file is writable through age")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "token: generated" })
vim.cmd.write()

assert_equal(decrypt(new_path, identity_path), "token: generated\n", "identity is used as a recipient")
assert_equal(file_mode(new_path), tonumber("600", 8), "new encrypted files use private permissions")
assert(read_file(new_path):find("-----BEGIN AGE ENCRYPTED FILE-----", 1, true), "new files are armored")

local invalid_path = vim.fs.joinpath(root, "invalid.age")
assert(vim.fn.writefile({ "not encrypted" }, invalid_path) == 0)
local invalid_contents = read_file(invalid_path)
local notifications = {}
local notify = vim.notify
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end
vim.cmd.edit(vim.fn.fnameescape(invalid_path))

assert(vim.wait(100, function()
  return #notifications > 0
end), "invalid age files report an error")
vim.notify = notify

buf = vim.api.nvim_get_current_buf()
assert_equal(vim.bo[buf].buftype, "nowrite", "invalid encrypted files cannot be written")
assert_equal(notifications[1].level, vim.log.levels.ERROR, "read failures are reported as errors")
assert(not pcall(vim.cmd.write), "writing an invalid encrypted file fails")
assert_equal(read_file(invalid_path), invalid_contents, "invalid file is not overwritten")

local binary_path = vim.fs.joinpath(root, "binary.age")
create_encrypted(binary_path, recipient, "before\0after", true)
notifications = {}
notify = vim.notify
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end
vim.cmd.edit(vim.fn.fnameescape(binary_path))

assert(vim.wait(100, function()
  return #notifications > 0
end), "binary plaintext reports an error")
vim.notify = notify
assert(notifications[1].message:find("binary", 1, true), "binary errors explain the problem")

TinyAge.setup({
  age = age_bin,
  identities = { identity_path },
  recipients = { recipient },
})
vim.cmd.edit(vim.fn.fnameescape(encrypted_path))
buf = vim.api.nvim_get_current_buf()
local before_failure = read_file(encrypted_path)
TinyAge.setup({
  age = vim.fs.joinpath(root, "missing-age"),
  recipients = { recipient },
})
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "must: survive" })
assert(not pcall(vim.cmd.write), "encryption failure aborts the write")
assert_equal(read_file(encrypted_path), before_failure, "encryption failure does not replace the file")
assert_equal(vim.bo[buf].modified, true, "failed writes leave the buffer modified")

vim.fn.delete(root, "rf")
vim.api.nvim_out_write("tiny-age tests passed\n")

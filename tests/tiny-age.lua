vim.opt.runtimepath:prepend(vim.fn.getcwd())

local bit = require("bit")
local uv = vim.uv

local TinyAge = require("tiny-age")
local Agenix = require("tiny-age.agenix")

local function assert_equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function run(cmd, stdin)
  local result = vim.system(cmd, { stdin = stdin, text = false }):wait()
  if result.code ~= 0 then
    error(("command failed (%d): %s\n%s"):format(result.code, table.concat(cmd, " "), result.stderr))
  end

  return result.stdout
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

local function create_encrypted(path, recipients, content, armor)
  local cmd = {
    age_bin,
    "--encrypt",
    "--output",
    path,
  }

  for _, recipient in ipairs(recipients) do
    vim.list_extend(cmd, { "--recipient", recipient })
  end

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
local function create_identity(name)
  local keygen = vim.system({ keygen_bin }, { text = true }):wait()
  assert(keygen.code == 0, keygen.stderr)

  local path = vim.fs.joinpath(root, name)
  assert(vim.fn.writefile(vim.split(vim.trim(keygen.stdout), "\n", { plain = true }), path) == 0)
  assert(uv.fs_chmod(path, tonumber("600", 8)))
  return path, assert(keygen.stderr:match("(age1[%w]+)"), "could not read generated recipient")
end

local identity_path, recipient = create_identity("identity.txt")

TinyAge.setup({
  age = age_bin,
  identities = { identity_path },
  recipients = { recipient },
})
assert(not pcall(TinyAge.setup, { suffixes = { "" } }), "empty suffixes are rejected")

local encrypted_path = vim.fs.joinpath(root, "settings.yaml.age")
create_encrypted(encrypted_path, { recipient }, "name: first\n", true)
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
create_encrypted(empty_path, { recipient }, "", true)
vim.cmd.edit(vim.fn.fnameescape(empty_path))
vim.cmd.write()
assert_equal(decrypt(empty_path, identity_path), "", "empty plaintext stays empty")

local newline_path = vim.fs.joinpath(root, "newline.age")
create_encrypted(newline_path, { recipient }, "\n", true)
vim.cmd.edit(vim.fn.fnameescape(newline_path))
vim.cmd.write()
assert_equal(decrypt(newline_path, identity_path), "\n", "a single newline is preserved")

local no_eol_path = vim.fs.joinpath(root, "no-eol.age")
create_encrypted(no_eol_path, { recipient }, "value without newline", true)
vim.cmd.edit(vim.fn.fnameescape(no_eol_path))
vim.cmd.write()
assert_equal(decrypt(no_eol_path, identity_path), "value without newline", "missing final newline is preserved")

local custom_path = vim.fs.joinpath(root, "secret with spaces.enc")
create_encrypted(custom_path, { recipient }, "custom suffix\n", false)
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
  recipients = { recipient },
})

local new_path = vim.fs.joinpath(root, "new-secret.age")
vim.cmd.edit(vim.fn.fnameescape(new_path))
buf = vim.api.nvim_get_current_buf()
assert_equal(vim.bo[buf].buftype, "acwrite", "new age file is writable through age")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "token: generated" })
vim.cmd.write()

assert_equal(decrypt(new_path, identity_path), "token: generated\n", "new files use explicit recipients")
assert_equal(file_mode(new_path), tonumber("600", 8), "new encrypted files use private permissions")
assert(read_file(new_path):find("-----BEGIN AGE ENCRYPTED FILE-----", 1, true), "new files are armored")

local host_identity, host_recipient = create_identity("host.txt")
local rules_root = vim.fs.joinpath(root, "agenix project")
vim.fn.mkdir(vim.fs.joinpath(rules_root, "homelab"), "p")
local rules_path = vim.fs.joinpath(rules_root, "rules with spaces.nix")
assert(vim.fn.writefile({
  ("let user = %q; host = %q; in {"):format(recipient, host_recipient),
  '  "homelab/moviepilot-env.age".publicKeys = [ user host ];',
  "}",
}, rules_path) == 0)

TinyAge.setup({
  age = age_bin,
  identities = { identity_path },
  recipients = Agenix.from_file(rules_path),
})

local shared_path = vim.fs.joinpath(rules_root, "homelab/moviepilot-env.age")
create_encrypted(shared_path, { recipient, host_recipient }, "TOKEN=before\n", true)
vim.cmd.edit(vim.fn.fnameescape(shared_path))
buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "TOKEN=after" })
vim.cmd.write()
assert_equal(decrypt(shared_path, identity_path), "TOKEN=after\n", "agenix keeps the user's access")
assert_equal(decrypt(shared_path, host_identity), "TOKEN=after\n", "agenix keeps the host's access")

assert(vim.fn.writefile({
  ("let user = %q; host = %q; in {"):format(recipient, host_recipient),
  '  "homelab/moviepilot-env.age".publicKeys = [ user ];',
  '  "homelab/new.age".publicKeys = [ host ];',
  "}",
}, rules_path) == 0)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "TOKEN=updated" })
vim.cmd.write()
assert_equal(decrypt(shared_path, identity_path), "TOKEN=updated\n", "rules are read again on each write")
assert(
  vim.system({ age_bin, "--decrypt", "--identity", host_identity, shared_path }):wait().code ~= 0,
  "recipients removed from the rules lose access"
)

local new_shared_path = vim.fs.joinpath(rules_root, "homelab/new.age")
vim.cmd.edit(vim.fn.fnameescape(new_shared_path))
buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "new shared secret" })
vim.cmd.write()
assert_equal(decrypt(new_shared_path, host_identity), "new shared secret\n", "new files use their own rule")
assert(
  vim.system({ age_bin, "--decrypt", "--identity", identity_path, new_shared_path }):wait().code ~= 0,
  "each file is encrypted only to the recipients in its rule"
)

local sibling_dir = vim.fs.joinpath(root, "modules/hosts/vesper/secrets")
vim.fn.mkdir(sibling_dir, "p")
local sibling_path = vim.fs.joinpath(sibling_dir, "host-secret.age")
create_encrypted(sibling_path, { recipient, host_recipient }, "HOST=before\n", true)
assert(vim.fn.writefile({
  ("let user = %q; host = %q; in {"):format(recipient, host_recipient),
  '  "../modules/hosts/vesper/secrets/host-secret.age".publicKeys = [ user host ];',
  "}",
}, rules_path) == 0)
vim.cmd.edit(vim.fn.fnameescape(sibling_path))
buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "HOST=after" })
vim.cmd.write()
assert_equal(decrypt(sibling_path, identity_path), "HOST=after\n", "relative ../ rules keep the user's access")
assert_equal(decrypt(sibling_path, host_identity), "HOST=after\n", "relative ../ rules keep the host's access")

vim.cmd.edit(vim.fn.fnameescape(shared_path))
buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "must survive invalid rules" })
local before_rules_failure = read_file(shared_path)
for _, rules in ipairs({
  "{",
  "{}",
  '{ "homelab/moviepilot-env.age".publicKeys = []; }',
  '{ "homelab/moviepilot-env.age".publicKeys = "not a list"; }',
  '{ "homelab/moviepilot-env.age".publicKeys = [ 1 ]; }',
  '{ "homelab/moviepilot-env.age".publicKeys = [ "invalid public key" ]; }',
}) do
  assert(vim.fn.writefile({ rules }, rules_path) == 0)
  local ok = pcall(vim.cmd.write)
  assert(not ok, "invalid agenix rules abort the write")
  assert_equal(read_file(shared_path), before_rules_failure, "rules errors do not replace the file")
  assert_equal(vim.bo[buf].modified, true, "rules errors leave the buffer modified")
end

local saved_path = vim.env.PATH
vim.env.PATH = root
local wrote_without_nix, missing_nix_error = pcall(vim.cmd.write)
vim.env.PATH = saved_path
assert(not wrote_without_nix, "missing Nix aborts the write")
assert(tostring(missing_nix_error):find("nix-instantiate", 1, true), "missing Nix explains the dependency")
assert_equal(read_file(shared_path), before_rules_failure, "missing Nix does not replace the file")
assert_equal(vim.bo[buf].modified, true, "missing Nix leaves the buffer modified")

TinyAge.setup({
  age = age_bin,
  identities = { identity_path },
})
assert(not pcall(vim.cmd.write), "identities alone cannot be used to encrypt")
assert_equal(read_file(shared_path), before_rules_failure, "missing recipients do not replace the file")
assert_equal(vim.bo[buf].modified, true, "missing recipients leave the buffer modified")

TinyAge.setup({
  age = age_bin,
  identities = { identity_path },
  recipients = { recipient },
})
vim.cmd.write()
assert_equal(
  decrypt(shared_path, identity_path),
  "must survive invalid rules\n",
  "static recipients are independent of agenix rules"
)

local before_write_failure = read_file(shared_path)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "before\0after" })
assert(not pcall(vim.cmd.write), "inserting binary content aborts the write")
assert_equal(read_file(shared_path), before_write_failure, "binary content does not replace the file")
assert_equal(vim.bo[buf].modified, true, "rejected binary content remains modified")

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "must survive failed replacement" })
for _, operation in ipairs({ "fs_write", "fs_rename" }) do
  local original = uv[operation]
  uv[operation] = function()
    return nil, "EIO: input/output error", "EIO"
  end
  local wrote, write_error = pcall(vim.cmd.write)
  uv[operation] = original

  assert(not wrote, operation .. " failure aborts the write")
  assert(tostring(write_error):find("EIO", 1, true), "the I/O error is propagated")
  assert_equal(read_file(shared_path), before_write_failure, "failed writes preserve the original ciphertext")
  assert_equal(vim.bo[buf].modified, true, "failed writes leave the buffer modified")
  assert_equal(
    vim.fn.glob(vim.fs.joinpath(rules_root, "homelab/.tiny-age-*"), false, true),
    {},
    "failed writes remove the temporary file"
  )
end
vim.cmd.write()
assert_equal(
  decrypt(shared_path, identity_path),
  "must survive failed replacement\n",
  "the buffer can be saved after a failed write"
)

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
create_encrypted(binary_path, { recipient }, "before\0after", true)
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

TinyAge.setup({
  age = age_bin,
  identities = { identity_path },
  recipients = { recipient },
})

local reload_path = vim.fs.joinpath(root, "reload.yaml.age")
create_encrypted(reload_path, { recipient }, "line: 1\nline: 2\n", true)
vim.cmd.edit(vim.fn.fnameescape(reload_path))
local reload_buf = vim.api.nvim_get_current_buf()
assert_equal(vim.api.nvim_buf_get_lines(reload_buf, 0, -1, false), { "line: 1", "line: 2" }, "initial reload fixture")

vim.cmd.enew()
create_encrypted(reload_path, { recipient }, "updated: 1\nupdated: 2\nupdated: 3\n", true)
vim.cmd("silent! edit " .. vim.fn.fnameescape(reload_path) .. " | 2")
assert_equal(vim.api.nvim_get_current_buf(), reload_buf, "reuses the existing buffer")
assert_equal(
  vim.api.nvim_buf_get_lines(reload_buf, 0, -1, false),
  { "updated: 1", "updated: 2", "updated: 3" },
  "hidden buffer reloads on BufEnter after external change"
)
assert_equal(vim.bo[reload_buf].modified, false, "reloaded buffer stays unmodified")
assert_equal(vim.api.nvim_win_get_cursor(0)[1], 2, "edit command line jump lands on the reloaded buffer")

create_encrypted(reload_path, { recipient }, "focus: 1\nfocus: 2\nfocus: 3\n", true)
vim.api.nvim_exec_autocmds("FocusGained", {})
assert_equal(
  vim.api.nvim_buf_get_lines(reload_buf, 0, -1, false),
  { "focus: 1", "focus: 2", "focus: 3" },
  "visible buffer reloads on FocusGained after external change"
)
assert_equal(vim.api.nvim_win_get_cursor(0)[1], 2, "FocusGained reload preserves cursor line")

vim.api.nvim_buf_set_lines(reload_buf, 0, -1, false, { "unsaved: true" })
vim.cmd.enew()
create_encrypted(reload_path, { recipient }, "disk: version\n", true)
notifications = {}
notify = vim.notify
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end
vim.cmd("silent! edit " .. vim.fn.fnameescape(reload_path))
assert(vim.wait(100, function()
  return #notifications == 1
end), "external change on modified buffer emits a warning")
assert_equal(notifications[1].level, vim.log.levels.WARN, "conflict notice is a warning")
assert_equal(vim.api.nvim_buf_get_lines(reload_buf, 0, -1, false), { "unsaved: true" }, "unsaved changes are preserved")
assert_equal(vim.bo[reload_buf].modified, true, "modified buffer stays modified")

vim.cmd.enew()
vim.cmd("silent! edit " .. vim.fn.fnameescape(reload_path))
vim.wait(50, function()
  return #notifications > 1
end)
assert_equal(#notifications, 1, "unchanged conflict is not reported repeatedly")
vim.notify = notify

vim.cmd("edit!")
assert_equal(vim.api.nvim_buf_get_lines(reload_buf, 0, -1, false), { "disk: version" }, "edit! reloads disk content")
assert_equal(vim.bo[reload_buf].modified, false, "edit! clears modified flag")

vim.api.nvim_buf_set_lines(reload_buf, 0, -1, false, { "saved: locally" })
vim.cmd.write()
vim.cmd.enew()
TinyAge.setup({
  age = vim.fs.joinpath(root, "missing-age"),
  identities = { identity_path },
  recipients = { recipient },
})
vim.cmd("silent! edit " .. vim.fn.fnameescape(reload_path))
assert_equal(
  vim.api.nvim_buf_get_lines(reload_buf, 0, -1, false),
  { "saved: locally" },
  "saving updates recorded stat so re-entering does not re-decrypt"
)
assert_equal(vim.bo[reload_buf].buftype, "acwrite", "buffer stays writable when stat matches")

TinyAge.setup({
  age = age_bin,
  identities = { identity_path },
  recipients = { recipient },
})

vim.cmd("silent! edit " .. vim.fn.fnameescape(invalid_path))
local invalid_buf = vim.api.nvim_get_current_buf()
assert_equal(vim.bo[invalid_buf].buftype, "nowrite", "invalid buffer starts nowrite")
vim.cmd.enew()
create_encrypted(invalid_path, { recipient }, "recovered: true\n", true)
vim.cmd("silent! edit " .. vim.fn.fnameescape(invalid_path))
assert_equal(
  vim.api.nvim_buf_get_lines(invalid_buf, 0, -1, false),
  { "recovered: true" },
  "fixed file recovers on BufEnter"
)
assert_equal(vim.bo[invalid_buf].buftype, "acwrite", "recovered buffer becomes acwrite")
assert_equal(vim.bo[invalid_buf].modifiable, true, "recovered buffer becomes modifiable")

vim.cmd("AgeEdit " .. vim.fn.fnameescape(custom_path))
local custom_buf = vim.api.nvim_get_current_buf()
vim.cmd.enew()
create_encrypted(custom_path, { recipient }, "custom updated\n", false)
vim.cmd("silent! edit " .. vim.fn.fnameescape(custom_path))
assert_equal(
  vim.api.nvim_buf_get_lines(custom_buf, 0, -1, false),
  { "custom updated" },
  "AgeEdit buffer reloads on BufEnter after external change"
)

vim.fn.delete(root, "rf")
vim.api.nvim_out_write("tiny-age tests passed\n")

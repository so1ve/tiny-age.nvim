local uv = vim.uv
local bit = require("bit")

local M = {}

function M.stat(path)
  local stat, stat_error, stat_code = uv.fs_stat(path)
  if not stat then
    if stat_code == "ENOENT" then
      return nil
    end
    error(stat_error)
  end

  return {
    dev = stat.dev,
    ino = stat.ino,
    size = stat.size,
    mtime_sec = stat.mtime.sec,
    mtime_nsec = stat.mtime.nsec,
  }
end

function M.is_armored(path)
  local marker = "-----BEGIN AGE ENCRYPTED FILE-----"
  local fd, open_error, open_code = uv.fs_open(path, "r", 0)
  if open_code == "ENOENT" then
    return nil
  end
  assert(fd, open_error)
  local header, read_error = uv.fs_read(fd, #marker, 0)
  local closed, close_error = uv.fs_close(fd)
  assert(header, read_error)
  assert(closed, close_error)

  return header == marker
end

function M.atomic_write(path, data)
  local stat, stat_error, stat_code = uv.fs_stat(path)
  if not stat and stat_code ~= "ENOENT" then
    error(stat_error)
  end

  local target = stat and assert(uv.fs_realpath(path)) or path
  local mode = stat and bit.band(stat.mode, tonumber("777", 8)) or tonumber("600", 8)
  local fd, temp = assert(uv.fs_mkstemp(vim.fs.dirname(target) .. "/.tiny-age-XXXXXX"))
  local ok, write_error = pcall(function()
    local offset = 0
    while offset < #data do
      local written = assert(uv.fs_write(fd, data:sub(offset + 1), offset))
      assert(written > 0, "file write made no progress")
      offset = offset + written
    end

    assert(uv.fs_fchmod(fd, mode))
    assert(uv.fs_fsync(fd))
  end)
  local closed, close_error = uv.fs_close(fd)

  if not ok or not closed then
    uv.fs_unlink(temp)
    error(write_error or close_error)
  end

  local renamed, rename_error = uv.fs_rename(temp, target)
  if not renamed then
    uv.fs_unlink(temp)
    error(rename_error)
  end
end

return M

local uv = vim.uv
local bit = require("bit")

local M = {}

function M.read_header(path)
  local fd, open_error = uv.fs_open(path, "r", 0)
  if not fd then
    return nil, ("could not open %s: %s"):format(path, open_error)
  end

  local stat, stat_error = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, ("could not stat %s: %s"):format(path, stat_error)
  end

  local header, read_error = uv.fs_read(fd, math.min(stat.size, 64), 0)
  local _, close_error = uv.fs_close(fd)

  if not header then
    return nil, ("could not read %s: %s"):format(path, read_error)
  end

  if close_error then
    return nil, ("could not close %s: %s"):format(path, close_error)
  end

  if header:find("age-encryption.org/v1", 1, true) then
    return false
  end

  if header:find("-----BEGIN AGE ENCRYPTED FILE-----", 1, true) then
    return true
  end

  return nil, "file does not have an age header"
end

local function create_temp_file(target)
  local directory = vim.fs.dirname(target)

  for attempt = 1, 20 do
    local path = ("%s/.tiny-age-tmp.%d.%d.%d"):format(directory, uv.os_getpid(), uv.hrtime(), attempt)
    local fd, err = uv.fs_open(path, "wx", tonumber("600", 8))

    if fd then
      return path, fd
    end

    if not err:find("EEXIST", 1, true) then
      return nil, nil, err
    end
  end

  return nil, nil, "could not allocate a temporary file next to " .. target
end

function M.atomic_write(path, data)
  local target = uv.fs_realpath(path) or path
  local stat = uv.fs_stat(target)
  local mode = stat and bit.band(stat.mode, tonumber("777", 8)) or tonumber("600", 8)
  local temp, fd, temp_error = create_temp_file(target)

  if not fd then
    return nil, temp_error
  end

  local offset = 0
  while offset < #data do
    local written, write_error = uv.fs_write(fd, data:sub(offset + 1), offset)
    if not written or written == 0 then
      uv.fs_close(fd)
      uv.fs_unlink(temp)
      return nil, write_error or "age write made no progress"
    end

    offset = offset + written
  end

  local _, sync_error = uv.fs_fsync(fd)
  local _, close_error = uv.fs_close(fd)

  if sync_error or close_error then
    uv.fs_unlink(temp)
    return nil, sync_error or close_error
  end

  local _, chmod_error = uv.fs_chmod(temp, mode)
  if chmod_error then
    uv.fs_unlink(temp)
    return nil, chmod_error
  end

  local _, rename_error = uv.fs_rename(temp, target)
  if rename_error then
    uv.fs_unlink(temp)
    return nil, rename_error
  end

  return true
end

return M

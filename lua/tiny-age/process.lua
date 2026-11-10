local M = {}

function M.run(cmd, stdin)
  local result = vim.system(cmd, { stdin = stdin, text = false }):wait()
  if result.code ~= 0 then
    error(("%s exited with status %d\n%s"):format(cmd[1], result.code, vim.trim(result.stderr)))
  end
  return result.stdout
end

return M

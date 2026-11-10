local M = {}

function M.normalize_path(path)
  return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
end

function M.decrypted_name(path, suffixes)
  for _, suffix in ipairs(suffixes) do
    if path:sub(-#suffix) == suffix then
      return path:sub(1, -#suffix - 1)
    end
  end

  return path
end

function M.text_to_lines(text)
  if text == "" then
    return { "" }, false
  end

  local lines = vim.split(text, "\n", { plain = true })
  local endofline = lines[#lines] == ""

  if endofline then
    table.remove(lines)
  end

  return lines, endofline
end

function M.lines_to_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return table.concat(lines, "\n") .. (vim.bo[buf].endofline and "\n" or "")
end

return M

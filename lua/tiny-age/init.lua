local Buffer = require("tiny-age.buffer")
local Config = require("tiny-age.config")

local M = {}

function M.setup(opts)
  Config.setup(opts)
  Buffer.setup()
end

function M.edit(path)
  Buffer.open(path)
end

return M

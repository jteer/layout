-- layout/compile.lua
-- Compile the Layout IR into the layout nodes Rex expects.
-- A split node becomes rex.layout.horizontal / rex.layout.vertical.
-- A block node becomes rex.layout.block.

local util = require("layout.util")
local spec = require("layout.spec")
local M = {}

local function options_for(node)
  local opts = util.deepcopy(node.options or {})
  if node.cwd and opts.cwd == nil then opts.cwd = node.cwd end
  if node.command and opts.command == nil then opts.command = util.deepcopy(node.command) end
  if next(opts) == nil then return nil end
  return opts
end

local function compile(node)
  if node.kind == "split" then
    local before = compile(node.before)
    local after = compile(node.after)
    local ratio = node.ratio or 0.5
    if node.direction == "horizontal" then
      return rex.layout.horizontal(ratio, before, after)
    end
    return rex.layout.vertical(ratio, before, after)
  end

  local block = { flavor = node.flavor or spec.DEFAULT_FLAVOR }
  local opts = options_for(node)
  if opts then block.options = opts end
  if node.label then block.label = node.label end
  return rex.layout.block(block)
end

M.compile = compile

-- Shape used for session.create's initial_windows. The field names follow
-- session.new_window (window_label, layout). Verify against your server with:
--   rex api describe session.create --json
function M.windows(ir)
  local out = util.array({})
  for i, w in ipairs(ir.windows) do
    local entry = { layout = compile(w.root) }
    if w.label then entry.window_label = w.label end
    out[i] = entry
  end
  return out
end

return M

-- check.lua
-- Validate a Layoutfile. Runs with `rex do check.lua` or plain `lua check.lua`.
-- Plain Lua: pass args as JSON in LAYOUT_ARGS, for example:
--   LAYOUT_ARGS='{"project":"webapp"}' lua check.lua

local root = os.getenv("LAYOUT_ROOT") or (os.getenv("HOME") .. "/.config/rex/layout")
package.path = root .. "/?.lua;./?.lua;" .. package.path

local spec = require("layout.spec")
local json = require("layout.json")

local standalone = (type(rex) ~= "table")
local args = {}
if not standalone and type(rex.args) == "table" then
  args = rex.args
elseif standalone then
  local raw = os.getenv("LAYOUT_ARGS")
  if raw and raw ~= "" then
    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == "table" then args = decoded end
  end
end

local function result(t)
  if standalone then
    print(json.encode(t, { indent = true }))
  end
  return t
end

local path = spec.find(args.spec)
if not path then
  return result({ ok = false, reason = "no Layoutfile found; pass spec=PATH" })
end
local loaded, err = spec.load(path)
if not loaded then return result({ ok = false, reason = err }) end
local vars, verr = spec.resolve_args(loaded, args)
if not vars then return result({ ok = false, reason = verr }) end
local ir, nerr = spec.normalize(loaded, vars)
if not ir then return result({ ok = false, reason = nerr }) end
local summary = spec.check(ir)

return result({
  ok = true,
  path = path,
  source = loaded.source,
  name = ir.name,
  session_label = ir.session.label,
  windows = summary.windows,
  blocks = summary.blocks,
  warnings = summary.warnings,
})

-- capture.lua
-- Save the current window, or the whole session, as a Layoutfile.
-- Run with: rex do capture.lua [scope=window|session] [format=lua|json] [path=FILE] [session=ID]
--
-- path=- writes nothing, so the recipe can be redirected from the CLI result:
--   rex do capture.lua path=- --json | jq -r .spec > Layoutfile.lua

local root = os.getenv("LAYOUT_ROOT") or (os.getenv("HOME") .. "/.config/rex/layout")
package.path = root .. "/?.lua;./?.lua;" .. package.path

local util = require("layout.util")
local ui = require("layout.ui")
local capture = require("layout.capture")
local provenance = require("layout.provenance")
local document = require("layout.document")
local session = require("layout.session")

local args = (type(rex) == "table" and (rex.args or {})) or {}
local function fail(msg) error("[layout] " .. msg, 0) end
if type(rex) ~= "table" or type(rex.call) ~= "function" then
  fail("capture.lua must be run with `rex do`")
end

local fmt, why = ui.format(args.format)
if fmt == nil then return { cancelled = true, reason = why } end
local scope, why2 = ui.scope(args.scope)
if scope == nil then return { cancelled = true, reason = why2 } end
local dest, why3 = ui.destination(args.path, fmt)
if dest == nil then return { cancelled = true, reason = why3 } end

-- In a Rex terminal REX_SESSION is set. Outside one, fall back to the first
-- session on the server. Labels, positions and short IDs are resolved too.
local session_id = session.resolve(args.session or rex.session_id)
if not session_id then
  local list = rex.call("session.list")
  if type(list) == "table" and type(list.sessions) == "table" and list.sessions[1] then
    session_id = list.sessions[1].session_id
  end
end
if not session_id then fail("no session to capture; pass session=ID") end

local ctx = { session_id = session_id, block_id = rex.block_id }
local view, verr = session.view(session_id)
if verr ~= nil then fail("session.view failed: " .. tostring(verr)) end

local stamp = provenance.get(session_id)
local ir = capture.build(view, {
  scope = scope,
  ctx = ctx,
  session_id = session_id,
  name = args.name or view.label,
})
local notes = capture.drift(ir, stamp)
if stamp and stamp.spec_path then
  notes[#notes + 1] = "Original recipe: " .. stamp.spec_path .. "."
end
for _, w in ipairs(ir.warnings or {}) do notes[#notes + 1] = w end

local text = document.render(ir, fmt, notes)
local wrote = false
if dest ~= "-" then
  local ok, werr = util.write_file(dest, text)
  if not ok then
    return { error = tostring(werr), spec = text, warnings = notes }
  end
  wrote = true
end

return {
  path = wrote and dest or nil,
  format = fmt,
  scope = scope,
  session_id = session_id,
  windows = #ir.windows,
  spec = text,
  warnings = notes,
}

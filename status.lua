-- status.lua
-- Report whether the current session has a stamped recipe and how it drifted.
-- Run with: rex do status.lua [session=ID]

local root = os.getenv("LAYOUT_ROOT") or (os.getenv("HOME") .. "/.config/rex/layout")
package.path = root .. "/?.lua;./?.lua;" .. package.path

local capture = require("layout.capture")
local provenance = require("layout.provenance")
local session = require("layout.session")

local args = (type(rex) == "table" and (rex.args or {})) or {}
if type(rex) ~= "table" or type(rex.call) ~= "function" then
  error("[layout] status.lua must be run with `rex do`", 0)
end

local session_id = session.resolve(args.session or rex.session_id)
if not session_id then
  local list = rex.call("session.list")
  if type(list) == "table" and type(list.sessions) == "table" and list.sessions[1] then
    session_id = list.sessions[1].session_id
  end
end
if not session_id then
  return { stamped = false, reason = "no session found; pass session=ID" }
end

local view, verr = session.view(session_id)
if verr ~= nil then
  return { error = tostring(verr), session_id = session_id }
end

local stamp = provenance.get(session_id)
local ir = capture.build(view, {
  scope = "session",
  ctx = { session_id = session_id },
  session_id = session_id,
})

return {
  stamped = stamp ~= nil,
  session_id = session_id,
  spec_path = stamp and stamp.spec_path or nil,
  created_at = stamp and stamp.created_at or nil,
  windows = #ir.windows,
  drift = capture.drift(ir, stamp),
}

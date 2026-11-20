-- layout/session.lua
-- Resolve a session target and read its view from any shell.

local M = {}

-- Full ID, case insensitive label, 1 based position, or a short ID suffix.
-- Mirrors the target resolution the rex CLI documents.
function M.resolve(value)
  if not value or value == "" then return nil end
  value = tostring(value)
  if value:match("^session:") then return value end

  local list = rex.call("session.list")
  if type(list) ~= "table" or type(list.sessions) ~= "table" then return value end
  local sessions = list.sessions
  local lower = value:lower()

  for _, s in ipairs(sessions) do
    if type(s.label) == "string" and s.label:lower() == lower then
      return s.session_id
    end
  end
  local n = tonumber(value)
  if n and sessions[n] then return sessions[n].session_id end
  for _, s in ipairs(sessions) do
    local id = s.session_id
    if type(id) == "string" and #value <= #id and id:sub(-#value) == value then
      return id
    end
  end
  return value
end

function M.view(session_id)
  local attached, err = rex.call("session.attach", { session_id = session_id })
  if attached ~= nil and type(attached.view) == "table" then
    return attached.view
  end
  local view, verr = rex.session.view{ session_id = session_id }
  if verr ~= nil then return nil, verr or err end
  return view
end

return M

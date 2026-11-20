-- layout/util.lua
-- Small helpers shared by every Layout module. Written for Lua 5.1, which is
-- what Rex embeds. Nothing here needs the rex global.

local M = {}

local array_mt = {}

function M.array(t)
  return setmetatable(t or {}, array_mt)
end

function M.is_array(t)
  if type(t) ~= "table" then return false end
  if getmetatable(t) == array_mt then return true end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n > 0 and n == #t
end

function M.path(...)
  local parts = { ... }
  local out = nil
  for i = 1, #parts do
    local p = parts[i]
    if p ~= nil and p ~= "" then
      p = tostring(p)
      if out == nil then
        out = p:gsub("/+$", "")
      else
        local lead = p:gsub("^/+", "")
        local cleaned = lead:gsub("/+$", "")
        if cleaned ~= "" then out = out .. "/" .. cleaned end
      end
    end
  end
  return out or ""
end

function M.root()
  local r = os.getenv("LAYOUT_ROOT")
  if r and r ~= "" then return r end
  return M.path(os.getenv("HOME") or ".", ".config", "rex", "layout")
end

function M.deepcopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do out[M.deepcopy(k)] = M.deepcopy(val) end
  if getmetatable(v) == array_mt then return setmetatable(out, array_mt) end
  return out
end

function M.merge(a, b)
  local out = M.deepcopy(a or {})
  for k, v in pairs(b or {}) do out[k] = M.deepcopy(v) end
  return out
end

function M.sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

function M.interpolate(value, vars)
  local t = type(value)
  if t == "string" then
    return (value:gsub("{{([%w_%.%-]+)}}", function(key)
      local v = vars[key]
      if v == nil then return nil end
      return tostring(v)
    end))
  elseif t == "table" then
    local out = {}
    for k, v in pairs(value) do out[M.interpolate(k, vars)] = M.interpolate(v, vars) end
    if getmetatable(value) == array_mt then setmetatable(out, array_mt) end
    return out
  end
  return value
end

function M.placeholders(value, found)
  found = found or {}
  local t = type(value)
  if t == "string" then
    for key in value:gmatch("{{([%w_%.%-]+)}}") do found[key] = true end
  elseif t == "table" then
    for k, v in pairs(value) do
      M.placeholders(k, found)
      M.placeholders(v, found)
    end
  end
  return found
end

function M.read_file(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local s = f:read("*a")
  f:close()
  return s
end

function M.write_file(path, text)
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then return nil, err end
  f:write(text)
  f:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return nil, rerr
  end
  return true
end

-- Create a directory tree before writing into it. Rex scripts have io and os
-- but os.execute is removed, so use rex.exec when it is available. Plain Lua
-- runs (the test suite) use os.execute. Returns ok, err.
function M.ensure_dir(dir)
  if not dir or dir == "" or dir == "." then return true end
  local windows = package.config and package.config:sub(1, 1) == "\\"
  if type(rex) == "table" and rex.exec then
    local argv = windows and { "cmd", "/c", "mkdir", dir } or { "mkdir", "-p", dir }
    local r, err = rex.exec(argv)
    if r == nil then return false, err end
    return r.ok, r.stderr
  end
  if type(os.execute) == "function" then
    local cmd = windows and ('mkdir "' .. dir .. '"')
                          or ('mkdir -p "' .. dir .. '"')
    local ok, res = pcall(os.execute, cmd)
    if not ok then return false, res end
    return res == true or res == 0, nil
  end
  return false, "no way to create a directory"
end

return M

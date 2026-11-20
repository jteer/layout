-- layout/spec.lua
-- Load, validate and normalise a Layoutfile into an intermediate representation.
-- The IR is what layout compilation, the provenance stamp and capture output
-- all work from.

local util = require("layout.util")
local json = require("layout.json")
local M = {}

M.DEFAULT_FLAVOR = "com.superlogical.terminal.shell"

local VALID_TYPES = {
  string = true, number = true, integer = true, boolean = true,
  object = true, array = true, any = true,
}

local function safe_env()
  local env = {
    math = math, string = string, table = table,
    pairs = pairs, ipairs = ipairs, next = next, type = type,
    tostring = tostring, tonumber = tonumber, select = select,
    error = error, assert = assert, pcall = pcall,
    os = { getenv = os.getenv, date = os.date, time = os.time },
  }
  if unpack then env.unpack = unpack end
  if table.unpack then env.unpack = table.unpack end
  return env
end

local function run_lua(text, name)
  local env = safe_env()
  local chunk, cerr
  if setfenv then
    chunk, cerr = loadstring(text, name)
  else
    chunk, cerr = load(text, name, "t", env)
  end
  if not chunk then return nil, cerr end
  if setfenv then setfenv(chunk, env) end
  local ok, res = pcall(chunk)
  if not ok then return nil, res end
  return res
end

function M.parse(text, source, path)
  path = path or "<string>"
  if source == "lua" then
    local res, err = run_lua(text, path)
    if res == nil then return nil, "invalid Lua spec " .. path .. ": " .. tostring(err) end
    if type(res) ~= "table" then return nil, "spec must return a table: " .. path end
    return { raw = res, source = "lua", path = path }
  end
  local ok, decoded = pcall(json.decode, text)
  if not ok then return nil, "invalid JSON spec " .. path .. ": " .. tostring(decoded) end
  if type(decoded) ~= "table" then return nil, "spec must be an object: " .. path end
  return { raw = decoded, source = "json", path = path }
end

function M.find(explicit)
  local candidates = {}
  if explicit and explicit ~= "" then candidates[#candidates + 1] = explicit end
  local cwd = os.getenv("PWD") or "."
  candidates[#candidates + 1] = util.path(cwd, "Layoutfile.lua")
  candidates[#candidates + 1] = util.path(cwd, ".rex", "Layoutfile.lua")
  candidates[#candidates + 1] = util.path(util.root(), "Layoutfile.lua")
  for _, p in ipairs(candidates) do
    local f = io.open(p, "r")
    if f then f:close(); return p end
  end
  return nil
end

function M.load(path)
  local text, err = util.read_file(path)
  if not text then return nil, "cannot read " .. path .. ": " .. tostring(err) end
  local source = path:match("%.lua$") and "lua" or "json"
  local loaded, perr = M.parse(text, source, path)
  if not loaded then return nil, perr end
  return loaded
end

local function type_ok(value, dtype)
  local t = type(value)
  if dtype == "any" then return true end
  if dtype == "string" then return t == "string" end
  if dtype == "number" then return t == "number" end
  if dtype == "integer" then return t == "number" and value == math.floor(value) end
  if dtype == "boolean" then return t == "boolean" end
  if dtype == "object" then return t == "table" and not util.is_array(value) end
  if dtype == "array" then return util.is_array(value) end
  return false
end

function M.resolve_args(loaded, provided)
  local decls = loaded.raw.args or {}
  local vars = {
    home = os.getenv("HOME") or "",
    user = os.getenv("USER") or "",
    cwd = os.getenv("PWD") or ".",
  }
  provided = provided or {}
  for name, raw_decl in pairs(decls) do
    local decl = raw_decl
    if type(decl) == "string" then decl = { type = decl } end
    if type(decl) ~= "table" then
      return nil, "bad declaration for arg '" .. tostring(name) .. "'"
    end
    local dtype = decl.type or "string"
    local optional = decl.optional == true
    if dtype:sub(-1) == "?" then optional = true; dtype = dtype:sub(1, -2) end
    if not VALID_TYPES[dtype] then
      return nil, "unknown type for arg '" .. tostring(name) .. "': " .. dtype
    end
    local value = provided[name]
    if value == nil then value = decl.default end
    if value ~= nil and not type_ok(value, dtype) then
      return nil, "arg '" .. tostring(name) .. "' expects " .. dtype .. ", got " .. type(value)
    end
    if value == nil and decl.required and not optional then
      return nil, "missing required arg '" .. tostring(name) .. "'"
    end
    if value ~= nil then vars[name] = value end
  end
  for k, v in pairs(provided) do
    if vars[k] == nil then vars[k] = v end
  end
  if vars.name == nil and loaded.raw.name then vars.name = loaded.raw.name end
  return util.interpolate(vars, vars)
end

local function node_of(n, at)
  if type(n) ~= "table" then return nil, at .. " must be a table" end

  -- Shorthand split: { "horizontal", 0.6, before, after }
  if type(n[1]) == "string" and (n[1] == "horizontal" or n[1] == "vertical") then
    local ratio = tonumber(n[2]) or 0.5
    if ratio <= 0 or ratio >= 1 then return nil, at .. ".ratio must be between 0 and 1" end
    local b, e1 = node_of(n[3], at .. ".before")
    if not b then return nil, e1 end
    local a, e2 = node_of(n[4], at .. ".after")
    if not a then return nil, e2 end
    return { kind = "split", direction = n[1], ratio = ratio, before = b, after = a }
  end

  -- IR style split
  if n.kind == "split" or (n.before and n.after) then
    local direction = n.direction or "horizontal"
    if direction ~= "horizontal" and direction ~= "vertical" then direction = "horizontal" end
    local ratio = tonumber(n.ratio) or 0.5
    if ratio <= 0 or ratio >= 1 then ratio = 0.5 end
    local b, e1 = node_of(n.before, at .. ".before")
    if not b then return nil, e1 end
    local a, e2 = node_of(n.after, at .. ".after")
    if not a then return nil, e2 end
    return { kind = "split", direction = direction, ratio = ratio, before = b, after = a }
  end

  local is_block = n.kind == "block" or type(n.block) == "string"
    or n.flavor or n.command or n.cwd
  if is_block then
    local name = n.block or n.name or n.label
    if type(name) ~= "string" then name = "block" end
    return {
      kind = "block",
      name = name,
      label = n.label,
      flavor = n.flavor or M.DEFAULT_FLAVOR,
      cwd = n.cwd,
      command = n.command and util.deepcopy(n.command) or nil,
      options = n.options and util.deepcopy(n.options) or nil,
      ready = n.ready and util.deepcopy(n.ready) or nil,
    }
  end

  return nil, at .. " is neither a block nor a split"
end

function M.normalize(loaded, vars)
  local raw = util.interpolate(loaded.raw, vars or {})
  local warnings = util.array({})
  local left = util.placeholders(raw)
  for _, k in ipairs(util.sorted_keys(left)) do
    warnings[#warnings + 1] = "Unresolved placeholder {{" .. k .. "}} was left as written."
  end

  local windows_raw = raw.windows
  if not windows_raw and raw.layout then
    windows_raw = { { label = "main", layout = raw.layout } }
  end
  if type(windows_raw) ~= "table" or #windows_raw == 0 then
    return nil, "spec needs at least one window"
  end

  local windows = util.array({})
  for i, w in ipairs(windows_raw) do
    local root, nerr = node_of(w.layout or w.root or w, "windows[" .. i .. "].layout")
    if not root then return nil, nerr end
    windows[#windows + 1] = {
      label = w.label or w.window_label or ("window-" .. i),
      root = root,
    }
  end

  local label = (raw.session and raw.session.label) or raw.name
    or (vars and vars.name) or "layout"
  return {
    version = 1,
    name = raw.name or "layout",
    session = { label = label },
    windows = windows,
    args_decl = util.deepcopy(loaded.raw.args or {}),
    vars = util.deepcopy(vars or {}),
    warnings = warnings,
    source = loaded.source,
    path = loaded.path,
  }
end

local function walk(n, fn)
  if not n then return end
  if n.kind == "split" then walk(n.before, fn); walk(n.after, fn)
  else fn(n) end
end
M.walk = walk

function M.blocks(ir)
  local out = util.array({})
  for i, w in ipairs(ir.windows or {}) do
    walk(w.root, function(b)
      b._window = i
      out[#out + 1] = b
    end)
  end
  return out
end

function M.check(ir)
  local warnings = util.deepcopy(ir.warnings or util.array({}))
  local blocks = M.blocks(ir)
  for _, b in ipairs(blocks) do
    if not b.command then
      warnings[#warnings + 1] = "Block '" .. b.name .. "' has no command. It will start an interactive shell."
    end
    if b.flavor ~= M.DEFAULT_FLAVOR then
      warnings[#warnings + 1] = "Block '" .. b.name .. "' uses flavor " .. tostring(b.flavor) .. ". Confirm this server provides it."
    end
  end
  return { windows = #ir.windows, blocks = #blocks, warnings = warnings }
end

local function short_node(n)
  if n.kind == "split" then
    return util.array({ n.direction, n.ratio, short_node(n.before), short_node(n.after) })
  end
  local out = { block = n.name }
  if n.label and n.label ~= n.name then out.label = n.label end
  if n.flavor and n.flavor ~= M.DEFAULT_FLAVOR then out.flavor = n.flavor end
  if n.cwd then out.cwd = n.cwd end
  if n.command then out.command = util.array(util.deepcopy(n.command)) end
  if n.options and next(n.options) ~= nil then out.options = util.deepcopy(n.options) end
  if n.ready then out.ready = util.deepcopy(n.ready) end
  return out
end

function M.document(ir)
  local out = {
    name = ir.name,
    session = { label = ir.session.label },
  }
  if ir.args_decl and next(ir.args_decl) ~= nil then
    out.args = util.deepcopy(ir.args_decl)
  end
  out.windows = util.array({})
  for _, w in ipairs(ir.windows or {}) do
    out.windows[#out.windows + 1] = { label = w.label, layout = short_node(w.root) }
  end
  return out
end

return M

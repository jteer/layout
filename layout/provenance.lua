-- layout/provenance.lua
-- Recipe store keyed by immutable session_id. The default path is derived
-- from this module's location, so server-side actions and local scripts
-- resolve to the same file without an env var.

local util = require("layout.util")
local json = require("layout.json")
local M = {}

local override = nil

-- .../layout/layout/provenance.lua -> .../layout
-- Rex reports source without the leading @ that stock Lua adds, so accept
-- both. Relative sources are resolved against PWD.
local function module_root()
  if not (type(debug) == "table" and type(debug.getinfo) == "function") then
    return nil
  end
  local info = debug.getinfo(1, "S")
  local src = info and info.source
  if type(src) ~= "string" then return nil end
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  local root = src:match("^(.*)/layout/provenance%.lua$")
  if not root then return nil end
  if root:sub(1, 1) == "/" then return root end
  local pwd = os.getenv("PWD") or os.getenv("HOME")
  if not pwd then return nil end
  if root == "." or root == "./" or root == "" then return pwd end
  return util.path(pwd, root)
end

function M.file()
  if override then return override end
  local explicit = os.getenv("LAYOUT_STAMPS")
  if explicit and explicit ~= "" then return explicit end
  local env_root = os.getenv("LAYOUT_ROOT")
  if env_root and env_root ~= "" then return util.path(env_root, "stamps.json") end
  local derived = module_root()
  if derived then return util.path(derived, "stamps.json") end
  return util.path(util.root(), "stamps.json")
end

-- Used by the test suite. Production reads LAYOUT_STAMPS, LAYOUT_ROOT or the
-- derived default.
function M.set_file(path)
  override = path
end

local function read_all()
  local text = util.read_file(M.file())
  if not text then return {} end
  local ok, data = pcall(json.decode, text)
  if not ok or type(data) ~= "table" then
    return {}, "stamp file is not valid JSON: " .. tostring(data)
  end
  return data
end

local function write_all(all)
  local path = M.file()
  local dir = path:match("^(.*)/[^/]+$")
  if dir and dir ~= "" then
    local ok, derr = util.ensure_dir(dir)
    if not ok then
      return nil, "cannot create stamp directory " .. dir .. ": " .. tostring(derr)
    end
  end
  local text = json.encode(all, { indent = true }) .. "\n"
  return util.write_file(path, text)
end

function M.get(session_id)
  if not session_id then return nil end
  local all = read_all()
  return all[session_id]
end

function M.put(session_id, stamp)
  if not session_id then return nil, "session_id is required" end
  local all, err = read_all()
  if err then return nil, err end
  all[session_id] = util.deepcopy(stamp)
  local ok, werr = write_all(all)
  if not ok then return nil, werr end
  return stamp
end

function M.all()
  return read_all()
end

function M.forget(session_id)
  local all, err = read_all()
  if err then return nil, err end
  all[session_id] = nil
  return write_all(all)
end

return M

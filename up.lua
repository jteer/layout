-- up.lua
-- Create a session from a Layoutfile and stamp it with the recipe.
-- Run with: rex do up.lua [spec=PATH] [project=...] [timeout=SECONDS]
--
-- This is a script, not a rex.action, because readiness waits and any future
-- long work belong outside the 30 second action limit.

local root = os.getenv("LAYOUT_ROOT") or (os.getenv("HOME") .. "/.config/rex/layout")
package.path = root .. "/?.lua;./?.lua;" .. package.path

local util = require("layout.util")
local spec = require("layout.spec")
local compile = require("layout.compile")
local provenance = require("layout.provenance")

local function fail(msg) error("[layout] " .. msg, 0) end

local args = (type(rex) == "table" and (rex.args or {})) or {}
if type(rex) ~= "table" or type(rex.call) ~= "function" then
  fail("up.lua must be run with `rex do`")
end

local path = spec.find(args.spec)
if not path then fail("no Layoutfile found; pass spec=PATH") end

local loaded, err = spec.load(path)
if not loaded then fail(err) end
local vars, verr = spec.resolve_args(loaded, args)
if not vars then fail(verr) end
local ir, nerr = spec.normalize(loaded, vars)
if not ir then fail(nerr) end
local summary = spec.check(ir)

local server = rex.call("server.version")
local windows = compile.windows(ir)

-- One atomic call. The server fires session_created only once every window is
-- ready, and creates no session at all if any window fails.
local res, cerr = rex.call("session.create", {
  label = ir.session.label,
  initial_windows = windows,
})
if res == nil then fail("session.create failed: " .. tostring(cerr)) end
local session_id = res.session_id
if not session_id then fail("session.create returned no session_id") end

-- session.create returns nested initial_windows, with block_ids in layout
-- order (before ahead of after), matching spec.blocks. Flatten them.
local window_ids = util.array({})
local block_ids = util.array({})
local revision = nil
for _, w in ipairs(res.initial_windows or {}) do
  if w.window_id then window_ids[#window_ids + 1] = w.window_id end
  for _, id in ipairs(w.block_ids or {}) do block_ids[#block_ids + 1] = id end
  if w.revision ~= nil then revision = w.revision end
end

-- session.create does not attach the connection, which rex.wait needs.
local attached = rex.call("session.attach", { session_id = session_id })
local warnings = util.deepcopy(summary.warnings)

local function record_matches(rec, gate)
  if type(rec) ~= "table" then return false end
  for k, v in pairs(gate) do
    if tostring(rec[k]) ~= tostring(v) then return false end
  end
  return true
end

-- A program can report its status before we attach and start waiting. Poll
-- the block's current records first so we do not miss an early match.
local function status_matches(block_id, gate)
  local res = rex.call("com.superlogical.terminal.program_status", {
    session_id = session_id,
    block_id = block_id,
    args = {},
  })
  if type(res) ~= "table" or type(res.records) ~= "table" then return false end
  for _, rec in ipairs(res.records) do
    if record_matches(rec, gate) then return true end
  end
  return false
end

local blocks = spec.blocks(ir)
local deadline = os.time() + (tonumber(args.timeout) or 30)
local status = "ready"
local unmet = util.array({})

if attached then
  for i, b in ipairs(blocks) do
    if b.ready then
      if not block_ids[i] then
        warnings[#warnings + 1] = "No block id for '" .. b.name .. "'. Readiness gate skipped."
      elseif status_matches(block_ids[i], b.ready) then
        -- Already satisfied before we started waiting.
      else
        local remaining = math.max(0, deadline - os.time())
        if remaining == 0 then
          status = "degraded"
          unmet[#unmet + 1] = b.name
        else
          local ev = rex.wait("terminal.program_status_changed", function(e)
            local rec = (type(e) == "table" and e.record) or e
            return record_matches(rec, b.ready)
          end, remaining)
          if ev == nil then
            status = "degraded"
            unmet[#unmet + 1] = b.name
          end
        end
      end
    end
  end
else
  warnings[#warnings + 1] = "Could not attach to the new session. Readiness gates were skipped."
end

local stamp = {
  version = 1,
  session_id = session_id,
  created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  spec_path = path,
  spec_source = loaded.source,
  spec = spec.document(ir),
  window_ids = window_ids,
  block_ids = block_ids,
  server = server,
  revision = revision,
}
local _, perr = provenance.put(session_id, stamp)
if perr then
  warnings[#warnings + 1] = "Could not write provenance stamp: " .. tostring(perr)
end

return {
  status = status,
  session_id = session_id,
  window_ids = window_ids,
  block_ids = block_ids,
  revision = revision,
  spec_path = path,
  unmet = unmet,
  warnings = warnings,
}

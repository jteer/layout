-- layout/actions.lua
-- Command palette entries loaded from init.lua.

local util = require("layout.util")
local ui = require("layout.ui")
local capture = require("layout.capture")
local provenance = require("layout.provenance")
local document = require("layout.document")
local session = require("layout.session")

local function current_session(args, ctx)
  local id = session.resolve(args.session or ctx.session_id or rex.session_id)
  if id then return id end
  local list = rex.call("session.list")
  if type(list) == "table" and type(list.sessions) == "table" and list.sessions[1] then
    return list.sessions[1].session_id
  end
  return nil
end

local function capture_run(ctx, args)
  args = args or {}
  ctx = ctx or {}
  local fmt, why = ui.format(args.format)
  if fmt == nil then return { cancelled = true, reason = why } end
  local scope, why2 = ui.scope(args.scope)
  if scope == nil then return { cancelled = true, reason = why2 } end
  local dest, why3 = ui.destination(args.path, fmt)
  if dest == nil then return { cancelled = true, reason = why3 } end

  local session_id = current_session(args, ctx)
  if not session_id then
    return { error = "no session found; pass session=ID" }
  end

  local view, err = session.view(session_id)
  if err ~= nil then error("[layout] session.view failed: " .. tostring(err), 0) end

  local stamp = provenance.get(session_id)
  local ir = capture.build(view, {
    scope = scope,
    ctx = { session_id = session_id, block_id = ctx.block_id or rex.block_id },
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
    if not ok then return { error = tostring(werr), spec = text, warnings = notes } end
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
end

local function status_run(ctx, args)
  ctx = ctx or {}
  args = args or {}
  local session_id = current_session(args, ctx)
  if not session_id then
    return { stamped = false, reason = "no session found; pass session=ID" }
  end
  local stamp = provenance.get(session_id)
  if not stamp then
    return { stamped = false, session_id = session_id,
             reason = "This session was not created by layout up." }
  end
  return {
    stamped = true,
    session_id = session_id,
    spec_path = stamp.spec_path,
    created_at = stamp.created_at,
    spec = stamp.spec,
  }
end

local M = { capture_run = capture_run, status_run = status_run }

-- Called once from init.lua, at server startup. Kept separate from the run
-- functions above so a script (capture.lua) can reuse capture_run via
-- `rex do` without re-registering the palette commands every run.
function M.register()
  rex.action{
    name = "layout_capture",
    title = "Layout: Save Session as Recipe...",
    description = "Write the current window or whole session to a Layoutfile.",
    category = "Layout",
    args = { format = "string?", scope = "string?", path = "string?",
             name = "string?", session = "string?" },
    run = capture_run,
  }

  rex.action{
    name = "layout_status",
    title = "Layout: Show Recipe",
    description = "Show the recipe stamped on this session at creation time.",
    category = "Layout",
    args = { session = "string?" },
    run = status_run,
  }
end

return M

-- layout/ui.lua
-- Prompts through rex.ui, with a headless path for CI and agents.
--
-- rex.ui only works inside an action's run function, so callers must be
-- actions. A missing app, an older server (prompts need control API revision
-- 17) or a cancelled prompt all have a defined outcome. "Running Without a
-- Person" from the Rex docs is the rule: every prompt is bypassable by an arg.

local util = require("layout.util")

local M = {}

local function log(level, msg)
  if type(rex) == "table" and type(rex.log) == "function" then
    rex.log(level, "[layout] " .. msg)
  else
    io.stderr:write("[layout] " .. msg .. "\n")
  end
end

local function prompts_available()
  return type(rex) == "table" and type(rex.ui) == "table"
     and type(rex.ui.pick) == "function"
end

local function finish(answer, why, default, label)
  if answer ~= nil then return answer end
  if why == "cancelled" then return nil, "cancelled" end
  log("warn", label .. " prompt unavailable (" .. tostring(why) .. "), using " .. tostring(default))
  return default
end

function M.pick(opts)
  if opts.provided ~= nil then return opts.provided end
  if not prompts_available() then
    log("warn", opts.title .. " prompt unavailable, using " .. tostring(opts.default))
    return opts.default
  end
  local answer, why = rex.ui.pick{
    title = opts.title,
    placeholder = opts.placeholder,
    items = opts.items,
    confirm = opts.confirm,
    timeout = opts.timeout or 120,
  }
  return finish(answer, why, opts.default, opts.title)
end

function M.input(opts)
  if opts.provided ~= nil then return opts.provided end
  if type(rex) ~= "table" or type(rex.ui) ~= "table"
     or type(rex.ui.input) ~= "function" then
    log("warn", opts.title .. " prompt unavailable, using " .. tostring(opts.default))
    return opts.default
  end
  local answer, why = rex.ui.input{
    title = opts.title,
    placeholder = opts.placeholder,
    value = opts.value,
    confirm = opts.confirm,
    timeout = opts.timeout or 120,
  }
  return finish(answer, why, opts.default, opts.title)
end

function M.format(provided)
  return M.pick{
    provided = provided,
    default = "lua",
    title = "Save recipe as",
    placeholder = "Choose a format",
    items = {
      { id = "lua",  title = "Lua", subtitle = "Layoutfile.lua", icon = "code" },
      { id = "json", title = "JSON / YAML", subtitle = "Layoutfile.json, valid YAML 1.2", icon = "document" },
    },
  }
end

function M.scope(provided)
  return M.pick{
    provided = provided,
    default = "window",
    title = "Capture scope",
    placeholder = "What to save",
    items = {
      { id = "window",  title = "Current window", subtitle = "The window holding the focused block", icon = "terminal" },
      { id = "session", title = "Whole session", subtitle = "Every window and its layout", icon = "server" },
    },
  }
end

-- Default to a captured filename so an unattended run never overwrites the
-- source Layoutfile in the working directory. Pass path=- to write nothing.
--
-- opts.base_dir, when given, anchors the default to a real directory (e.g.
-- the focused block's cwd) instead of wherever this process happens to run
-- from. opts is a table, not positional args, so a later way of picking a
-- destination (browsing with com.superlogical.terminal.list_dir, say) can
-- add its own key here without touching this signature or its callers.
function M.destination(provided, fmt, opts)
  opts = opts or {}
  local name = "Layoutfile.captured." .. (fmt == "json" and "json" or "lua")
  local default = opts.base_dir and util.path(opts.base_dir, name) or name
  return M.input{
    provided = provided,
    default = default,
    title = "Save recipe to",
    placeholder = "File path, or - to skip writing",
    value = default,
    confirm = "Save",
  }
end

return M

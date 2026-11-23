-- capture.lua
-- Save the current window, or the whole session, as a Layoutfile.
-- Run with: rex do capture.lua [scope=window|session] [format=lua|json] [path=FILE] [session=ID]
--
-- path=- writes nothing, so the recipe can be redirected from the CLI result:
--   rex do capture.lua path=- --json | jq -r .spec > Layoutfile.lua
--
-- Thin wrapper: the logic lives in layout.actions.capture_run, shared with
-- the layout_capture palette action.

local root = os.getenv("LAYOUT_ROOT") or (os.getenv("HOME") .. "/.config/rex/layout")
package.path = root .. "/?.lua;./?.lua;" .. package.path

local actions = require("layout.actions")

local args = (type(rex) == "table" and (rex.args or {})) or {}
if type(rex) ~= "table" or type(rex.call) ~= "function" then
  error("[layout] capture.lua must be run with `rex do`", 0)
end

return actions.capture_run({ block_id = rex.block_id }, args)

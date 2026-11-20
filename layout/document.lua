-- layout/document.lua
-- Render a captured or normalised IR back into a Layoutfile document.
-- JSON is valid YAML 1.2, so one encoder covers both.

local spec = require("layout.spec")
local json = require("layout.json")
local serial = require("layout.serial")
local M = {}

function M.render(ir, fmt, notes)
  notes = notes or {}
  local doc = spec.document(ir)
  if fmt == "json" then
    doc._layout = { generated_by = "layout", warnings = notes }
    return json.encode(doc, { indent = true }) .. "\n"
  end
  return serial.to_lua(doc, { header = notes })
end

return M

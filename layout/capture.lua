-- layout/capture.lua
-- Turn a live session.view snapshot back into a Layout document.
--
-- Shape of a session.view window:
--   view.windows[]           { window_id, label, layers[] }
--   window.layers[1]         the tiled layer: { layout, blocks[] }
--   layer.layout             { rect, block_id } or
--                            { rect, split: { direction, ratio, before, after } }
--   layer.blocks[]           { block_id, label, creator_name, flavor, ... }
--   view.active_window_id, view.label, view.revision, view.session_id
--
-- The creation shape { block = {...} } / { split = {...} } emitted by
-- compile.lua is accepted too, so the same adapter reads both.

local util = require("layout.util")
local spec = require("layout.spec")
local M = {}

local DEFAULT_FLAVOR = spec.DEFAULT_FLAVOR

-- A window in session.view keeps its layout and its block metadata in the
-- tiled layer, in two separate places. Build a lookup from block_id to the
-- metadata so leaf nodes can be enriched.
local function window_layout(win)
  local blocks_by_id = {}
  local layout = win.layout or win.root or win.layer
  local layers = (type(win.layers) == "table") and win.layers or {}
  for _, layer in ipairs(layers) do
    for _, b in ipairs(layer.blocks or {}) do
      if b.block_id then blocks_by_id[b.block_id] = b end
    end
    if not layout and (layer.kind == "tiled" or layer.layout) then
      layout = layer.layout or layer
    end
  end
  if not layout and layers[1] then layout = layers[1].layout or layers[1] end
  return layout, blocks_by_id
end

local function is_block(n)
  return type(n) == "table"
     and (n.block_id or n.flavor or type(n.block) == "table")
end

-- Both the creation shape and the session.view shape have splits, but the
-- latter nests direction/ratio/before/after under a "split" key.
local function split_info(n)
  local s = (type(n.split) == "table") and n.split or n
  local before = s.before or n.before or n.first
  local after = s.after or n.after or n.second
  local direction = s.direction or n.direction or "horizontal"
  local ratio = tonumber(s.ratio or n.ratio) or 0.5
  return before, after, direction, ratio
end

local function children(n)
  local out = {}
  local function add(v)
    if type(v) == "table" then
      if util.is_array(v) then
        for i = 1, #v do out[#out + 1] = v[i] end
      else
        out[#out + 1] = v
      end
    end
  end
  for _, key in ipairs({ "before", "after", "first", "second", "layout",
                         "root", "blocks", "children", "layers", "split" }) do
    add(n[key])
  end
  for i = 1, #n do add(n[i]) end
  return out
end

local function block_method(method, block_id, session_id)
  if not (block_id and type(rex) == "table" and type(rex.call) == "function") then
    return nil
  end
  -- Block methods require session_id. The CLI adds it through -s; in Lua we
  -- have to pass it ourselves.
  local args = { args = {}, block_id = block_id }
  if session_id then args.session_id = session_id end
  local res = rex.call("com.superlogical.terminal." .. method, args)
  if res == nil then return nil end
  return res
end

local function clean_pwd(v)
  if type(v) == "table" then v = v.pwd or v.url or v.cwd or v.path end
  if type(v) ~= "string" then return nil end
  -- OSC 7 reports file://host/path. Drop the scheme AND the host, keep /path.
  return (v:gsub("^file://[^/]*", ""))
end

-- Exposed so callers (layout.actions) can default a save destination to
-- where the user is actually looking, instead of wherever this process
-- happens to run from. nil if the block has no recoverable cwd.
function M.block_cwd(session_id, block_id)
  return clean_pwd(block_method("pwd", block_id, session_id))
end

local function block_node(n, opts, warnings, meta)
  meta = meta or {}
  local b = (type(n.block) == "table") and n.block or n
  local block_id = b.block_id or n.block_id
  local options = b.options or n.options or {}
  if type(options) ~= "table" then options = {} end

  local label = b.label or meta.label or n.label or b.window_label
  local cwd = b.cwd or options.cwd
  local command = b.command or options.command
  local flavor = b.flavor or meta.flavor or n.flavor

  if not cwd then cwd = clean_pwd(block_method("pwd", block_id, opts.session_id)) end

  local name = label
  if not name and block_id then
    name = tostring(block_id):match("([%w%-]+)$") or "block"
  end
  name = name or "block"

  if not command then
    warnings[#warnings + 1] = "Block '" .. name .. "' has no recoverable command. Saved as an interactive shell."
  end

  local extra = util.deepcopy(options)
  extra.command = nil
  extra.cwd = nil

  return {
    kind = "block",
    name = name,
    label = label,
    flavor = flavor or DEFAULT_FLAVOR,
    cwd = cwd,
    command = command and util.deepcopy(command) or nil,
    options = next(extra) ~= nil and extra or nil,
    ready = nil,
    block_id = block_id,
  }
end

local function to_node(n, opts, warnings, depth, blocks_by_id)
  if type(n) ~= "table" or depth > 32 then return nil end

  if is_block(n) then
    local meta = (n.block_id and blocks_by_id[n.block_id]) or nil
    return block_node(n, opts, warnings, meta)
  end

  local before, after, direction, ratio = split_info(n)
  if before and after then
    if direction ~= "horizontal" and direction ~= "vertical" then direction = "horizontal" end
    if ratio <= 0 or ratio >= 1 then ratio = 0.5 end
    local bn = to_node(before, opts, warnings, depth + 1, blocks_by_id)
    local an = to_node(after, opts, warnings, depth + 1, blocks_by_id)
    if bn and an then
      return { kind = "split", direction = direction, ratio = ratio, before = bn, after = an }
    end
    return bn or an
  end

  local kids = children(n)
  if #kids == 0 then return nil end
  local nodes = {}
  for _, k in ipairs(kids) do
    local node = to_node(k, opts, warnings, depth + 1, blocks_by_id)
    if node then nodes[#nodes + 1] = node end
  end
  if #nodes == 0 then return nil end
  if #nodes > 1 then
    warnings[#warnings + 1] = "A layout node had an unrecognised shape. Its children were stacked vertically."
  end
  local out = nodes[#nodes]
  for i = #nodes - 1, 1, -1 do
    out = { kind = "split", direction = "vertical", ratio = 0.5,
            before = nodes[i], after = out }
  end
  return out
end

local function contains_block(n, block_id, depth)
  if type(n) ~= "table" or depth > 32 then return false end
  if n.block_id == block_id then return true end
  if type(n.block) == "table" and n.block.block_id == block_id then return true end
  for _, child in ipairs(children(n)) do
    if contains_block(child, block_id, depth + 1) then return true end
  end
  return false
end

-- ctx has no window_id in Rex. Find the window holding ctx.block_id, then
-- fall back to the active window, then the first.
function M.window_index(view, ctx)
  local windows = (type(view) == "table" and view.windows) or {}
  ctx = ctx or {}
  for i, win in ipairs(windows) do
    local id = win.window_id or win.id
    if ctx.window_id and id == ctx.window_id then return i end
    if ctx.block_id then
      local layout = window_layout(win)
      if layout and contains_block(layout, ctx.block_id, 0) then return i end
    end
  end
  if type(view) == "table" and view.active_window_id then
    for i, win in ipairs(windows) do
      if (win.window_id or win.id) == view.active_window_id then return i end
    end
  end
  return 1
end

function M.build(view, opts)
  opts = opts or {}
  local warnings = util.array({})
  if type(view) ~= "table" then
    warnings[#warnings + 1] = "session.view returned no view."
    return { version = 1, name = "captured", session = { label = "captured" },
             windows = util.array({}), warnings = warnings, source = "captured" }
  end

  local windows = view.windows or util.array({})
  local picked
  if opts.scope == "window" then
    picked = { windows[M.window_index(view, opts.ctx)] }
  else
    picked = windows
  end

  local out_windows = util.array({})
  for _, win in ipairs(picked) do
    if type(win) == "table" then
      local layout, blocks_by_id = window_layout(win)
      local node = to_node(layout, opts, warnings, 0, blocks_by_id)
      if node then
        out_windows[#out_windows + 1] = {
          label = win.label or win.window_label or ("window-" .. (#out_windows + 1)),
          root = node,
        }
      end
    end
  end
  if #out_windows == 0 then
    warnings[#warnings + 1] = "No windows could be read from session.view."
  end

  return {
    version = 1,
    name = opts.name or view.label or "captured",
    session = { label = view.label or opts.name or "captured" },
    windows = out_windows,
    warnings = warnings,
    source = "captured",
  }
end

-- The stamp stores a document (windows[].layout, shorthand nodes), while
-- capture.build returns an IR (windows[].root, kind="block"/"split" nodes).
-- Walk both shapes so drift compares like with like.
local function collect_labels(node, prefix, out)
  if type(node) ~= "table" then return end
  if node.kind == "split" then
    collect_labels(node.before, prefix, out)
    collect_labels(node.after, prefix, out)
    return
  end
  if type(node[1]) == "string" and (node[1] == "horizontal" or node[1] == "vertical") then
    collect_labels(node[3], prefix, out)
    collect_labels(node[4], prefix, out)
    return
  end
  if type(node.split) == "table" then
    collect_labels(node.split.before, prefix, out)
    collect_labels(node.split.after, prefix, out)
    return
  end
  if node.before and node.after then
    collect_labels(node.before, prefix, out)
    collect_labels(node.after, prefix, out)
    return
  end
  out[#out + 1] = prefix .. "/" .. tostring(node.name or node.block or node.label or "?")
end

local function block_labels(windows)
  local out = {}
  for _, w in ipairs(windows or {}) do
    collect_labels(w.root or w.layout or w, w.label or "?", out)
  end
  table.sort(out)
  return out
end

-- Informational only. Layout does not reconcile or enforce drift.
function M.drift(ir, stamp)
  local notes = util.array({})
  if not (type(stamp) == "table" and type(stamp.spec) == "table") then
    notes[#notes + 1] = "No recipe is stamped for this session. Output is a best effort structural snapshot."
    return notes
  end

  local before = block_labels(stamp.spec.windows)
  local after = block_labels(ir.windows)
  if #before ~= #after then
    notes[#notes + 1] = "Recipe has " .. #before .. " blocks, live session has " .. #after .. "."
  end
  local i, j = 1, 1
  while i <= #before and j <= #after do
    if before[i] == after[j] then i = i + 1; j = j + 1
    elseif before[i] < after[j] then
      notes[#notes + 1] = "Removed since the recipe: " .. before[i]; i = i + 1
    else
      notes[#notes + 1] = "Added since the recipe: " .. after[j]; j = j + 1
    end
  end
  while i <= #before do
    notes[#notes + 1] = "Removed since the recipe: " .. before[i]; i = i + 1
  end
  while j <= #after do
    notes[#notes + 1] = "Added since the recipe: " .. after[j]; j = j + 1
  end
  if #notes == 0 then notes[#notes + 1] = "Live layout matches the stamped recipe." end
  return notes
end

return M

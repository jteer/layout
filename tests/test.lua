-- tests/test.lua
-- Run from the project root: luajit tests/test.lua
-- A fake rex global stands in for the server; no Rex instance is needed.

package.path = "./?.lua;" .. package.path

local util = require("layout.util")
local json = require("layout.json")
local serial = require("layout.serial")
local spec = require("layout.spec")
local compile = require("layout.compile")
local capture = require("layout.capture")
local provenance = require("layout.provenance")
local document = require("layout.document")
local session = require("layout.session")

local passed, failed = 0, 0
local function ok(cond, label)
  if cond then passed = passed + 1
  else failed = failed + 1; io.stderr:write("FAIL: " .. label .. "\n") end
end
local function eq(a, b, label)
  ok(a == b, label .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end
local function deep_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deep_equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- Set below. The attach response has to return the same view.
local fake_view = {}

local calls = {}
rex = {
  args = {},
  action = function(_) end,
  session = {},
  layout = {
    horizontal = function(ratio, before, after)
      return { kind = "split", direction = "horizontal", ratio = ratio,
               before = before, after = after }
    end,
    vertical = function(ratio, before, after)
      return { kind = "split", direction = "vertical", ratio = ratio,
               before = before, after = after }
    end,
    block = function(t)
      return { kind = "block", flavor = t.flavor, options = t.options, label = t.label }
    end,
  },
  call = function(method, args)
    calls[#calls + 1] = { method = method, args = args }
    if method == "com.superlogical.terminal.pwd" then
      return { pwd = "file://localhost/tmp/work", owner = { pid = 1, name = "zsh" } }
    elseif method == "com.superlogical.terminal.program_status" then
      return { records = util.array({}) }
    elseif method == "server.version" then
      return { rex_version = "0.1.0-preview.21" }
    elseif method == "session.list" then
      return { sessions = util.array({
        { session_id = "session:test", label = "alpha" },
        { session_id = "session:other", label = "beta" },
      }) }
    elseif method == "session.create" then
      return {
        session_id = "session:test",
        initial_windows = util.array({
          { window_id = "window:1",
            block_ids = util.array({ "block:1", "block:2", "block:3" }), revision = 1 },
          { window_id = "window:2",
            block_ids = util.array({ "block:4" }), revision = 2 },
        }),
      }
    elseif method == "session.attach" then
      return { client_id = "client:test", view = fake_view }
    end
    return nil, "not available"
  end,
  wait = function(event, filter, timeout)
    return { record = { app = "vite", state = "idle" } }
  end,
}

-- 1. util
eq(util.path("/home/user", ".config", "rex", "layout"),
   "/home/user/.config/rex/layout", "path keeps absolute prefix")
eq(util.path("a/", "/b/", "c"), "a/b/c", "path cleans slashes")
ok(util.is_array(util.array({})), "empty marked array is an array")
ok(util.is_array({ 1, 2, 3 }), "numeric table is an array")
ok(not util.is_array({ a = 1 }), "map is not an array")
ok(not util.is_array({}), "plain empty table is an object")
eq(util.interpolate("{{a}}/{{b}}", { a = "x", b = "y" }), "x/y", "interpolate")
local ph = util.placeholders("{{z}} and {{a}}")
ok(ph.z and ph.a and not ph.b, "placeholders found")

-- 2. json
local original = util.array({
  {
    name = "a \"quoted\"\nline",
    ratio = 0.6,
    count = 42,
    yes = true,
    no = false,
    empty = util.array({}),
    nested = { x = 1, y = util.array({ "p", "q" }) },
  },
})
local decoded = json.decode(json.encode(original))
ok(deep_equal(original, decoded), "json round trip")
eq(json.decode('{"s":"caf\\u00e9"}').s, "caf\195\169", "json unicode escape")
eq(json.encode({ x = json.null }), '{"x":null}', "json null")
ok(not pcall(json.decode, "{} {}"), "json rejects trailing content")
ok(json.decode(json.encode({ a = 1 }, { indent = true })).a == 1, "indented json")

-- 3. serial
local lua_text = serial.to_lua(original, { header = { "a note", "another note" } })
ok(lua_text:find("^%-%- a note"), "serial header comment")
local reloaded = loadstring(lua_text)()
ok(deep_equal(original, reloaded), "lua source round trip")

-- 4. spec
local path = spec.find("Layoutfile.lua")
ok(path ~= nil, "find example Layoutfile")
local loaded, lerr = spec.load(path)
ok(loaded ~= nil, "load example Layoutfile: " .. tostring(lerr))
eq(loaded.source, "lua", "example source is lua")

local vars, verr = spec.resolve_args(loaded, { project = "webapp" })
ok(vars ~= nil, "resolve args: " .. tostring(verr))
eq(vars.branch, "main", "default arg applied")
ok(vars.root:match("/src/webapp$") ~= nil, "nested default interpolated: " .. tostring(vars.root))

local ir, nerr = spec.normalize(loaded, vars)
ok(ir ~= nil, "normalize: " .. tostring(nerr))
eq(#ir.windows, 2, "window count")
eq(#spec.blocks(ir), 4, "block count")
eq(ir.session.label, "webapp", "session label interpolated")
local summary = spec.check(ir)
eq(summary.blocks, 4, "check block count")
ok(#summary.warnings >= 1, "check warns about commandless block")

local _, missing = spec.resolve_args(loaded, {})
ok(missing ~= nil and missing:find("project") ~= nil, "required arg enforced")
local _, badtype = spec.resolve_args(loaded, { project = 123 })
ok(badtype ~= nil and badtype:find("expects string") ~= nil, "arg type enforced")

-- 5. document round trip
local doc = spec.document(ir)
eq(doc.windows[1].layout[1], "horizontal", "document uses shorthand split")
eq(doc.windows[1].layout[2], 0.6, "document preserves ratio")
local rendered_lua = document.render(ir, "lua", { "note one" })
local loaded2 = spec.parse(rendered_lua, "lua", "roundtrip.lua")
local vars2 = spec.resolve_args(loaded2, { project = "webapp" })
local ir2 = spec.normalize(loaded2, vars2)
eq(#ir2.windows, 2, "document round trip windows")
eq(#spec.blocks(ir2), 4, "document round trip blocks")
local rendered_json = document.render(ir, "json", { "note one" })
local as_json = json.decode(rendered_json)
eq(as_json._layout.warnings[1], "note one", "json document carries warnings")

-- 6. layout compilation
local wins = compile.windows(ir)
eq(#wins, 2, "compiled window count")
eq(wins[1].window_label, "main", "window_label forwarded")
eq(wins[1].layout.kind, "split", "root split compiled")
eq(wins[1].layout.ratio, 0.6, "ratio forwarded")
eq(wins[1].layout.before.options.command[1], "nvim", "block command compiled")
ok(wins[1].layout.before.options.cwd:match("/src/webapp$") ~= nil, "cwd compiled")
eq(wins[2].layout.kind, "block", "single block window compiled")

-- 7. provenance
local stamp_file = "./.layout-test-stamps.json"
os.remove(stamp_file)
provenance.set_file(stamp_file)
local put, perr = provenance.put("session:abc", {
  spec_path = "Layoutfile.lua",
  spec = { windows = util.array({}) },
})
ok(put ~= nil, "stamp written: " .. tostring(perr))
eq(provenance.get("session:abc").spec_path, "Layoutfile.lua", "stamp read back")
eq(provenance.all()["session:abc"].spec_path, "Layoutfile.lua", "stamp listed")
provenance.forget("session:abc")
ok(provenance.get("session:abc") == nil, "stamp forgotten")
os.remove(stamp_file)

-- First stamp write must create its directory tree.
local nested = "./.layout-test-nested/deeper"
os.execute('rm -rf ./.layout-test-nested')
local made, merr = util.ensure_dir(nested)
ok(made, "ensure_dir creates nested directories: " .. tostring(merr))
provenance.set_file(nested .. "/stamps.json")
local stamped, serr = provenance.put("session:nested", { spec_path = "Layoutfile.lua" })
ok(stamped ~= nil, "stamp written into a newly created directory: " .. tostring(serr))
provenance.set_file(stamp_file)
os.remove(nested .. "/stamps.json")
os.execute('rm -rf ./.layout-test-nested')

-- 8. session target resolution
eq(session.resolve("beta"), "session:other", "label resolves to full id")
eq(session.resolve("BETA"), "session:other", "label match is case insensitive")
eq(session.resolve("session:abc"), "session:abc", "full id passes through")
eq(session.resolve("2"), "session:other", "position resolves")
eq(session.resolve("other"), "session:other", "short id suffix resolves")
eq(session.resolve(nil), nil, "nil stays nil")

-- 9. capture against the real session.view shape
local view = {
  session_id = "session:test",
  label = "webapp",
  revision = 7,
  active_window_id = "window:2",
  windows = {
    {
      window_id = "window:1",
      label = "main",
      layers = {
        {
          layer_id = "layer:1",
          kind = "tiled",
          bounds = { 0, 0, 1, 1 },
          layout = {
            rect = { 0, 0, 1, 1 },
            split = {
              split_id = "split:1",
              direction = "horizontal",
              ratio = 0.6,
              before = { rect = { 0, 0, 0.6, 1 }, block_id = "block:1" },
              after = {
                rect = { 0.6, 0, 0.4, 1 },
                split = {
                  split_id = "split:2",
                  direction = "vertical",
                  ratio = 0.5,
                  before = { rect = { 0.6, 0, 0.4, 0.5 }, block_id = "block:2" },
                  after = { rect = { 0.6, 0.5, 0.4, 0.5 }, block_id = "block:3" },
                },
              },
            },
          },
          blocks = {
            { block_id = "block:1", label = "editor",
              creator_name = "com.superlogical.terminal",
              flavor = "com.superlogical.terminal.shell" },
            { block_id = "block:2", label = "server",
              creator_name = "com.superlogical.terminal",
              flavor = "com.superlogical.terminal.shell" },
            { block_id = "block:3", label = "logs",
              creator_name = "com.superlogical.terminal",
              flavor = "com.superlogical.terminal.shell" },
          },
        },
      },
    },
    {
      window_id = "window:2",
      label = "ops",
      layers = {
        {
          layer_id = "layer:2",
          kind = "tiled",
          bounds = { 0, 0, 1, 1 },
          layout = { rect = { 0, 0, 1, 1 }, block_id = "block:4" },
          blocks = {
            { block_id = "block:4", label = "shell",
              creator_name = "com.superlogical.terminal",
              flavor = "com.superlogical.terminal.shell" },
          },
        },
      },
    },
  },
}
fake_view = view

eq(capture.window_index(view, { block_id = "block:3" }), 1,
   "current window found by block id through nested splits")
eq(capture.window_index(view, {}), 2, "active window fallback")

local captured = capture.build(view, {
  scope = "session", ctx = {}, session_id = "session:test",
})
eq(#captured.windows, 2, "captured window count")
eq(#spec.blocks(captured), 4, "captured block count")
eq(captured.windows[1].root.direction, "horizontal", "capture reads split.direction")
eq(captured.windows[1].root.ratio, 0.6, "capture reads split.ratio")
eq(captured.windows[1].root.after.direction, "vertical", "capture reads nested split.direction")
eq(captured.windows[1].root.after.ratio, 0.5, "capture reads nested split.ratio")

local cap_blocks = spec.blocks(captured)
eq(cap_blocks[1].name, "editor", "capture reads label from layer.blocks")
eq(cap_blocks[1].flavor, "com.superlogical.terminal.shell", "capture reads flavor from layer.blocks")
eq(cap_blocks[1].cwd, "/tmp/work", "capture strips file:// host from pwd")
local warn_text = table.concat(captured.warnings, "\n")
ok(warn_text:find("no recoverable command") ~= nil, "capture warns about lost commands")

local one_window = capture.build(view, {
  scope = "window", ctx = { block_id = "block:2" }, session_id = "session:test",
})
eq(#one_window.windows, 1, "window scope selects one window")
eq(#spec.blocks(one_window), 3, "window scope block count")

local cap_lua = document.render(captured, "lua", capture.drift(captured, nil))
local cap_loaded = spec.parse(cap_lua, "lua", "captured.lua")
local cap_vars = spec.resolve_args(cap_loaded, {})
local cap_ir = spec.normalize(cap_loaded, cap_vars)
eq(#spec.blocks(cap_ir), 4, "captured document is loadable")

local drift = capture.drift(captured, {
  spec = { windows = { { label = "main", root = { kind = "block", name = "editor" } } } },
})
ok(table.concat(drift, "\n"):find("blocks") ~= nil, "drift reports block count change")
ok(capture.drift(captured, nil)[1]:find("No recipe") ~= nil, "drift reports missing stamp")

local drift_doc = capture.drift(captured, {
  spec = { windows = util.array({ { label = "main", layout = { block = "editor" } } }) },
})
ok(table.concat(drift_doc, "\n"):find("Recipe has 1 blocks") ~= nil,
   "drift counts blocks in a document shaped stamp")

local drift_match = capture.drift(captured, {
  spec = { windows = util.array({
    { label = "main", layout = { "horizontal", 0.6,
        { block = "editor" },
        { "vertical", 0.5, { block = "server" }, { block = "logs" } } } },
    { label = "ops", layout = { block = "shell" } },
  }) },
})
ok(table.concat(drift_match, "\n"):find("matches the stamped recipe") ~= nil,
   "matching document stamp reports no drift")

-- A stamp built by up.lua, not a hand-built IR.
local real_stamp = { spec = spec.document(ir), spec_path = "Layoutfile.lua" }
local drift_real = capture.drift(captured, real_stamp)
ok(table.concat(drift_real, "\n"):find("matches the stamped recipe") ~= nil,
   "drift reads a stamp produced by spec.document")

-- 10. end to end smoke tests for the entry scripts, against the fake server
rex.session = { view = function(_) return fake_view end }
rex.session_id = "session:test"
rex.block_id = "block:3"

rex.args = { project = "webapp", spec = "Layoutfile.lua" }
local up_result = dofile("up.lua")
eq(up_result.status, "ready", "up.lua reaches ready")
eq(up_result.session_id, "session:test", "up.lua returns session id")
eq(#up_result.block_ids, 4, "up.lua flattens initial_windows block ids")
eq(#up_result.window_ids, 2, "up.lua flattens window ids")
eq(up_result.revision, 2, "up.lua reads revision from initial_windows")
ok(provenance.get("session:test") ~= nil, "up.lua stamps provenance")
eq(#provenance.get("session:test").block_ids, 4, "stamp stores flattened block ids")
eq(provenance.get("session:test").spec_path:match("Layoutfile%.lua$") ~= nil, true,
   "stamp records the source Layoutfile")

rex.args = { format = "json", scope = "session", path = "-" }
local cap_result = dofile("capture.lua")
eq(cap_result.windows, 2, "capture.lua reads both windows")
ok(cap_result.spec:find("_layout") ~= nil, "capture.lua emits json document")
eq(cap_result.path, nil, "path=- writes no file")

rex.args = { session = "session:test" }
local status_result = dofile("status.lua")
eq(status_result.stamped, true, "status.lua finds the stamp")
eq(status_result.spec_path:match("Layoutfile%.lua$") ~= nil, true,
   "status.lua reports the recipe path")
ok(table.concat(status_result.drift, "\n"):find("matches the stamped recipe") ~= nil,
   "status.lua reports no drift immediately after up.lua")

-- 11. palette actions resolve a session without -s
local actions = require("layout.actions")
rex.session_id = nil
local action_result = actions.capture_run({}, {
  format = "json", scope = "session", path = "-",
})
eq(action_result.session_id, "session:test", "layout_capture resolves the first session")
ok(action_result.spec ~= nil, "layout_capture returns a document")
rex.session_id = "session:test"

os.remove(stamp_file)
io.write("layout tests: " .. passed .. " passed, " .. failed .. " failed\n")
os.exit(failed == 0 and 0 or 1)

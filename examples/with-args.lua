-- Arg declarations: required, optional (shorthand "type?"), typed, defaulted,
-- and a default that interpolates another arg.
-- Run with: rex do up.lua spec=examples/with-args.lua project=demo
-- Or try it without "project" to see the required-arg error:
--   rex do check.lua spec=examples/with-args.lua
return {
  name = "with-args",
  args = {
    project = { type = "string", required = true },
    branch  = "string?",
    count   = { type = "integer", default = 1 },
    root    = { type = "string", default = "{{home}}/src/{{project}}" },
  },
  session = { label = "{{project}}" },
  windows = {
    { label = "main", layout = { block = "shell", cwd = "{{root}}" } },
  },
}

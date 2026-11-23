-- The smallest useful Layoutfile: one window, one block, no args.
-- Run with: rex do up.lua spec=examples/minimal.lua
return {
  name = "minimal",
  windows = {
    { label = "main", layout = { block = "shell" } },
  },
}

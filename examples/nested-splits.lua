-- A 2x2 grid: splits nested two levels deep, no args or commands, just shape.
-- Run with: rex do up.lua spec=examples/nested-splits.lua
--
-- ┌─────────────┬─────────────┐
-- │  top-left   │  top-right  │
-- ├─────────────┼─────────────┤
-- │ bottom-left │ bottom-right│
-- └─────────────┴─────────────┘
return {
  name = "grid",
  windows = {
    {
      label = "main",
      layout = { "horizontal", 0.5,
        { "vertical", 0.5,
          { block = "top-left",    label = "top-left" },
          { block = "bottom-left", label = "bottom-left" },
        },
        { "vertical", 0.5,
          { block = "top-right",    label = "top-right" },
          { block = "bottom-right", label = "bottom-right" },
        },
      },
    },
  },
}

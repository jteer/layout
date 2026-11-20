-- Layoutfile.lua
-- An example recipe. Copy it, edit it, keep it in your repo.
--
-- {{name}} placeholders are filled from args. Built in vars: home, user, cwd.
-- A split is { "horizontal"|"vertical", ratio, before, after } where ratio is
-- the fraction of space given to the first child. Blocks can be nested.

return {
  name = "webapp",

  args = {
    project = { type = "string", required = true },
    branch  = { type = "string", default = "main" },
    root    = { type = "string", default = "{{home}}/src/{{project}}" },
  },

  session = { label = "{{project}}" },

  windows = {
    {
      label = "main",
      layout = { "horizontal", 0.6,
        {
          block = "editor",
          label = "editor",
          cwd = "{{root}}",
          command = { "nvim", "." },
        },
        { "vertical", 0.5,
          {
            block = "server",
            label = "server",
            cwd = "{{root}}",
            command = { "npm", "run", "dev" },
            ready = { app = "vite", state = "idle" },
          },
          {
            block = "logs",
            label = "logs",
            cwd = "{{root}}",
            command = { "tail", "-f", "dev.log" },
          },
        },
      },
    },
    {
      label = "ops",
      layout = { block = "shell", label = "shell", cwd = "{{root}}" },
    },
  },
}

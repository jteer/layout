# Layout

> A live session is authoritative while the spec is provenance.

Layout is a small tool for [Rex](https://www.superlogical.com/rex/docs/). It writes down how a session was made, and uses that recipe when the session has to be created again. It does not reconcile, enforce, or continuously manage anything. A recipe matters only when the session doesn't exist yet, doesn't exist anymore, or doesn't exist on this server.

Rex ensures that when a second client attaching to an existing session needs no work from Layout at all. Layout only matters when there is no session to attach to: first creation, a different server, a session that was lost, or a CI job and an agent starting from nothing.

## What it does

- **`up.lua`** reads a `Layoutfile.lua`, builds the whole layout in one atomic `session.create` call, waits on optional readiness gates, and stamps the recipe into `stamps.json` keyed by the immutable `session_id`.
- **`capture.lua`** reads `session.view` and writes the current window or the whole session back out as a `Layoutfile.lua` or `Layoutfile.json`. JSON output is valid YAML 1.2.
- **`layout_capture`** and **`layout_status`** are command palette actions, with a keybinding, so saving a recipe is one keypress. `layout_capture` uses `rex.ui.pick` as a small Save As menu and `rex.ui.input` for the path.
- **`check.lua`** validates a Layoutfile and changes nothing. It runs under plain Lua with no Rex server.
- **`status.lua`** reports whether the current session has a stamped recipe and describes drift. Drift is informational only.

## Install

### Option A: default location, no configuration

```sh
cp -r /path/to/layout ~/.config/rex/layout
cat ~/.config/rex/layout/init.lua.snippet >> ~/.config/rex/init.lua
rex config check
rex config reload      # on the machine running the Rex server
```

`~/.config/rex/layout` is what `LAYOUT_ROOT`, `spec.find()` and the stamp store default to. `init.lua.snippet` derives its path from `HOME`, so nothing needs editing. `rex config reload` is refused over a remote connection, so run it on the server host.

### Option B: keep this repo in place

Two processes read the project, they do not share an environment.

1. The server side. `~/.config/rex/init.lua` is read by the already-running Rex server, which was launched outside your shell and never sees your shell profile. Edit `layout_dir` in the snippet to the absolute path of this repo. A shell-exported `LAYOUT_ROOT` has no effect here.
2. The CLI side. `rex do up.lua` and the other scripts run locally in your shell. Run them from the project root, where `./?.lua` resolves the modules. If you invoke them from another directory, export `LAYOUT_ROOT` in your shell profile:

```sh
export LAYOUT_ROOT=/absolute/path/to/layout
```

Rex injects `REX_BIN_DIR` at the front of `PATH` in terminals it opens, so `rex` is normally available there. In a shell that Rex did not open, check with `command -v rex` or set `REX` to the binary's absolute path.

```sh
REX="$(command -v rex)"
"$REX" whoami --json
```

Environment variables:

| Variable | Meaning |
| --- | --- |
| `LAYOUT_ROOT` | Directory containing the `layout/` modules, used by the CLI scripts for `package.path`. Defaults to this project's own directory, derived at runtime. |
| `LAYOUT_STAMPS` | Exact path of the recipe store. Overrides everything else. |
| `LAYOUT_ARGS` | JSON args for plain Lua runs of `check.lua`. |

The stamp file defaults to `<project>/stamps.json`, derived from `layout/provenance.lua`'s own location, so the palette actions inside the server and the scripts in your shell resolve to the same file. `LAYOUT_ROOT` is not a stamp setting. The directory is created on the first stamp write.

## Usage

```sh
# validate a Layoutfile, no changes (works with plain lua too)
rex do check.lua project=webapp

# create the session and stamp the recipe
rex do up.lua project=webapp

# save the current window as a Layoutfile
rex do capture.lua scope=window format=lua path=Layoutfile.lua

# save the whole session as JSON (valid YAML), no file written
rex do capture.lua scope=session format=json path=- --json | jq -r .spec > Layoutfile.json

# headless, for CI and agents: no prompts are shown
rex do up.lua spec=/path/to/Layoutfile.lua project=webapp timeout=60

# inspect the stamped recipe and drift
rex do status.lua
```

Every prompt is bypassable by an argument. `format`, `scope`, `path` and `name` are all optional. If no connected app can show a prompt, Layout logs a warning, uses the default, and carries on. Prompts need control API revision 17.

The palette action is the same operation:

```sh
rex do layout_capture scope=window format=lua path=Layoutfile.lua
```

`path=-` writes nothing and returns the recipe text in the result, so a `rex do` script (which runs locally where the CLI is) can redirect it to your laptop. Actions defined in `init.lua` run on the server, so a file written from the palette lands on the server host. Keep that distinction in mind for remote servers.

Outside a Rex terminal there is no `REX_SESSION`, so `capture.lua`, `status.lua` and the palette actions fall back to the first session on the server. `session=` accepts a full ID, a label, a 1 based position or a short ID suffix. The connection is attached before reading the view, which the API requires.

## Layoutfile format

A Layoutfile is a Lua table, or a JSON object for data-only specs that you do not want to execute.

```lua
return {
  name = "webapp",
  args = {
    project = { type = "string", required = true },
    root    = { type = "string", default = "{{home}}/src/{{project}}" },
  },
  session = { label = "{{project}}" },
  windows = {
    { label = "main", layout = { "horizontal", 0.6,
        { block = "editor", cwd = "{{root}}", command = { "nvim", "." } },
        { "vertical", 0.5,
          { block = "server", cwd = "{{root}}", command = { "npm", "run", "dev" },
            ready = { app = "vite", state = "idle" } },
          { block = "logs", cwd = "{{root}}", command = { "tail", "-f", "dev.log" } },
        },
      },
    },
  },
}
```

- A split is `{ "horizontal"|"vertical", ratio, before, after }`. `ratio` is the fraction of space given to the first child, between 0 and 1.
- A block has `block` (a name), plus optional `label`, `flavor`, `cwd`, `command`, `options` and `ready`.
- `{{name}}` placeholders are filled from declared args and the built in vars `home`, `user`, `cwd`. Defaults can reference other vars.
- `ready` gates wait on `terminal.program_status_changed` instead of sleeping. `up.lua` first polls `com.superlogical.terminal.program_status` so an early status report is not missed. A gate that never matches produces `status = "degraded"` with the block names, rather than hanging.
- Lua Layoutfiles run in a restricted environment with no access to the `rex` global. For untrusted templates, use JSON, which is data only.

Arg types are `string`, `number`, `integer`, `boolean`, `object`, `array`, `any`. A trailing `?` marks an arg optional.

## How capture works

`capture` walks `session.view`. A window keeps its layout in the tiled layer, as a tree of leaf nodes (`{ rect, block_id }`) and split nodes (`{ rect, split: { direction, ratio, before, after } }`). Block labels, flavors and creators live in a separate `blocks[]` array on that same layer, so capture joins them by `block_id`. It also reads each block's working directory through `com.superlogical.terminal.pwd`, which reports `file://host/path` and needs an explicit `session_id` in Lua. Drift against the stamped recipe is written into the output as warnings.

**Rex does not expose the command a block was started with. (yet?) ** `session.view` describes structure, not content, and there is no documented method that returns the launch command. So a captured Layoutfile preserves layout, labels, cwd and flavor, but saves any block whose command cannot be recovered as an interactive shell and says so in a warning. That is exactly why `up.lua` stamps the real recipe at creation. Capture reads the stamp when one exists. Otherwise it produces a best effort, honestly degraded document.

All of the shape handling is confined to `layout/capture.lua`.

## Compatibility

Verified against Rex `0.1.0-preview.21` (api revision 18)


## Tests

```sh
cd /path/to/layout
luajit tests/test.lua
```

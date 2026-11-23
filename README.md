<p align="center">
  <img src="assets/icon.svg" alt="Layout icon" width="112" height="112">
</p>

<h1 align="center">Layout</h1>

<p align="center">Save a Rex session's layout. Rebuild it when there's nothing to attach to.</p>

Layout is a small tool for [Rex](https://www.superlogical.com/rex/docs/). It saves a recipe for how a session was put together (panes, commands, working directories) and replays it when the session has to be built again. Once the session exists, Layout is done. There's no daemon and no drift correction; `status.lua` just tells you what changed.

Most of the time you don't need it. If the session is already there, Rex attaches the second client and Layout does nothing. The recipe only matters when there's nothing to attach to: the first run, a different server, a session that got lost, or a CI job where an agent starts from scratch.

## What it does

Say you keep a `Layoutfile.lua` in your repo (there's a full one below). It describes a `webapp` window with an editor beside a dev server and a log tail. One command builds it:

```sh
rex do up.lua project=webapp
```

What you get:

```text
┌───────────────┬─────────────────┐
│               │ npm run dev     │
│    nvim .     ├─────────────────┤
│               │ tail -f dev.log │
└───────────────┴─────────────────┘
```

The `server` block in that file has a readiness gate:

```lua
ready = { app = "vite", state = "idle" }
```

`npm run dev` starts Vite, the dev server. That line tells Layout to wait until Vite reports `idle` (started up, not busy) before it says it's done. It listens for that status event from Rex's terminal instead of sleeping for a guess. Then it saves the recipe against the new session, so you can see later what it was built from.

Next day you're on a different machine with no `webapp` session, or the old one got lost and a CI job is starting from scratch. Same command:

```sh
rex do up.lua project=webapp
```

There's nothing to attach to, so Layout builds the same window again from the same file. If a session does exist, Rex attaches you to it and Layout does nothing.

Rearrange the panes by hand and `rex do status.lua` will show you what changed. It won't put them back. To keep the new arrangement instead, save it:

```sh
rex do capture.lua scope=window format=lua path=Layoutfile.lua
```

Rex won't tell capture what command started each block, so those come back as plain shells with a warning. That's why the recipe saved at creation is worth having.

## Install

### Option A: default location, no configuration

```sh
cp -r /path/to/layout ~/.config/rex/layout
cat ~/.config/rex/layout/init.lua.snippet >> ~/.config/rex/init.lua
rex config check
rex config reload      # on the machine running the Rex server
```

`~/.config/rex/layout` is the default for `LAYOUT_ROOT`, `spec.find()` and the stamp store. The snippet works out its own path from `HOME`, so there's nothing to edit. One catch: `rex config reload` is refused over a remote connection, so run it on the machine hosting the Rex server.

### Option B: keep this repo in place

There are two processes here and they don't share an environment, which is the part that trips people up.

1. **The server.** `~/.config/rex/init.lua` is read by the Rex server that's already running. It was started outside your shell, so it never sees your shell profile. Set `layout_dir` in the snippet to the absolute path of this repo. Exporting `LAYOUT_ROOT` in your shell won't reach it.
2. **The CLI.** `rex do up.lua` and the other scripts run in your shell. Run them from the project root, where `./?.lua` finds the modules. From anywhere else, export `LAYOUT_ROOT` in your shell profile:

```sh
export LAYOUT_ROOT=/absolute/path/to/layout
```

Terminals opened by Rex have `REX_BIN_DIR` at the front of `PATH`, so `rex` is there. In a shell Rex didn't open, check `command -v rex`; set `REX` to the binary's absolute path if that comes up empty.

```sh
REX="$(command -v rex)"
"$REX" whoami --json
```

Environment variables:

| Variable | Meaning |
| --- | --- |
| `LAYOUT_ROOT` | Where the `layout/` modules live. The CLI scripts use it for `package.path`; by default it's this project's own directory, worked out at runtime. |
| `LAYOUT_STAMPS` | Exact path of the recipe store. Overrides everything else. |
| `LAYOUT_ARGS` | JSON args for plain Lua runs of `check.lua`. |

The stamp file defaults to `<project>/stamps.json`, worked out from `layout/provenance.lua`'s own location. That's deliberate: the palette action inside the server and the scripts in your shell land on the same file without any configuration. `LAYOUT_ROOT` has nothing to do with stamps. The directory gets created on the first write.

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

Every prompt can be skipped by passing the argument instead. `format`, `scope`, `path` and `name` are all optional. If there's no app around to show a prompt, Layout warns and uses the default. Prompts need control API revision 17.

The same thing is in the command palette as `layout_capture`, with `layout_status` for the drift report. Both have a keybinding, so it's one keypress inside Rex:

```sh
rex do layout_capture scope=window format=lua path=Layoutfile.lua
```

`path=-` writes no file. It returns the recipe text in the result, so a `rex do` script (running locally, where the CLI is) can redirect it to your laptop. Actions from `init.lua` run on the server, though, so a file saved from the palette lands on the server's disk. On a remote server that difference matters.

Outside a Rex terminal there's no `REX_SESSION`, so `capture.lua`, `status.lua` and the palette actions fall back to the first session on the server. You can point them somewhere else with `session=`: a full ID, a label, a 1-based position, or a short ID suffix. The API won't let you read the view until the connection is attached, so capture does that first.

## Layoutfile format

A Layoutfile is a Lua table. If you don't want a spec to execute, write it as a JSON object instead; that's just data.

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

- A split is `{ "horizontal"|"vertical", ratio, before, after }`. `ratio` (0 to 1) is how much space the first child gets.
- A block needs a `block` name. The rest is optional: `label`, `flavor`, `cwd`, `command`, `options`, `ready`.
- `{{name}}` placeholders come from your args plus the built-ins `home`, `user` and `cwd`. Defaults can refer to other vars.
- `ready` gates wait on `terminal.program_status_changed` rather than sleeping. `up.lua` polls `com.superlogical.terminal.program_status` first so it doesn't miss a status that fired early. A gate that never matches gives you `status = "degraded"` with the block names instead of hanging.
- Lua Layoutfiles run in a sandbox without the `rex` global. For templates you don't trust, stick to JSON.

Arg types are `string`, `number`, `integer`, `boolean`, `object`, `array`, `any`. A trailing `?` makes an arg optional.

More Layoutfiles, each showing one piece in isolation (a minimal spec, nested splits, arg handling, the JSON form), are in [`examples/`](examples/).

## How capture works

`capture` walks `session.view`. A window's layout lives in the tiled layer as a tree of leaf nodes (`{ rect, block_id }`) and split nodes (`{ rect, split: { direction, ratio, before, after } }`). Labels, flavors and creators sit in a separate `blocks[]` array on that same layer, so capture joins them back by `block_id`. Working directories come from `com.superlogical.terminal.pwd`, which reports `file://host/path` and needs an explicit `session_id` in Lua. Any drift from the stamped recipe goes into the output as warnings.

**Rex doesn't expose the command a block was started with.** (Yet, anyway; there's no documented call for it.) `session.view` describes structure, not content, so a captured Layoutfile keeps the layout, labels, cwd and flavor but turns any block with an unrecoverable command into a plain interactive shell, and says so in a warning. That's exactly why `up.lua` stamps the real recipe at creation: capture reads it back when there is one. Without a stamp you get a best-effort, honestly degraded document.

All that shape wrangling lives in `layout/capture.lua`.

## Compatibility

Tested against Rex `0.1.0-preview.21` (api revision 18).

## Tests

```sh
cd /path/to/layout
luajit tests/test.lua
```

`tests/test.lua` exercises every module against a fake `rex` global, no server needed. For a check against a real server, `tests/integration.sh` creates a disposable session, drives it through the scripts and the `layout_capture`/`layout_status` actions, and tears it down:

```sh
cd /path/to/layout
tests/integration.sh
```

It needs `rex` connected to a server with the actions registered (see above) and `jq`.

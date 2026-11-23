# Examples

Each file is a standalone Layoutfile, runnable from the project root. The root [`Layoutfile.lua`](../Layoutfile.lua) is the full-featured one referenced in the main README; these show individual pieces in isolation.

| File | Shows |
| --- | --- |
| [`minimal.lua`](minimal.lua) | The smallest useful spec: one window, one block, no args. |
| [`nested-splits.lua`](nested-splits.lua) | A 2x2 grid, splits nested two levels deep. |
| [`with-args.lua`](with-args.lua) | Required, optional (shorthand `"type?"`), typed, and interpolated-default args. |
| [`json-recipe.json`](json-recipe.json) | The same format as plain data, for templates you don't want to execute. |

Validate one without creating anything:

```sh
rex do check.lua spec=examples/minimal.lua
```

Build it for real:

```sh
rex do up.lua spec=examples/nested-splits.lua
rex do up.lua spec=examples/with-args.lua project=demo
```

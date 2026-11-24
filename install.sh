#!/usr/bin/env bash
# Installs this repo to ~/.config/rex/layout (or $LAYOUT_ROOT) and wires it
# into ~/.config/rex/init.lua. Safe to re-run: the snippet is only added once.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${LAYOUT_ROOT:-$HOME/.config/rex/layout}"
INIT_LUA="$HOME/.config/rex/init.lua"
MARKER='require("layout.actions")'

mkdir -p "$(dirname "$DEST_DIR")"
rm -rf "$DEST_DIR"
cp -r "$SRC_DIR" "$DEST_DIR"

touch "$INIT_LUA"
if ! grep -qF "$MARKER" "$INIT_LUA"; then
  cp "$INIT_LUA" "$INIT_LUA.bak"
  cat <<EOF >> "$INIT_LUA"

-- layout (added by install.sh)
package.path = "$DEST_DIR/?.lua;" .. package.path
$MARKER.register()
EOF
  if [ -n "${LAYOUT_KEYBIND:-}" ]; then
    echo "rex.bind(\"$LAYOUT_KEYBIND\", \"layout_capture\")" >> "$INIT_LUA"
  fi
  echo "Added Layout to $INIT_LUA (backup at $INIT_LUA.bak)"
else
  echo "Layout already wired into $INIT_LUA, skipping"
fi

rex config check
echo "Run 'rex config reload' on the machine hosting the Rex server to finish."

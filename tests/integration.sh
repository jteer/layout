#!/usr/bin/env bash
# tests/integration.sh
# End-to-end check against a REAL rex server. tests/test.lua exercises every
# module with a fake rex global; this instead creates a disposable session
# on whatever server `rex` is connected to, drives it through up.lua /
# capture.lua / status.lua (client-side scripts) and layout_capture /
# layout_status (server-side actions, registered via init.lua.snippet),
# and checks that script and action agree. Then it tears everything down.
#
# Needs: a running rex server with the layout actions registered, and jq.
# Run from the project root: tests/integration.sh

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v rex >/dev/null || { echo "rex CLI not found" >&2; exit 1; }
rex whoami >/dev/null 2>&1 || { echo "no rex server reachable" >&2; exit 1; }

WORK=$(mktemp -d)
SID=""

# stamps.json is the real, derived-default provenance file (see
# layout/provenance.lua): both the scripts below and the server-side
# actions read and write it with no env var involved, so the test has to
# leave it exactly as it found it.
STAMPS="stamps.json"
STAMPS_BACKUP=""
if [ -f "$STAMPS" ]; then
  STAMPS_BACKUP="$WORK/stamps.json.bak"
  cp "$STAMPS" "$STAMPS_BACKUP"
fi

cleanup() {
  [ -n "$SID" ] && rex kill "$SID" >/dev/null 2>&1
  if [ -n "$STAMPS_BACKUP" ]; then
    cp "$STAMPS_BACKUP" "$STAMPS"
  else
    rm -f "$STAMPS"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Two harmless long-running blocks so the session survives the test; no
# `ready` gates, so up.lua returns immediately instead of waiting on one.
FIXTURE="$WORK/Layoutfile.lua"
cat >"$FIXTURE" <<'LUA'
return {
  name = "layout-integration-test",
  session = { label = "layout-integration-test" },
  windows = {
    {
      label = "main",
      layout = { "horizontal", 0.5,
        { block = "left",  label = "left",  command = { "sleep", "60" } },
        { block = "right", label = "right", command = { "sleep", "60" } },
      },
    },
  },
}
LUA

echo "== up.lua: create a real session from the fixture =="
UP=$(rex do up.lua spec="$FIXTURE" --json)
echo "$UP" | jq -e '.status == "ready"' >/dev/null && ok || fail "up.lua reached ready"
echo "$UP" | jq -e '.block_ids | length == 2' >/dev/null && ok || fail "up.lua created 2 blocks"
SID=$(echo "$UP" | jq -r '.session_id')
if [ -z "$SID" ] || [ "$SID" = "null" ]; then
  fail "up.lua returned a session_id"
  echo "integration: $PASS passed, $FAIL failed"
  exit 1
fi
ok

echo "== the session actually exists on the server =="
rex session list --json | jq -e --arg id "$SID" \
  '.sessions | map(.session_id) | index($id) != null' >/dev/null \
  && ok || fail "session appears in session.list"

echo "== status.lua (client-side script): fresh session has no drift =="
STATUS=$(rex do status.lua session="$SID" --json)
echo "$STATUS" | jq -e '.stamped == true' >/dev/null && ok || fail "status.lua sees the stamp"
echo "$STATUS" | jq -e '.drift | join(" ") | test("matches the stamped recipe")' >/dev/null \
  && ok || fail "status.lua reports no drift"

echo "== layout_status (server-side action): agrees with status.lua =="
# This is the check that would have caught the actions.lua regression: the
# action runs inside the server process, with the server's own environment,
# not this shell's. If it can't find the stamp up.lua just wrote, the
# client/server stamp path agreement is broken.
ACTION_STATUS=$(rex do layout_status session="$SID" --json)
echo "$ACTION_STATUS" | jq -e '.stamped == true' >/dev/null \
  && ok || fail "layout_status action sees the stamp up.lua wrote"
echo "$ACTION_STATUS" | jq -e --argjson want "$(echo "$STATUS" | jq '.spec_path')" \
  '.spec_path == $want' >/dev/null \
  && ok || fail "layout_status action and status.lua agree on spec_path"

echo "== capture.lua (client-side script): round-trips the live session =="
CAPTURED=$(rex do capture.lua session="$SID" scope=session format=json path=- --json)
echo "$CAPTURED" | jq -e '.windows == 1' >/dev/null && ok || fail "capture.lua read 1 window"
echo "$CAPTURED" | jq -e '.spec | fromjson | .windows[0].layout[0] == "horizontal"' >/dev/null \
  && ok || fail "capture.lua's document preserves the horizontal split"

echo "== layout_capture (server-side action): same capture through the registered action =="
ACTION_CAPTURE=$(rex do layout_capture session="$SID" scope=session format=json path=- --json)
echo "$ACTION_CAPTURE" | jq -e '.windows == 1' >/dev/null \
  && ok || fail "layout_capture action read 1 window"

echo "integration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

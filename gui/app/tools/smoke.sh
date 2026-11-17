#!/bin/sh
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
smoke_dir=$(mktemp -d /tmp/knobby-gui-smoke.XXXXXX)
cd "$repo_dir"
nim c -o:gui/app/dist/knobby_gui gui/app/src/knobby_gui.nim
nim c -o:gui/app/dist/test_lifecycle gui/app/tools/test_lifecycle.nim
nim c -o:gui/app/dist/check_rendering gui/app/tools/check_rendering.nim
Xvfb -displayfd 3 -screen 0 1920x1200x24 -nolisten tcp 3>"$smoke_dir/display" >"$smoke_dir/xvfb.log" 2>&1 &
xvfb_pid=$!
trap 'kill "$xvfb_pid" 2>/dev/null || true' EXIT HUP INT TERM
attempt=0
while [ ! -s "$smoke_dir/display" ]; do
  if ! kill -0 "$xvfb_pid" 2>/dev/null; then
    cat "$smoke_dir/xvfb.log"
    exit 1
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -gt 100 ]; then
    exit 1
  fi
  sleep 0.1
done
mkdir -m 700 "$smoke_dir/runtime"
XDG_RUNTIME_DIR="$smoke_dir/runtime" DISPLAY=":$(cat "$smoke_dir/display")" LIBGL_ALWAYS_SOFTWARE=1 KNOBBY_GUI_SMOKE=1 \
  dbus-run-session --config-file="${DBUS_SESSION_CONF:-/etc/dbus-1/session.conf}" -- gui/app/dist/knobby_gui --smoke "$smoke_dir"
gui/app/dist/check_rendering "$smoke_dir"
XDG_RUNTIME_DIR="$smoke_dir/runtime" DISPLAY=":$(cat "$smoke_dir/display")" LIBGL_ALWAYS_SOFTWARE=1 KNOBBY_GUI_SMOKE=1 \
  dbus-run-session --config-file="${DBUS_SESSION_CONF:-/etc/dbus-1/session.conf}" -- sh -c 'openbox --sm-disable >"$1/openbox.log" 2>&1 & wm_pid=$!; trap '\''kill "$wm_pid" 2>/dev/null || true'\'' EXIT; sleep 1; gui/app/dist/test_lifecycle gui/app/dist/knobby_gui' sh "$smoke_dir"
printf 'Screenshots: %s\n' "$smoke_dir"

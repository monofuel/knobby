#!/bin/sh
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
smoke_dir=$(mktemp -d /tmp/knobby-editor-smoke.XXXXXX)
cd "$repo_dir"
nim c -o:gui/app/dist/knobby_gui gui/app/src/knobby_gui.nim
nim c -o:gui/app/dist/test_button_editor gui/app/tools/test_button_editor.nim
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
dbus_config=${DBUS_SESSION_CONF:-}
if [ -z "$dbus_config" ]; then
  for candidate in /usr/share/dbus-1/session.conf /etc/dbus-1/session.conf; do
    if [ -r "$candidate" ]; then
      dbus_config=$candidate
      break
    fi
  done
fi
XDG_RUNTIME_DIR="$smoke_dir/runtime" DISPLAY=":$(cat "$smoke_dir/display")" LIBGL_ALWAYS_SOFTWARE=1 KNOBBY_GUI_SMOKE=1 \
  dbus-run-session --config-file="$dbus_config" -- \
  gui/app/dist/test_button_editor gui/app/dist/knobby_gui "$smoke_dir/editor"
printf 'Editor screenshots: %s/editor/edit and %s/editor/recover\n' "$smoke_dir" "$smoke_dir"

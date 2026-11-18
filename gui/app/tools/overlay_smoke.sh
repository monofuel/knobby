#!/bin/sh
# Verify the help overlay on a private Xvfb display, Openbox, and D-Bus session.
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
smoke_dir=$(mktemp -d /tmp/knobby-overlay-smoke.XXXXXX)
cd "$repo_dir"
if [ -z "${DBUS_SESSION_CONF:-}" ]; then
  for candidate in /usr/share/dbus-1/session.conf /etc/dbus-1/session.conf; do
    if [ -r "$candidate" ]; then DBUS_SESSION_CONF="$candidate"; break; fi
  done
fi
if [ ! -r "${DBUS_SESSION_CONF:-}" ]; then
  echo 'Set DBUS_SESSION_CONF to a readable D-Bus session configuration.' >&2
  exit 1
fi
nim c -o:gui/app/dist/knobby_overlay gui/app/src/knobby_overlay.nim
nim c -o:gui/app/dist/test_overlay gui/app/tools/test_overlay.nim
Xvfb -displayfd 3 -screen 0 3200x1200x24 -nolisten tcp 3>"$smoke_dir/display" >"$smoke_dir/xvfb.log" 2>&1 &
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
for name in runtime config state; do mkdir -m 700 "$smoke_dir/$name"; done
export DISPLAY=":$(cat "$smoke_dir/display")" LIBGL_ALWAYS_SOFTWARE=1 KNOBBY_GUI_SMOKE=1 \
  XDG_RUNTIME_DIR="$smoke_dir/runtime" XDG_CONFIG_HOME="$smoke_dir/config" XDG_STATE_HOME="$smoke_dir/state"
gui/app/dist/knobby_overlay --smoke "$smoke_dir"
dbus-run-session --config-file="$DBUS_SESSION_CONF" -- sh -c '
  openbox --sm-disable >"$1/openbox.log" 2>&1 &
  wm_pid=$!
  trap '\''kill "$wm_pid" 2>/dev/null || true'\'' EXIT
  sleep 1
  gui/app/dist/test_overlay gui/app/dist/knobby_overlay "$1"' sh "$smoke_dir"
printf 'Overlay screenshots: %s\n' "$smoke_dir"

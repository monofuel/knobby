# Knobby tray viewer

Knobby has two independent user services. The daemon owns the mixer, Stream
Deck, lighting, actions, and audio observations. The GUI displays that state
and edits buttons through daemon transactions. It can close or quit without
affecting physical controls. See [buttons.md](buttons.md) for menus, artwork,
draft recovery, and the shared GUI/CLI configuration workflow.

## Install or update

From this checkout:

```sh
nix develop --command nim r tools/install.nim
```

The installer builds the pinned Nix package, runs hardware-free and isolated
GUI checks, then switches `~/.local/share/knobby/current` to the verified build.
A failed build leaves the installed version unchanged. The compiled binaries
include their runtime wrappers; service startup needs neither the compiler
nor the source checkout. New code takes effect after rebuilding and installing.

The repository copies of both service units remain the source of truth. The
installer copies them to the user unit directory, enables graphical-login
startup, and restarts the daemon. It neither launches nor restarts the desktop
GUI. For a new editor or IPC version, choose **Quit viewer** from the tray and
run `~/.local/bin/knobby-gui`; saved configurations and drafts are retained.

Before migrating from the standalone Stream Deck demo, stop that demo with
Ctrl+C. The daemon now owns the same numbered page at 30% brightness and its
press/release images. Demos and probes reject a second display owner; stop
the daemon explicitly when running those diagnostics.

## Open and close

Run `~/.local/bin/knobby-gui`, or open Knobby from the desktop applications
menu. The launcher activates the existing viewer. If it is absent, the
launcher starts `knobby-gui.service`, waits for readiness, then activates it.
Concurrent launches reuse a single process and window.

The GUI starts hidden at graphical login, including when the tray host has
not started yet. Closing the window hides it. Tray activation or **Open
Knobby** restores and focuses it. **Quit viewer** exits only the GUI and stays
stopped until another launch or graphical login. Missing tray hosts never
cause an unsolicited window; the normal launcher remains available.

On high-steel the current graphical session is Openbox/X11. The GUI service
inherits the systemd user manager's display and Xauthority environment. It
is tied to `graphical-session.target`, not a root service at the login screen.

```sh
systemctl --user status knobby knobby-gui
journalctl --user -u knobby -u knobby-gui -f
```

Restarting the daemon does not restart or close the GUI. The viewer reconnects
and receives a complete state snapshot. It retains last-known fader positions
while the device or daemon is disconnected, with connection status shown
separately.

## Unplugging and reconnecting

Knobby keeps running when a device is unplugged. The mixer and Stream Deck
are rediscovered automatically, including when their ALSA port or hidraw node
changes. Reconnecting the Deck restores its active menu and artwork. Mixer
connection changes clear held buttons while retaining last-known fader positions;
they do not apply those positions to audio. Mousepad lighting is reapplied after
a new USB attachment or OpenRazer restart, including quick unplug/replug cycles.
MIDI failures retry locally without restarting the other device workers.

The GUI is independent of these reconnect loops. A missing USB device must first
return in Linux's device listings; charging-only hubs provide no USB data
connection for Knobby to discover. Lifecycle messages appear in the daemon's
journal, with repeated identical failures suppressed.

The daemon remembers MIDI positions in `$XDG_STATE_HOME/knobby/faders.json`
(normally `~/.local/state/knobby/faders.json`). A separate worker saves changed
positions at most once every two seconds and flushes remaining changes on clean
shutdown. The cache is replaced atomically; an unreadable or invalid cache does
not prevent controls from working. Restored positions are for display only and
never change audio volume or populate action state. Abrupt termination can lose
the latest unsaved readings.

## Read-only views

- **Mixer:** physical button order, held buttons, short-tap feedback, and last
  MIDI fader positions. `MIDI N` means observed in the current connection;
  `Last known N` means remembered from an earlier connection or daemon run.
  `Not observed` means no position is known. Each fader becomes freshly observed
  when its next MIDI event arrives. The daemon captures inputs before action
  execution; actual audio volume is a separate observation.
- **Audio:** actual default-output volume and individual matching application
  stream levels, independently of fader positions. The microphone control
  lists real input sources and mute state. Discord's binding is shown; its
  RPC mute state is not queried by the viewer.
- **Stream Deck:** the daemon's numbered page and live input state. The GUI
  never opens hidraw or changes the display.
- **Mousepad:** physical presence and the intended OpenRazer preset. Actual
  RGB values are not queried. Lighting failures are independent of MIDI.

Selecting controls in the live browser only inspects them. The button editor
uses explicit Save & Apply transactions; it never fires an action by selecting
a tile. The local configuration API does not expose an execute-button command.

## Local interfaces

The daemon publishes versioned, length-framed JSON through
`$XDG_RUNTIME_DIR/knobby/daemon.sock`. A subscriber gets a complete snapshot,
updates at up to 20 Hz, and a one-second heartbeat. Freshness uses the client's
monotonic receive time. Slow clients have bounded buffers and are disconnected
rather than blocking input handling.

Window activation uses a separate endpoint,
`$XDG_RUNTIME_DIR/knobby-gui/activate.sock`. Activation acknowledgement follows
showing, restoring, raising, and focusing the existing window. Each service
owns its own runtime directory and process lock.

## Development

The daemon remains standard-library-only Nim. The GUI uses the pinned Windy,
Silky, and related packages in an isolated development workspace:

```sh
cd gui
nimby create
cd app
nimby sync nimby.lock
cd ../..
nix develop
```

Use Nimby 0.2.3 or newer. Normal users do not need this workspace setup; the
Nix package obtains pinned source archives directly. After deliberately changing
`gui/app/nimby.lock`, refresh the archive hashes with
`nim r tools/pin_nix_dependencies.nim` and review both lock files.

Run `nimble test` for hardware-free checks. `nix build .#knobby` runs those
checks and the GUI checks inside the package build. To run the isolated GUI
checks directly:

```sh
nix develop --command sh gui/app/tools/smoke.sh
nix develop --command sh gui/app/tools/editor_smoke.sh
nix develop --command nim r gui/app/tools/test_button_media.nim
```

These use private Xvfb/Openbox and D-Bus sessions. They verify rendering,
selection, resize, hidden startup, concurrent activation, focus, hiding, clean
quit, and restart without opening a desktop window. Text stays at its native
pixel size while panels and wrapping adjust to window size. Rendering checks
compare GPU glyph coverage against the font atlas and require unchanged text
pixels across default, small, odd-sized, and large windows; inspect the saved
images for visual quality too. Live state can be checked
without a GUI using:

```sh
nix develop --command nim r gui/app/tools/check_observers.nim
```

Regenerate the embedded atlas with
`nim r gui/app/tools/generate_assets.nim`. The DejaVu Sans font and license
are included. The atlas contains fractional-position glyph variants so Silky
can retain fractional advances and kerning without stretching glyph bitmaps.
Interactive tray and real hardware checks happen when the user launches the
viewer.

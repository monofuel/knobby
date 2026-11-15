# Knobby

Knobby puts Linux audio on physical faders. An Arduino MIDI mixer controls
master, browser, music, and game volume without opening a volume panel or
leaving the app you're using. Its buttons launch apps and toggle microphone
or Discord mute.

It runs in the background, reconnects when the controller is unplugged, and
keeps app volumes at their fader levels when new audio streams appear.
With OpenRazer installed, it also gives the
[Goliathus mousepad](docs/goliathus-chroma.md) a subtle grey breathing effect.

## Scope

This is monofuel's personal setup for `high-steel`, a NixOS desktop using
PipeWire's PulseAudio compatibility layer. Bindings and desktop paths are
hardcoded intentionally; there is no configuration system.

The [controller](docs/hardware.md) has four faders and twelve buttons.
See the [desktop setup](docs/high-steel.md) for bindings and Discord
authorization. Adapting Knobby to another desktop means editing the bindings
in [actions.nim](src/knobby/actions.nim) and the service paths.

## Try it

From the checkout, enter the Nix development shell and run the tests:

```sh
nix develop
nimble test
```

The shell supplies Nim and the command-line tools Knobby needs. Without Nix,
use Nim 2.0 or newer, Nimble, `alsa-utils`, `pactl`, `wmctrl`, `curl`, and
`pgrep` (from `procps`). Mousepad lighting also uses `busctl` (from `systemd`)
and the OpenRazer driver and user daemon; MIDI and audio work without OpenRazer.
Knobby uses only Nim's standard library. Tests need neither the controller
nor a running audio server.

To watch the controller's events without changing volumes or launching apps:

```sh
nim r examples/midi_monitor.nim
```

Stop the monitor with Ctrl+C. Once the desktop bindings match your setup, run
the daemon:

```sh
nim r src/knobby.nim
```

To inspect the available MIDI ports or active audio streams:

```sh
nim r examples/midi_monitor.nim -- --list
nim r examples/audio_outputs.nim
```

## Background service

On high-steel, install the checked-in [systemd user service](docs/knobby.service):

```sh
mkdir -p ~/.config/systemd/user
cp docs/knobby.service ~/.config/systemd/user/knobby.service
systemctl --user daemon-reload
systemctl --user enable --now knobby
```

The service compiles the daemon on startup. After code changes, restart it
with `systemctl --user restart knobby`. View logs with
`journalctl --user -u knobby -f`. Edit the repository's service file and copy
it again when changing the service.

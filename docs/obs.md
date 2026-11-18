# Minecraft recordings with OBS

The `Minecraft AI Demos` profile and scene collection are separate from the
existing `Untitled` setup. The single `Minecraft` scene captures the Minecraft
X11 window, game audio, and an optional `Commentary` microphone. It has no
desktop capture, webcam, title card, or end card.

The recording preset is 1920×1080 at 60 fps, AMD VAAPI H.264 with CQP 20,
AAC audio, and MKV recording with OBS automatic MP4 remux. Files go to
`~/Videos/Minecraft-AI/`. Track 1 combines game and commentary, track 2 is
game audio, and track 3 is commentary. Commentary starts muted. Its button
affects OBS only; the hardware microphone mute and listening volumes stay
independent.

The `wayfolk` Prism instance has a per-instance environment override:
`PULSE_PROP_OVERRIDE_application.name=knobby-minecraft`. Minecraft otherwise
identifies its audio as `.java-wrapped`, which would capture unrelated Java
programs too. Knobby verifies the labeled streams against the actual Minecraft
window's PID and clears the capture target if verification fails. It never
selects a generic Java target. New instances need the same label and a restart;
only one labeled instance should run at a time. Processes newly launched by
Minecraft inherit its environment, so avoid opening external apps from in-game
links during recording. An already-running browser is unaffected.

## Stream Deck

Main-menu key 2 opens the OBS submenu on the Deck. Entering the menu does
not launch OBS or start recording. The Arduino keeps its current menu.

| Key | Action |
| --- | --- |
| 1 | Back to the parent menu |
| 2 | Start/stop recording |
| 3 | Pause/resume recording |
| 4 | Mute/unmute OBS Commentary |
| 5 | Open/focus OBS and select the Minecraft project when idle |
| 6 | Launch Prism if Minecraft is closed; otherwise resize Minecraft to 1920×1080 |

Recording, pause, and mic artwork follows actual OBS events and periodic
queries. Grey unavailable artwork means the connection or required workspace
is unavailable. Commands are never retried after an uncertain result, and
reconnecting never starts a recording. Stop/pause remain available for an
existing recording if Minecraft closes. Open OBS never switches projects
while recording or streaming.

The **OBS** key keeps its application icon: a grey frame when closed and a
green frame when OBS is running. App presence is observed independently of
the WebSocket connection, so an open OBS with unavailable controls can be
explained in the GUI. The Record key keeps its **REC** artwork when capture is
unavailable, with a grey frame; its details explain the missing prerequisite.
Opening OBS alone does not make Minecraft capture ready.

The Minecraft key shows **PRISM** while the game is absent. Pressing it opens
`~/bin/prism` without choosing an instance or modpack. Once a Minecraft game
window appears it shows amber **1080**, or green **1080** when its content is
already exactly 1920×1080. These observations continue while OBS is closed.

The 1080p action identifies Minecraft by its X11 window class, removes
fullscreen/maximized state from that window, and resizes its client area.
It does not change the monitor resolution. OBS fits the captured window
inside its 1080p canvas.

## Shared configuration and artwork

OBS uses the existing [button configuration](buttons.md), with this action:

```json
{"kind":"obs","operation":"recordToggle"}
```

Operations are `recordToggle`, `pauseToggle`, `micToggle`, `open`, and
`minecraft1080`. Optional `visual.states` maps `recording`, `paused`,
`muted`, `unavailable`, `running`, and `ready` to managed image paths. The default visual remains
`visual.image`. PNG, JPEG, and animated GIF preparation and limits apply to
every variant. A status change selects preloaded media without resetting menu
navigation, held keys, or animation timing.

The GUI offers an OBS operation picker and state-image editor. Its draft
state preview does not change OBS. AI tools can use `knobby config export`,
`import-asset`, `validate --prepare`, and `apply` through the same validation
and revision checks. Drafts and the last valid configuration survive failure.

`assets/obs/` contains deterministic 72×72 pixel-art originals. Regenerate
them with `nim r gui/app/tools/generate_obs_icons.nim` using the isolated GUI
dependencies. Initial menu installation is explicit:

```sh
nix develop --command nim r tools/setup_obs_buttons.nim --apply
```

This imports artwork and adds the menu against the current revision, preserving
the other bindings. It refuses to overwrite an existing `obs` menu; edit that
menu through the normal editor instead.

## Runtime and installation

The daemon remains standard-library Nim. A separate headless `knobby-obs`
helper uses the GUI workspace's already pinned `ws` and `crunchy` packages
for OBS WebSocket 5 and its challenge authentication. It reads the password
from OBS's own local settings; credentials are never stored in button JSON.
OBS must enable its authenticated WebSocket server. No firewall changes are
needed for the local client.

`knobby-obs request GetRecordStatus` performs a read-only diagnostic request.
The daemon supervises `knobby-obs bridge` through bounded pipes, command
queues, and deadlines. Losing the helper marks status unavailable without
interrupting MIDI, faders, lighting, or the Stream Deck connection. Quitting
Knobby leaves OBS and any recording running.

The Nix package pins `obs-pipewire-audio-capture` 1.2.1, supported by the
installed OBS 32.1.2. The installer links this plugin into OBS's user plugin
directory and refuses to replace an unmanaged installation. Loading a newly
installed plugin requires an idle OBS restart. It never replaces system OBS.

To reproduce the OBS project, enable authenticated WebSocket control in OBS,
then run the installed setup tool:

```sh
knobby-obs-setup prepare-online
# Quit OBS while it is idle, then:
knobby-obs-setup configure-offline --render-device /dev/dri/by-path/pci-0000:03:00.0-render
# Reopen OBS on the Minecraft AI Demos profile and collection.
```

The online mode checks recording/streaming before changes. The offline mode
refuses while OBS runs, preserves unknown profile settings, and makes private
backups before atomic replacement. The setup is repeatable; it does not reset
an existing microphone mute choice. Global audio devices in the new collection
must be disabled; the tool refuses them rather than record desktop audio.

Window binding uses X11 identity directly. OBS 32.1.2 crashed when its WebSocket
window-property-list request encountered a null item, so the production bridge
and setup do not use that enumeration request.

References: [OBS WebSocket protocol](https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md),
[Xcomposite implementation](https://github.com/obsproject/obs-studio/blob/32.1.2/plugins/linux-capture/xcomposite-input.c),
[application-audio matching](https://github.com/dimtpap/obs-pipewire-audio-capture/blob/1.2.1/src/pipewire-audio-capture-app.c),
and [Prism instance environment](https://github.com/PrismLauncher/PrismLauncher/blob/11.1.1/launcher/minecraft/MinecraftInstance.cpp).

The installer restarts the daemon after all package checks pass. It leaves
the existing Knobby GUI and its drafts running. After this IPC version 4
update, choose **Quit viewer** from the tray, then run
`~/.local/bin/knobby-gui` to load the new editor.

## Verification

Hardware-free tests cover WebSocket authentication and failures, commands
against a fake OBS server, state selection, preloaded animation lifecycles,
and helper death/stalls with no command replay. GUI screenshots and interaction
checks run on a private Xvfb display. Live recording acceptance is a separate,
user-triggered check: record a short clip, pause/resume, stop, and inspect
video dimensions, audio tracks, game isolation, and the remuxed file. Automated
checks never start a desktop recording or play test sounds.

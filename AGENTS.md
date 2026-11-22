# Knobby

- Linux MIDI controller daemon.
- Focus: stable background service behavior and predictable MIDI event handling.
- Desktop integration remains specific to high-steel. Buttons and their menus
  are editable through shared JSON configuration and the GUI/CLI. Faders, audio
  targeting, and mousepad lighting remain compiled; do not broaden configuration
  beyond buttons without a user request.
- Hardware is an Arduino Micro MIDI mixer documented in docs/hardware.md:
  12 buttons (notes 1-12) and 4 faders (CC 16-19).
- Faders drive PipeWire volumes through pactl; buttons launch apps. Shared
  bindings are consts in src/knobby/bindings.nim; actions.nim dispatches them.

## Layout

- `src/knobby.nim` - daemon entrypoint: detect the Arduino, dispatch event
  batches, reconnect on disconnect.
- `src/knobby/midi_monitor.nim` - aseqdump wrappers: port detection, per-line
  and batched sessions. Batches coalesce fader bursts so the last value wins.
- `src/knobby/midi_events.nim` - parse aseqdump output lines into MidiEvent.
- `src/knobby/midi_supervisor.nim` - retry MIDI discovery and sessions without restarting other workers.
- `src/knobby/actions.nim` - action dispatch, fader endpoint snap and deadband,
  pactl volume calls, detached app launchers.
- `src/knobby/audio_outputs.nim` - pactl sink-input listing.
- `src/knobby/razer_lighting.nim` - optional OpenRazer mousepad lighting through D-Bus.
- `src/knobby/stream_deck.nim` - Linux hidraw transport and MK.2 report codecs for the standalone demo.
- `src/knobby/status.nim` - locked authoritative state shared by daemon workers.
- `src/knobby/fader_cache.nim` - atomic, rate-limited last-known fader display cache.
- `src/knobby/ipc.nim` - bounded nonblocking local sockets and versioned framing.
- `src/knobby/daemon_workers.nim` - independent button, fader, Stream Deck, audio, IPC, and cache workers.
- `src/knobby/obs_worker.nim` - supervised headless OBS helper with bounded queues and no command replay.
- `src/knobby/obs_state.nim` - authoritative OBS observations and pure state-art selection.
- `src/knobby/obs_projects.nim`, `obs_menu.nim` - shared recording profile, Minecraft/Firefox/WoW collections and nested Deck menu installation.
- `gui/app/src/wow_capture.nim` - exact Classic/Wine or Nim window selection, process-verified audio, and explicit 1080p sizing.
- `gui/app/tools/setup_obs_shared.nim` - additive, inactive shared-profile and WoW collection provisioning.
- `src/knobby/firefox_demo_config.nim`, `gui/app/src/firefox_demo.nim` - dedicated configurable Firefox demo window and isolated application audio.
- `src/knobby/discord_calls.nim` - bounded incoming-call AT-SPI observation and explicit voice/video answer queue.
- `src/knobby/work_menu.nim` - pure Softmax submenu install from `docs/work-menu-targets.json` (`tools/setup_work_buttons.nim`).
- `src/knobby/task_menu_links.nim` - reciprocal Deck shortcuts between Softmax and Discord (`tools/setup_task_links.nim`).
- `src/knobby/spotify.nim`, `spotify_menu.nim` - explicit local Spotify playback and an additive submenu; `tools/knobby_spotify.nim` handles on-demand PKCE/API requests, never background playback.
- `src/knobby/custom_buttons.nim` - mark known external integrations as editor-protected custom logic; `tools/setup_custom_buttons.nim` applies metadata without changing actions or artwork.
- `src/knobby/workflow_menu.nim` - compact workflow layouts with Home at key 1, Menu at key 5 on subpages, fixed bottom-right context links, and flattened OBS controls (`tools/setup_workflow_layout.nim`; see docs/navigation.md).
- `src/knobby/navigation_menu.nim` - historical four-key-prefix migration retained for legacy configuration tests; current setup does not reserve a permanent global header.
- `src/knobby/discord_worker.nim`, `controls_state.nim` - isolated Discord RPC supervision and shared observed microphone/control state.
- `src/knobby/overlay_state.nim`, `overlay_activation.nim` - transient MIDI help requests and explicit overlay service activation.
- `src/knobby/gui_activation.nim` - activate one GUI instance through its user service.
- `src/knobby/audio_status.nim` - pure pactl JSON parsing for the viewer.
- `src/knobby/button_config.nim` - shared button schema, validation, and atomic storage.
- `src/knobby/button_runtime.nim` - authoritative menus, temporary Deck Menu row, independent MIDI navigation, and configuration transactions.
- `src/knobby/button_media.nim` - bounded FFmpeg preparation and managed artwork imports.
- `src/knobby/stream_deck_player.nim` - active-page animation and responsive HID writes.
- `gui/app/` - Windy/Silky viewer and button editor; `gui/` is its isolated Nimby workspace.
- `gui/app/src/knobby_overlay.nim` - independent, passive X11 mixer legend; it starts only on Help requests.
- `gui/app/src/obs_client.nim`, `obs_workspace.nim`, `obs_targets.nim` - authenticated OBS WebSocket control and exact Minecraft targets.
- `gui/app/src/minecraft_window.nim`, `minecraft_audio.nim` - X11 client sizing and per-process audio-label verification.
- `docs/obs.md` - Minecraft recording profile, submenu, setup, and live acceptance.
- `examples/` - midi_monitor and audio_outputs demos (see README.md).
- `docs/example_out.txt` - real capture of every button and fader; the
  reference for parser behavior and test cases.

## Dependencies

- Daemon: Nim >= 2.0.0, standard library only (no package dependencies).
- GUI: Nim >= 2.2.4; use Nimby >= 0.2.3 and `gui/app/nimby.lock` inside
  the isolated `gui/` workspace. Do not install into the shared parent
  workspace or update global packages. GUI commands are in docs/gui.md.
- External command-line tools, all provided by the flake dev shell
  (`nix develop`): aseqdump and aconnect (alsa-utils), pactl (pulseaudio),
  wmctrl, curl, busctl (systemd).
- Stream Deck support uses Linux hidraw and POSIX calls directly, with the
  system's Linux headers. It adds no third-party C or Nim library dependency.
- Regenerating the committed Stream Deck JPEG assets needs FFmpeg and
  `fc-match` (fontconfig) with DejaVu Sans Bold. Running the demo does not.
- Mousepad lighting uses the separately installed OpenRazer driver and user
  daemon. Missing OpenRazer must not interrupt MIDI or audio handling.

## Tests

- Run `nimble test` to run all tests
- Individual test files can be run individually `nim r tests/test_*.nim`
- Unit tests must not call pactl, launch apps, or need the hardware. Test
  pure logic (parsing, fader math, coalescing) against lines from
  docs/example_out.txt.
- GUI smoke tests run under a private Xvfb display and D-Bus session. Never
  open a GUI window on the user's desktop for automated verification.

## Git Publication

- After completing authorized changes and the required checks, commit your
  changes and push to both `origin` (Gitea) and `github` (GitHub). Monofuel wants
  both remotes kept current automatically; do not wait for another commit or
  push request unless he explicitly asks to leave the work unpublished.
- Review the staged changes and preserve unrelated work in this shared checkout.
  Never force-push. Verify both remote branch tips match the published commit
  and report any failure to publish.

## Systemd User Service

The daemon runs as a systemd user service. The reference copy is
`docs/knobby.service`; the live copy is `~/.config/systemd/user/knobby.service`.

- After code or service changes, build, check, and install the compiled Nix package:

```
nix develop --command nim r tools/install.nim
```

- Logs: `journalctl --user -u knobby -f`
- The GUI unit is `docs/knobby-gui.service`; it starts hidden at graphical
  login. Running `knobby-gui` activates that same process. The installer
  enables it for future logins without opening a desktop window.
- Services execute verified prebuilt binaries. Restarting does not rebuild;
  rebuild/install first. The daemon owns all device and audio observations.
- Installation and verification must not launch or restart desktop GUI
  processes automatically. Preserve existing viewers and drafts; report an
  exact reopen step when a protocol/editor update requires it. A task-specific
  explicit user exception permits restarting an existing viewer for that task.
- Stream Deck writers take an exclusive process lock outside service-managed
  runtime directories. Stop the daemon before running display demos/probes.
- Never edit the live copy directly; edit docs/knobby.service and copy it, so
  the repo copy stays the source of truth.

## Nim

## Nim best practices

**Prefer letting errors bubble up naturally** - Nim's stack traces are excellent for debugging:

Default approach - let operations fail with full context:
```nim
# Simple and clear - if writeFile fails, we get a full stack trace
writeFile(filepath, content)

# Database operations - let them fail with complete error information
db.exec(sql"INSERT INTO users (name) VALUES (?)", username)
```

For validation and early returns, check conditions explicitly:
```nim
# Check preconditions and exit early with clear messages
if not fileExists(parentDir):
  error "Parent directory does not exist"
  quit(1)

if username.len == 0:
  error "Username cannot be empty"
  quit(1)

# Now proceed with the operation
writeFile(filepath, content)
```

This approach ensures full stack traces in CI environments and makes debugging straightforward.

### Nim Imports

- std imports should be first, then libraries, and then local imports
- use [] brackets to group when possible
- split imports on newlines
for example,
```
import
  std/[strformat, strutils],
  debby/[pools, postgres],
  ./[models, logs, llm] 
```

### Nim Procs

- do not put comments before functions! comments go inside functions.
- every proc should have a nimdoc comment
- nimdoc comments start with ##
- nimdoc comments should be complete sentences followed by punctuation
for example,
```
proc sumOfMultiples(limit: int): int =
  ## Calculate the sum of all multiples of 3 or 5 below the limit.
  var total = 0
  for i in 1..<limit:
    if i mod 3 == 0 or i mod 5 == 0:
      total += i
  return total
```

### Nim Properties

- if an object property is the same name as a nim keyword, you must wrap it in backticks
```
  DeleteModelResponse* = ref object
    id*: string
    `object`*: string
    deleted*: bool
```

### Variables

- please group const, let, and var variables together.
- please prefer const over let, and let over var.
- please use capitalized camelCase for consts
- use regular camelcase for var and let
- do not place 'magic variables' in the code, instead make them a const and pull them up to the top of the file
- for example:

```
const
  Version = "0.1.0"
  Model = "llama3.2:1b"
let
  embeddingModel = "nomic-embed-text"
```

## Programming

- Don't use try/catch unless you have a very, very good reason to be handling the error at this level.
- never mask errors with catch: discard
- it's OK to allow errors to bubble up. we want things to be easy to debug and fail fast.
- returning in the middle of files is confusing, avoid doing it.
  - early returns at the start of the file is ok.
- try to make things as idempotent as possible. if a job runs every day, we should make sure it can be robust.
- never use booleans for 'success' or 'error'. If a function was successful, return nothing and do not throw an error. if a function failed, throw an error.

### Comments

- functions should have doc comments
- however code should otherwise not need comments. functions should be named properly and the code should be readable.
- comments may be ok for 'spooky at a distance' things in rare cases.
- comments should be complete sentences that are followed with a period.

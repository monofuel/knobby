# High-Steel Scope

This doc describes Knobby's integration with `high-steel`, monofuel's NixOS
desktop. Buttons and menus now use the [shared editable configuration](buttons.md);
fader and audio targeting remain specific to this machine.

## Background

On Windows, monofuel used [MIDI Mixer](https://www.midi-mixer.com/) to drive
app volumes from the hardware mixer: faders mapped to application volumes and
buttons handled toggles like mute. It worked great (very funky UI) but is
Windows only. Knobby's v1 goal is to replicate that setup on Linux.

## Environment

- Host: `high-steel` (NixOS, PipeWire 1.4.9 with the PulseAudio compat layer).
- Controller: the Arduino Micro MIDI mixer described in `docs/hardware.md`
  (12 Cherry buttons sending notes 1-12, 4 faders sending CC 16-19).
- Audio control goes through `pactl` (provided by the flake dev shell), the
  same tool `src/knobby/audio_outputs.nim` already uses to list sink inputs.
- Typical audio clients on this machine: Firefox, Spotify, FINAL FANTASY XIV.
- Output sink: Bose USB desktop speakers
  (`alsa_output.usb-Generic_Bose_PC_Desktop_Controller_*.analog-stereo`).
- Microphone: the BenQ EX3210U monitor's built-in mic
  (`alsa_input.usb-Generic_BenQ_EX3210U-00.iec958-stereo`) is the preferred
  mic because its noise cancellation beats the other mics on this machine.
  It is not the PipeWire default source (the Lenovo webcam mic usually is),
  so mic actions must target sources by name rather than `@DEFAULT_SOURCE@`.
  Other live mics: the Lenovo Performance Camera, the Bose desktop
  controller's speakerphone mic, and the onboard analog input.

## v1 Scope

Replicate the Windows MIDI Mixer setup:

- Daemon connects to the Arduino automatically and reconnects when the device
  drops, reusing the detect/reconnect loop proven in
  `src/knobby/midi_monitor.nim`.
- Each fader is bound to a volume target. CC value 0-127 maps linearly to
  0-100% volume.
- Buttons are bound to simple actions such as launching apps.
- Fader targeting uses compiled bindings; button assignments use shared JSON.

### Bindings

Fader bindings match the old Windows MIDI Mixer profile:

| Control   | Target                                        |
|-----------|-----------------------------------------------|
| Fader 16  | Master volume (the default output sink, normally the Bose PC desktop controller) |
| Fader 17  | Browsers: Firefox, Google Chrome and Chromium |
| Fader 18  | Spotify                                       |
| Fader 19  | Games: any Steam-launched app (SteamAppId in `/proc/<pid>/environ`), any stream with `media.role = game` (OpenAL Soft apps like decompbound's player), plus a name whitelist (FINAL FANTASY XIV, World of Warcraft) |

Button bindings deviate from the Windows profile (just re-organizing). Button
numbers refer to the grid in `docs/hardware.md`:

| Button | Position     | Action                                             |
|--------|--------------|----------------------------------------------------|
| 12     | Top left     | Launch Firefox and open grok.com                   |
| 9      | Top, col 2   | Launch Firefox and open claude.ai                  |
| 6      | Top, col 3   | Open https://chatgpt.com/ in a new Firefox window |
| 3      | Top right    | Show the temporary MIDI button legend             |
| 10     | Bottom left  | Launch FINAL FANTASY XIV through Steam (XIVLauncher) |
| 11     | Middle left  | Toggle mic mute on every real input source at once |
| 8      | Middle, col 2 | Toggle Discord self-mute through its local RPC socket |
| Others | -            | TBD                                                |

The ChatGPT binding is an ordinary editable `command` action:
`firefox --new-window https://chatgpt.com/`. It follows the Grok and Claude
browser-launch behavior and requires no daemon or viewer restart when assigned.

Button 11 mutes all mics together rather than just the default source: the
preferred BenQ monitor mic is not the PipeWire default, and muting everything
guarantees no mic is hot regardless of which one an app grabbed. The toggle
keys off the BenQ mic's current state so the sources cannot drift out of
sync.

Button 8 toggles Discord's own self-mute over the local RPC socket
(`$XDG_RUNTIME_DIR/discord-ipc-0`, length-prefixed JSON frames implemented in
`src/knobby/discord_rpc.nim`) so Discord shows its muted icon. It needs a
one-time OAuth setup: create an application at
discord.com/developers/applications, add `http://127.0.0.1` as an OAuth2
redirect (the app must have one registered, but the RPC flow rejects a
`redirect_uri` passed in the request itself), write its id and secret to
`~/.config/knobby/discord_rpc.json` as `{"clientId": ..., "clientSecret":
...}`, then run `nim r examples/discord_auth.nim` and approve the popup in
Discord. Tokens are cached in the same file and refreshed automatically by
the daemon. The daemon keeps one authenticated RPC connection open across
presses: Discord rate-limits handshakes per client id, so
connecting per press makes the next press hang until the limit expires. The RPC voice API is officially reserved for approved apps but
works against one's own local client; if Discord ever locks it down, the
fallback is Vesktop with portal-based global keybinds.

Button 10 launches the non-Steam Steam shortcut named "Final Fantasy XIV",
which runs `~/bin/xivlauncher-cpu`. That existing wrapper starts the XIVLauncher
Flatpak with the saved performance profile and existing `~/.xlcore` game data.
Going through Steam is deliberate so friends can see the game
in monofuel's Steam status. FFXIV is not owned on Steam: monofuel plays on a
regular non-Steam account from before the Steam version existed, and
XIVLauncher (Dalamud) provides TOTP input and fine-grained wine version
control. The launch command is:

```
steam steam://rungameid/9547416891190935552
```

(The id is the synthetic rungameid for the "Final Fantasy XIV" shortcut in
`~/.local/share/Steam/userdata/35647166/config/shortcuts.vdf`; it changes if
the shortcut is ever recreated.)

For the MVP, button 10 only launches XIVLauncher; login and OTP entry stay
manual. See Future Goals for the automated version.

App-bound faders should apply to all sink inputs whose application name
matches (Firefox opens several).

## Future Goals

- Automatic FFXIV TOTP login: unlock Bitwarden with a master key protected by
  the TPM, fetch the Square Enix TOTP with `bw get totp`, and post it to
  XIVLauncher's OTP-macro listener (`http://127.0.0.1:4646/ffxivlauncher/<otp>`).
  The old Windows version of this lives at
  `~/Documents/recovered-windows-bin/auto-ffxiv.ps1` (recovered from the
  Windows partition). It used PowerShell's `ConvertFrom-SecureString` (DPAPI,
  user-account-scoped) to protect the Bitwarden master password; a Linux
  equivalent would look totally different, e.g. sealing the key with the TPM
  via systemd-creds or tpm2-tools.

## Non-Goals (for now)

- Configuring fader/audio targets or lighting presets through the GUI.
- Windows or macOS support.
- Additional device integrations beyond the current mixer, Stream Deck, and mousepad.
- Multiple controllers at once. Several mixers exist (see Board Variants in
  `docs/hardware.md`) but only one is plugged into high-steel.

## Open Questions

- Bindings for the remaining 7 buttons.

Resolved: button 10 checks for a running `ffxiv_dx11.exe` process and focuses
the game window with `wmctrl -a "FINAL FANTASY XIV"` instead of relaunching
(a second Steam launch fails silently in the background). The game runs under
XWayland, so wmctrl works even though the desktop session is Wayland. Firefox
buttons relaunch freely since Firefox delegates to the existing instance.
Resolved: fader levels are remembered and re-applied when new sink inputs
appear. A background thread watches `pactl subscribe` for new sink-input
events; without this, apps that open a fresh stream per sound (Firefox web
apps, for example) would play sounds born after the fader move at their old
volume.
- Whether fader moves should be absolute-set immediately or soft-takeover.
  Absolute-set is simpler and matches the hardware doc; start there.

## Daemon Recovery

MIDI sessions read nonblocking output in bounded batches, with no reader
thread or channel. Session subprocesses are reaped even when dispatch fails.
Quiet MIDI input is normal: the main loop polls every 100 ms and continues
reporting progress without requiring fader movement.

An independent watchdog exits the daemon if the main loop makes no progress
for 30 seconds. Systemd then restarts it after one second. Discord responses
have a total deadline, a frame-count limit, and a maximum frame size; token
requests also have network timeouts. Microphone commands use the same
one-second timeout as volume commands.

Services use verified prebuilt executables; rebuild/install after source changes.
Inspect recovery messages with
`journalctl --user -u knobby --since today`. A watchdog restart is recovery
from a stall, not evidence that its original cause has been identified.

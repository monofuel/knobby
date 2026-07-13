# High-Steel Scope

This doc defines what knobby v1 should do on `high-steel`, monofuel's NixOS
desktop. Per the README, nothing is configurable yet: knobby should work for
exactly this machine and this hardware before anything clever happens.

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

## v1 Scope

Replicate the Windows MIDI Mixer setup:

- Daemon connects to the Arduino automatically and reconnects when the device
  drops, reusing the detect/reconnect loop proven in
  `src/knobby/midi_monitor.nim`.
- Each fader is bound to a volume target. CC value 0-127 maps linearly to
  0-100% volume.
- Buttons are bound to simple actions such as launching apps.
- Bindings are hardcoded constants for this machine. No config file.

### Bindings

Fader bindings match the old Windows MIDI Mixer profile:

| Control   | Target                                        |
|-----------|-----------------------------------------------|
| Fader 16  | Master volume (the Bose PC desktop controller sink) |
| Fader 17  | Firefox (often YouTube)                       |
| Fader 18  | Spotify                                       |
| Fader 19  | FINAL FANTASY XIV                             |

Button bindings deviate from the Windows profile (just re-organizing). Button
numbers refer to the grid in `docs/hardware.md`:

| Button | Position     | Action                                             |
|--------|--------------|----------------------------------------------------|
| 12     | Top left     | Launch Firefox and open grok.com                   |
| 9      | Top, col 2   | Launch Firefox and open claude.ai                  |
| 10     | Bottom left  | Launch FINAL FANTASY XIV through Steam (XIVLauncher) |
| Others | -            | TBD                                                |

Button 10 launches the non-Steam Steam shortcut named "Final Fantasy XIV",
which runs XIVLauncher (`XIVLauncher.Core`, the nixpkgs install, config in
`~/.xlcore`). Going through Steam is deliberate so friends can see the game
in monofuel's Steam status. FFXIV is not owned on Steam: monofuel plays on a
regular non-Steam account from before the Steam version existed, and
XIVLauncher (Dalamud) provides TOTP input and fine-grained wine version
control. The launch command is:

```
steam steam://rungameid/9332724227821797376
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

- Config files or any user-facing configuration.
- Windows or macOS support.
- A GUI.
- Multiple controllers at once. Several mixers exist (see Board Variants in
  `docs/hardware.md`) but only one is plugged into high-steel.

## Open Questions

- Bindings for the remaining 9 buttons.

Resolved: button 10 checks for a running `ffxiv_dx11.exe` process and focuses
the game window with `wmctrl -a "FINAL FANTASY XIV"` instead of relaunching
(a second Steam launch fails silently in the background). The game runs under
XWayland, so wmctrl works even though the desktop session is Wayland. Firefox
buttons relaunch freely since Firefox delegates to the existing instance.
- Behavior when a bound app has no active stream: ignore, or remember the
  level and apply when the app appears?
- Whether fader moves should be absolute-set immediately or soft-takeover.
  Absolute-set is simpler and matches the hardware doc; start there.

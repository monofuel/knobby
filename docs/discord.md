# Discord controls and the MIDI legend

Open **Discord controls (3)** from Home, or press **Menu (5)** then **Discord (3)**.
The top-row menu is temporary; pressing Menu again restores the page's own
controls. Mixer buttons remain independent.

| Key | Control | What it changes |
| --- | --- | --- |
| 1 | Home | Return to Home, with Menu open or closed. |
| 2 | System Mic | Toggle all real system microphone inputs together. |
| 3 | Discord Mic | Toggle Discord's own self-mute. |
| 4 | Deafen | Toggle Discord's own deafen state. |
| 5 | Menu | Reveal/cancel workflow navigation on keys 2–4. |
| 6 | Answer voice | Answer the current incoming call with voice. |
| 7 | Answer video | Answer the current incoming call with video. |
| 8 | Open Discord | Focus Discord, or launch it when closed. |
| 14 | Softmax menu | Switch to work controls, consistently at the bottom right. |
| 15 | OBS controls | Direct link to recording controls. |

Softmax key 13 opens the Discord app; its key 14 opens this controls page.
Navigation leaves the MIDI mixer unchanged.

System mic mute affects applications using those microphones. Discord mic mute
affects Discord only. OBS Commentary remains a separate recording control in
the OBS submenu. Duplicate MIDI and Deck buttons use the same actions.

The icons show observations rather than guessing from the last press: green
**LIVE**, red **MUTED** or **DEAF**, amber **MIXED** when microphone inputs
disagree, and grey **N/A** when state cannot be established. Both mute buttons
show a **microphone**, with a silver **gear** beside the system mic and the
original purple **pixel chat face** beside the Discord mic. The chat face also
identifies the Discord menu and Open button. There are no source-word headers.
Open Discord shows grey
**OPEN** when closed and green **READY** when running; it does not imply RPC
authorization succeeded.

Discord status uses the existing local RPC authorization described in
[desktop setup](high-steel.md). One background worker keeps the connection and
checks for changes made inside Discord too. Closing Discord or losing its RPC
connection does not interrupt the faders, OBS controls, or other devices.
No microphone or deafen button automatically launches Discord.

## Answering incoming calls

Keys 6 and 7 use Discord's Linux accessibility interface (AT-SPI), because its
documented local RPC does not provide separate incoming voice/video answer
commands. The phone and camera symbols show grey **WAIT** while idle, green
**READY** when that specific incoming answer control is available, or **N/A**
if the desktop controls cannot be read. A voice-only incoming call may offer
only the voice answer option. Neither key starts an outgoing call or launches
Discord. Video answer uses Discord's own video-answer control; it does not
toggle a camera in an existing call.

The session accessibility bridge must be enabled and Discord must expose its
renderer accessibility tree. On high-steel it was enabled before restarting
Discord with `--force-renderer-accessibility`; Knobby's Open Discord action
includes that flag for future launches. No screen reader is started.
Other launchers may need the same flag and a normal Discord reopen if the keys
show N/A. The bridge can be checked with:

```sh
busctl --user get-property org.a11y.Bus /org/a11y/bus org.a11y.Status IsEnabled
```

The worker matches visible incoming-call dialogs and exact answer captions,
rechecks a target before pressing it, and never retries an uncertain answer.
Missing, translated, or ambiguous controls fail without clicking another UI
element. English Discord captions are currently supported. It runs separately
from the fader and mute workers. Closing/reopening Discord is rediscovered.
Automated tests use injected accessibility fixtures and never place or accept
real calls; actual incoming voice/video acceptance still needs human use.

## MIDI button legend

The mixer's **top-right button, note 3**, shows its twelve current button labels
at the bottom center of the primary middle monitor. The legend matches the
physical layout:

```text
12   9   6   3
11   8   5   2
10   7   4   1
```

It disappears after ten seconds or when another MIDI or Stream Deck button is
pressed. That other button still performs its normal action. Press Help again
to close it, and press once more to reopen it for ten seconds. Moving faders
leaves the legend visible.

The legend takes no keyboard focus and mouse clicks pass through it, including
the cards. It uses transparent gaps around readable dark cards. Without an X11
compositor the cards are opaque; with compositing they can be translucent.
Knobby does not change the desktop's compositor configuration.

The overlay renderer runs independently of the editor and reads the daemon's
active labels. It starts on a Help press, stays hidden between uses, and hides
if daemon state becomes unavailable. Closing the editor does not disable it.

## Recreating this setup

After installing Knobby, add the menu and Help binding through its shared
configuration API:

```sh
nix develop --command nim r tools/setup_discord_buttons.nim --apply
```

This refuses to replace an existing Discord menu or an occupied root key 3 on
either device. Use the editor or export/edit/apply to change an existing setup.
Other bindings, OBS menus, faders, and unfinished editor drafts are preserved.
Use `--refresh-art` instead of `--apply` to update the standard key faces in an
existing Discord menu while retaining titles and bindings.
Use `--upgrade` to add the answer controls to unused Discord keys 6 and 7 and
refresh standard faces; occupied custom keys are refused before applying any
configuration. Applying is revision checked and keeps the last valid config.
Artwork is generated alongside the OBS icons by
`gui/app/tools/generate_obs_icons.nim`. The pixel chat face, microphones,
frames, gear, phone, and camera are original Knobby artwork.

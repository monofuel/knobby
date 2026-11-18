# Discord controls and the MIDI legend

Main-menu Stream Deck **key 3** opens Discord. The MIDI buttons stay on their
current assignments while you navigate this Deck submenu.

| Key | Control | What it changes |
| --- | --- | --- |
| 1 | Back | Return to the previous Deck menu. |
| 2 | System Mic | Toggle all real system microphone inputs together. |
| 3 | Discord Mic | Toggle Discord's own self-mute. |
| 4 | Deafen | Toggle Discord's own deafen state. |
| 5 | Open Discord | Focus Discord, or launch it when closed. |

System mic mute affects applications using those microphones. Discord mic mute
affects Discord only. OBS Commentary remains a separate recording control in
the OBS submenu. Duplicate MIDI and Deck buttons use the same actions.

The icons show observations rather than guessing from the last press: green
**LIVE**, red **MUTED** or **DEAF**, amber **MIXED** when microphone inputs
disagree, and grey **N/A** when state cannot be established. A teal **SYSTEM**
header and a purple **DISCORD** header distinguish the microphone controls,
including when both are muted. Open Discord shows grey
**OPEN** when closed and green **READY** when running; it does not imply RPC
authorization succeeded.

Discord status uses the existing local RPC authorization described in
[desktop setup](high-steel.md). One background worker keeps the connection and
checks for changes made inside Discord too. Closing Discord or losing its RPC
connection does not interrupt the faders, OBS controls, or other devices.
No microphone or deafen button automatically launches Discord.

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
Artwork is original, generated alongside the OBS icons by
`gui/app/tools/generate_obs_icons.nim`.

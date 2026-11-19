# Shared Deck navigation

The main, OBS, Discord, and Softmax Stream Deck menus share their top-left
keys, so switching tasks always uses the same place:

| Key | Main menu | OBS, Discord, Softmax |
| --- | --- | --- |
| 1 | HOME (stays on the main menu) | HOME |
| 2 | OBS | OBS |
| 3 | CHAT (Discord controls) | CHAT (Discord controls) |
| 4 | SOFT (Softmax) | SOFT (Softmax) |

These keys change menus on the Deck only; the MIDI mixer keeps its current
menu. Home always returns directly to the main menu and clears the Deck's
navigation history. Pressing Home on the main menu does nothing. Pressing
the shortcut for the menu you are already in also does nothing.

## Colors

A **purple** frame and label mark keys that change menus. Every other key keeps
its state colors: green ready or live, red muted or recording, amber attention
or paused, grey closed or unavailable. Action faces are unchanged.

## Actions after the shared keys

| Menu | Keys |
| --- | --- |
| Main | 5-15 unassigned |
| OBS | 5 REC, 6 PAUSE, 7 Commentary mic, 8 Open OBS, 9 Minecraft 1080 |
| Discord | 5 System mic, 6 Discord mic, 7 Deafen, 8 Open Discord, 9 Answer voice, 10 Answer video |
| Softmax | 5 PRISM, 6 WOW VANILLA, 7 WOW NIM, 8 DISCORD (foreground the app), 9 SLACK, 10 LAB (autoresearch, port 8103), 11 PROD, 12 STAGE, 13 NEXT (staging game list), 14 REALM (WoW dashboard, port 7777), 15 START (Start WoW Server) |

Softmax key 15 runs exactly
`cd /home/monofuel/src/wow-coworld && nix develop /home/monofuel/src/wow-coworld/wow-shadow-army --command bash /home/monofuel/src/wow-coworld/tools/private_realm.sh start`.
It starts the existing persistent private world, or reports that it is already
running. See [the Softmax guide](work.md).

## Applying the layout

Install Knobby, then reorganize the four menus through the shared
configuration API:

```sh
nix develop --command nim r tools/setup_navigation.nim --apply
```

The tool checks the result before importing artwork, imports only the purple
navigation faces and the Start face, then applies against a freshly read
revision. It does nothing when the layout is already organized.

It replaces only Back, Home, and Deck-only links among these four menus. Every
other key keeps its title, action, and artwork; only its key may change. Keys
already clear of 1-4 stay where they are. A menu that still has actions on keys
1-4 is repacked from key 5 in its existing order, with Start always on Softmax
key 15. Links to other menus, links that also switch the mixer, other menus,
and every mixer binding are left alone. The tool refuses, without changing
anything, when a menu is missing, actions would not fit, or Softmax key 15
already holds something else.

To recreate the whole setup, run the normal menu installers first (OBS,
Discord, Softmax, task links), then `setup_navigation.nim --apply` last. The
other helpers find their standard keys wherever navigation moved them.

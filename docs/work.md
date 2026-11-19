# Work submenu

Root Stream Deck key 4 opens **Work** on the Deck only; the MIDI mixer stays
where it is. Key 1 is the standard linked Back.

| Key | Label | Opens |
| --- | --- | --- |
| 2 | PRISM | `~/bin/prism` in the same `knobby-prism.service` unit as the OBS key |
| 3 | WOW | The genuine 1.12.1 client for the human seat (`make play-classic`) |
| 4 | NIM | The native Nim WoW client with the human controller (`make play`) |
| 5 | OPEN/READY | Discord, focusing an open window first, with live status art |
| 6 | SLACK | The installed Slack desktop app |
| 7 | LAB | The local coworld-autoresearch dashboard |
| 8 | PROD | The Fast-XP production performance dashboard |
| 9 | STAGE | The Fast-XP staging performance dashboard |
| 10 | NEXT | The staging `/next/` list of experimental Polyworld games |

Both WoW keys run the documented human play targets in
`~/src/wow-coworld/wow-shadow-army` and need its local realm running. Dashboard
keys open exact URLs in a new Firefox window. Fast-XP needs Tailscale access.

## Recreating this setup

The machine-specific launch commands and URLs live in
[work-menu-targets.json](work-menu-targets.json). After installing Knobby, add
the menu through the shared configuration API:

```sh
nix develop --command nim r tools/setup_work_buttons.nim --apply
```

Pass a different targets file, and optionally an assets directory, after
`--apply` to use other launchers. Setup refuses an occupied root Deck key 4 or a
different existing Work menu, and does nothing when the same Work menu is
already installed. Other menus, mixer bindings, faders, and editor drafts are
preserved. After installation, change titles, commands, or art in the editor
or through export/edit/apply like any other button.

Artwork is generated alongside the OBS and Discord icons by
`gui/app/tools/generate_obs_icons.nim`. Prism, Discord, and Back reuse their
existing faces; the briefcase, sword, crown, hash, flask, bolts, and gamepad
are original Knobby pixel art.

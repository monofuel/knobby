# Softmax submenu

Root Stream Deck key 4 opens **Softmax** on the Deck only; the MIDI mixer stays
where it is. Key 1 is the standard linked Back.

| Key | Label | Opens |
| --- | --- | --- |
| 2 | PRISM | Open/focus Prism using Knobby's existing launcher (`knobby-obs prism`) |
| 3 | WOW | The genuine 1.12.1 client for the human seat (`make play-classic`) |
| 4 | NIM | The native Nim WoW client with the human controller (`make play`) |
| 5 | OPEN/READY | Discord, focusing an open window first, with live status art |
| 6 | SLACK | The installed Slack desktop app |
| 7 | LAB | The local coworld-autoresearch dashboard |
| 8 | PROD | The Fast-XP production performance dashboard |
| 9 | STAGE | The Fast-XP staging performance dashboard |
| 10 | NEXT | The staging `/next/` list of experimental Polyworld games |
| 12 | REALM | The separate WoW private-world dashboard at `http://127.0.0.1:7777/` |

Both WoW keys run the documented human play targets in
`~/src/wow-coworld/wow-shadow-army` and need its local realm running. The Nim
launcher runs inside that project's Nix development environment; the Classic
target enters the same environment internally. Neither button starts bots or
an episode controller. Prism reuses the OBS helper's existing open/focus logic
and `~/bin/prism`, without choosing a modpack or resizing Minecraft.
Dashboard keys use `xdg-open` to open exact URLs in the normal browser
(currently Firefox). Fast-XP needs Tailscale access.

The WoW dashboard is distinct from the autoresearch dashboard on port 8103.
Key 11 is reserved for the private-world Start Server control, pending the
WoW owner's verified persistent-world launcher. The current upstream Compose
file ignores `VMANGOS_DB_DIR`, so its existing start paths must not be used
until that regression is repaired. Knobby setup does not start servers or
launch applications while installing the menu.

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
existing faces; the sword, crown, hash, flask, bolts, and gamepad are original
Knobby pixel art. The root Softmax key plots the two-output softmax of logits
(z, 0) for z from -4.5 to 4.5: a cyan p1 = e^z / (e^z + 1) and a gold
p2 = 1 / (e^z + 1) cross at 0.5 over silver axes.

Setup never replaces artwork on an installed menu. To show regenerated root
art, refresh only that key image; every other button, menu, and mixer binding
is kept, and a root Deck key 4 that does not open the Softmax menu is refused:

```
nix develop --command nim r tools/setup_work_buttons.nim --refresh-menu-art
```

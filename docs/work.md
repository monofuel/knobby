# Softmax submenu

Root Stream Deck key 4 opens **Softmax** on the Deck only; the MIDI mixer stays
where it is. Key 1 is the standard linked Back.

| Key | Label | Opens |
| --- | --- | --- |
| 2 | PRISM | Open/focus Prism using Knobby's existing launcher (`knobby-obs prism`) |
| 3 | WOW VANILLA | The genuine 1.12.1 client for the human seat (`make play-classic`) |
| 4 | WOW NIM | The native Nim WoW client with the human controller (`make play`) |
| 5 | DISCORD | Discord, focusing an open window first |
| 6 | SLACK | The installed Slack desktop app |
| 7 | LAB | The local coworld-autoresearch dashboard |
| 8 | PROD | The Fast-XP production performance dashboard |
| 9 | STAGE | The Fast-XP staging performance dashboard |
| 10 | NEXT | The staging `/next/` list of experimental Polyworld games |
| 12 | REALM | The separate WoW private-world dashboard at `http://127.0.0.1:7777/` |
| 13 | CHAT | The Discord controls menu; this does not launch or focus the app |

The **DISCORD** key brings the app to the foreground; **CHAT** opens its controls
menu. Discord menu key **8** links back to Softmax using the same graph icon.
Both shortcuts affect only the Deck. Key 1 remains Back. Direct reciprocal
switches undo the last matching transition, so repeated task swaps keep Back
useful without filling navigation history.

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
different standard Work binding, and does nothing when its standard controls
are already installed. Extra buttons such as task shortcuts or the private
server control are retained. Other menus, mixer bindings, faders, and editor drafts are
preserved. After installation, change titles, commands, or art in the editor
or through export/edit/apply like any other button.

After installing both menus, add the reciprocal task shortcuts with:

```sh
nix develop --command nim r tools/setup_task_links.nim --apply
```

This refuses occupied foreign bindings on Softmax key 13 or Discord key 8.

Artwork is generated alongside the OBS and Discord icons by
`gui/app/tools/generate_obs_icons.nim`. Prism and Back reuse their existing
faces, and Discord reuses the pixel chat sprite under a fixed DISCORD caption;
the sword, crown, hash, flask, bolts, and gamepad are original Knobby pixel
art. Two-word and long captions use a compact 3x5 font, so the WoW keys read
WOW VANILLA and WOW NIM. The root Softmax key plots the two-output softmax of logits
(z, 0) for z from -4.5 to 4.5: a cyan p1 = e^z / (e^z + 1) and a gold
p2 = 1 / (e^z + 1) cross at 0.5 over silver axes.

Setup never replaces artwork on an installed menu. To show regenerated root
art, refresh only that key image; every other button, menu, and mixer binding
is kept, and a root Deck key 4 that does not open the Softmax menu is refused:

```
nix develop --command nim r tools/setup_work_buttons.nim --refresh-menu-art
```

The WoW Vanilla, WoW Nim, and Discord launchers (keys 3-5) have their own
refresh. It sets their titles and faces from the targets file and drops the
Discord key's state images so it always reads DISCORD. It changes nothing else,
and refuses unless each of those keys already runs its standard action:

```
nix develop --command nim r tools/setup_work_buttons.nim --refresh-launcher-art
```

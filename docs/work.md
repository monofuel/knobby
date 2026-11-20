# Softmax submenu

Open **Softmax** from Home, or press **Menu (1)** then **Softmax (5)**.
Menu temporarily replaces the top row; press it again to cancel. Its navigation
leaves the MIDI mixer unchanged. See [Menu navigation](navigation.md).

| Key | Label | Opens |
| --- | --- | --- |
| 1 | MENU | Toggle temporary navigation |
| 2 | PRISM | Open/focus Prism using the existing launcher |
| 3 | WOW VANILLA | The genuine 1.12.1 client (`make play-classic`) |
| 4 | WOW NIM | The native human Nim client (`make play`) |
| 5 | DISCORD | Open/focus the Discord app |
| 6 | SLACK | Open the installed Slack app |
| 7 | LAB | Local autoresearch dashboard, port 8103 |
| 8 | PROD | Fast-XP production performance dashboard |
| 9 | STAGE | Fast-XP staging performance dashboard |
| 10 | NEXT | Staging `/next/` experimental games list |
| 11 | REALM | Private-world dashboard, port 7777 |
| 12 | START | Start the existing persistent private WoW server |
| 13 | DISCORD MENU | Open Discord controls |
| 14 | OBS MENU | Open OBS controls |

The Discord app action and controls-menu link remain distinct. Discord's
controls page also keeps a direct Softmax link, so switching tasks stays quick.

Both WoW keys run the documented human play targets in
`~/src/wow-coworld/wow-shadow-army` and need its local realm running. The Nim
launcher runs inside that project's Nix development environment; the Classic
target enters the same environment internally. Neither button starts bots or
an episode controller. Prism reuses the OBS helper's existing open/focus logic
and `~/bin/prism`, without choosing a modpack or resizing Minecraft.
Dashboard keys use `xdg-open` to open exact URLs in the normal browser
(currently Firefox). Fast-XP needs Tailscale access.

The WoW dashboard is distinct from the autoresearch dashboard on port 8103.
**START** runs the WoW owner's verified persistent-world helper, independent of
the current directory:

```sh
cd /home/monofuel/src/wow-coworld && nix develop /home/monofuel/src/wow-coworld/wow-shadow-army --command bash /home/monofuel/src/wow-coworld/tools/private_realm.sh start
```

It reuses the existing world and database and reports when the server is
already running; it never resets or reseeds the world. It does not open a
browser or start bots, and it replaces the project's older start paths, which
must not be used. Knobby setup does not start
servers or launch applications while installing or reorganizing the menu.

## Recreating this setup

The machine-specific launch commands and URLs live in
[work-menu-targets.json](work-menu-targets.json). After installing Knobby, add
the menu through the shared configuration API. The targets file lists Start
WoW Server at its original key 11; the current workflow layout places it at key 12:

```sh
nix develop --command nim r tools/setup_work_buttons.nim --apply
```

Pass a different targets file, and optionally an assets directory, after
`--apply` to use other launchers. Setup refuses an occupied root Deck key 4 or a
different standard Work binding, and does nothing when its standard controls
are already installed at any keys. Extra buttons such as navigation keys or task
shortcuts are retained. Other menus, mixer bindings, faders, and editor drafts are
preserved. After installation, change titles, commands, or art in the editor
or through export/edit/apply like any other button.

After installing both menus, add the reciprocal task shortcuts with:

```sh
nix develop --command nim r tools/setup_task_links.nim --apply
```

The current workflow layout retains direct reciprocal links on Softmax key 13
and Discord key 8. Run `tools/setup_workflow_layout.nim --apply` last; see
[Menu navigation](navigation.md).

Artwork is generated alongside the OBS and Discord icons by
`gui/app/tools/generate_obs_icons.nim`. The root Softmax face and Back use the
purple navigation frame. Prism and Back reuse their existing
faces, and Discord reuses the pixel chat sprite under a fixed DISCORD caption;
the sword, crown, hash, flask, bolts, and gamepad are original Knobby pixel
art. Two-word and long captions use a compact 3x5 font, so the WoW keys read
WOW VANILLA and WOW NIM. The root Softmax key plots the two-output softmax of logits
(z, 0) for z from -4.5 to 4.5: a cyan p1 = e^z / (e^z + 1) and a gold
p2 = 1 / (e^z + 1) cross at 0.5 over silver axes.

Setup never replaces artwork on an installed menu. To show regenerated root
art, refresh only that key image; every other button, menu, and mixer binding
is kept, and a missing or duplicated root Softmax key is refused:

```
nix develop --command nim r tools/setup_work_buttons.nim --refresh-menu-art
```

The WoW Vanilla, WoW Nim, and Discord launchers have their own refresh. It
finds each by its standard action at whatever key it occupies, sets its title
and face from the targets file, and drops the Discord key's state images so it
always reads DISCORD. It changes nothing else, and refuses when a launcher is
missing or bound to several keys:

```
nix develop --command nim r tools/setup_work_buttons.nim --refresh-launcher-art
```

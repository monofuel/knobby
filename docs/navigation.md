# Menu toggle and workflow pages

Key **1 is MENU** on every Stream Deck page. It opens a temporary navigation
row; press it again to cancel and restore the current page's controls.

| Key | Navigation open |
| --- | --- |
| 1 | MENU, highlighted as open; press to cancel |
| 2 | Home |
| 3 | OBS controls |
| 4 | Discord controls |
| 5 | Softmax |

Choosing a destination opens that page and closes navigation. Only the top
row changes while navigation is open: keys 6–15 keep their current actions and
images. Opening or closing Menu never launches an application, changes OBS's
selected capture, resizes a window, or starts a recording. Covered controls do
not fire. The mixer and its navigation remain independent. Home is an explicit
destination inside Menu. Choosing a drawer destination jumps directly there
and clears Deck navigation history without discarding MIDI navigation history.

With navigation closed, keys 2–5 belong to the current workflow. There is no
permanent global menu row. Home provides one entry each for OBS, Discord,
and Softmax. Purple **MENU** faces navigate; **OPEN OBS** launches/focuses the
app; **Minecraft/WoW/Firefox SETUP** selects recording sources and the shared
profile; **1080** changes that application's client-window size.

## OBS controls

All requested recording and setup controls are on this one page:

| Row | 1st key | 2nd key | 3rd key | 4th key | 5th key |
| --- | --- | --- | --- | --- | --- |
| 1 | MENU | Open OBS | Record/Stop | Pause/Resume | Commentary mic |
| 2 | Minecraft Setup | WoW Setup | Firefox Setup | spare | spare |
| 3 | Minecraft 1080p | WoW 1080p | Firefox 1080p | spare | spare |

The setup and resize keys are aligned by application. There is no extra SETUP
submenu or separate ambiguous Firefox OPEN face. The Firefox 1080p action can
open the dedicated demo window when it is closed; it never chooses a personal
Firefox window. Record/Stop follows the scene explicitly selected in OBS.
Managed scene capture checks and the recording/streaming guards still apply.

## Other workflows

Discord uses keys 2 System mic, 3 Discord mic, 4 Deafen, 5 Open Discord,
6 Answer voice, 7 Answer video, 8 Softmax menu, and 9 OBS controls.

Softmax uses keys 2 Prism, 3 WoW Vanilla, 4 WoW Nim, 5 Open Discord, 6 Slack,
7 Autoresearch, 8 Fast-XP Prod, 9 Fast-XP Staging, 10 Next Games,
11 WoW Dashboard, 12 Start WoW Server, 13 Discord menu, and 14 OBS controls.
Their existing actions, launch commands, media states, and private-world
identity are preserved. See [Softmax](work.md) and [Discord](discord.md).

## Configuration and installation

The navigation destinations live in the shared JSON configuration as the
`deck-navigation` menu. The `deckMenu` action opens that menu as a temporary
top-row overlay, using existing prepared menu artwork. It does not add a
navigation-history entry or a new desktop window.

After installing the base workflow menus and Knobby, apply the layout through
the normal revision-checked configuration API:

```sh
nix develop --command nim r tools/setup_workflow_layout.nim --apply
```

The tool preserves unrelated actions, command targets, mixer bindings, and
editor drafts. It refuses overflow or ambiguous custom bindings before applying
anything. A completed layout is left alone on later runs. The older
`setup_navigation.nim --apply` entrypoint delegates to this current layout;
the historical four-key-prefix migration is no longer the installed behavior.

The desktop viewer must run the current version to render temporary navigation
and edit its action. Installation leaves an existing viewer and its drafts
running. Load the updated viewer once by choosing **Quit viewer** from its tray,
then reopening **Knobby**. Physical Deck controls run in the daemon independently.

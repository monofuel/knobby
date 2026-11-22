# Buttons, menus, and artwork

Knobby's editor and command-line tools share one JSON configuration. The daemon
owns the active configuration, button routing, and device displays; the editor
can close without interrupting them. Faders, audio targeting, and mousepad
lighting retain their existing behavior.

## Edit in the app

Open the button editor, select a menu and device, and select a button. Selection
inspects or edits that button; it does not execute its action. Change its title,
choose an existing helper or custom command, or make it open another menu.
Choose whether a menu action affects the mixer, the Stream Deck, or both.

Choosing a menu that has bindings on only one device selects that device's grid
automatically. You can still choose the other device explicitly; its empty
slots are genuinely unassigned, rather than copies of the other device's keys.

Buttons marked **Custom logic** retain their working integration action. Their
action chooser and command editor are unavailable, while their title and Stream
Deck images remain editable. This includes the Spotify helpers and specialized
Prism/WoW launchers. Ordinary commands and empty slots remain assignable.
The shared button entry records this as `"customLogic": true`; intentional
implementation changes remain possible through JSON or AI edits. An unknown
action in a recovered draft is also shown as custom instead of being mistaken
for None, and cannot be silently overwritten by the action chooser.

Save & Apply validates the whole draft and prepares its artwork before changing
the live controls. Preparation, validation, or save failures keep the working
configuration and your draft. Another editor's saved changes cause a revision
conflict instead of silently overwriting them. Reload the latest configuration
and reapply your changes; the displaced draft remains recoverable.

The editor remembers unfinished work under the user state directory. Viewing or
editing a menu is separate from switching the physical devices into that menu.

## Menus and temporary navigation

Mixer buttons use MIDI note numbers 1–12 in their physical arrangement. Stream
Deck keys use numbers 1–15, left to right, top to bottom. The installed Deck
submenus keep **HOME at key 1** and **MENU at key 5**. Menu reveals OBS,
Discord, and Softmax on keys 2–4; press again to restore that page's controls.
Selecting a destination closes the row automatically. Home and the lower
keys keep their actions and artwork while the row is open.
Home already shows the workflow destinations at the same keys 2–4, with a
non-action Home indicator at key 1 and no Menu button.
Unused Home keys 7–15 are blank; assigning an action or a custom image preserves
that button when the workflow layout is refreshed.

Every submenu reserves button 1 for navigation. The mixer uses Back at its
bottom-right; the installed Deck uses `deckMenu` at key 5. Its `menu` field
references the editable `deck-navigation` menu, whose first five keys supply
the overlay artwork and destinations. This uses the same configuration and
managed image pipeline as other buttons. Home inside that row is a Deck-only
link to the configured root and clears only the Deck's history. Legacy Back
and Home configurations, including the earlier key-1 drawer, remain supported. Drawer destinations jump directly
to a workflow without stacking Back history; MIDI history is retained.

Back restores the previous menu on the device where you press it. If that
transition switched both devices, Back restores both together. For example:

- Open Tools on both devices: both switch to Tools.
- Open Games on the Deck only: the mixer stays in Tools.
- Back on the Deck returns it to Tools. Back again restores the previous pair.
- Back on the mixer while the Deck is in Games restores the previous pair and
  removes that dependent Games navigation too.

Home returns to the top-level menus. A successful configuration application
also returns both devices to their roots. Held keys must be released before
they can act on a newly displayed menu.

## Images and animation

Stream Deck buttons accept PNG and JPEG images or animated GIFs. Import copies
the source into Knobby's managed assets, so moving the original does not break
the button. An optional title can appear over the artwork. Artwork fits
proportionally onto a black square; the preview uses the actual prepared device
frames, displayed upright.

Animations loop only while their menu is active. The device player skips late
frames instead of building a backlog that delays input. A pressed appearance
temporarily overrides an animation while the button is held.

Imports are limited to 20 MiB, 4096×4096 source pixels, and 30 seconds/900
prepared frames per animation, with a maximum 30 FPS and 128 MiB of prepared
frames per configuration. These are software resource limits, not promises of
USB throughput. Unsupported or oversized imports produce a preparation error
without replacing the working configuration.

Each import or preparation has a 90-second overall deadline. Old prepared
artwork is reclaimed after successful operations once no retained manifest
references it and it has been unused for an hour. Imported source assets and
drafts remain available.

## Edit with a text editor or AI

The command-line workflow exports the same draft document the GUI uses:

```sh
knobby config export /tmp/knobby-buttons.json
# Edit the config field, retaining baseRevision.
knobby config validate /tmp/knobby-buttons.json
knobby config validate --prepare /tmp/knobby-buttons.json
knobby config apply /tmp/knobby-buttons.json
```

Validation alone does not change the devices. `--prepare` additionally checks
and prepares artwork. Apply rejects an outdated `baseRevision`; export a fresh
document and reapply the intended edit instead of forcing an overwrite.

Import artwork before referencing its managed path:

```sh
knobby config import-asset /path/to/artwork.gif
```

The returned operation includes a relative `assets/...` path. A Deck button's
`visual.image` references that path. For example, this button opens Tools on
both devices:

```json
{
  "key": 2,
  "title": "Tools",
  "action": {"kind": "menu", "menu": "tools", "target": "both"}
}
```

Configurations have `version`, `root`, and a `menus` array. Each menu has a
stable `id`, a title, and `mixer` and `deck` button arrays. Each button identifies
its physical `key`, title, and action. Use an exported configuration as the
starting point; defaults retain the existing desktop helpers and numbered Deck.

## Storage and recovery

The canonical file is `$XDG_CONFIG_HOME/knobby/buttons.json`, normally
`~/.config/knobby/buttons.json`, with imported sources in its `assets/` directory.
Prepared media, the last applied configuration, and GUI drafts live under
`$XDG_STATE_HOME/knobby`, normally `~/.local/state/knobby`.

At startup Knobby tries the canonical configuration, then the last applied
configuration, then the compiled defaults. Invalid input never overwrites a
working configuration automatically. Use export/edit/apply for normal changes;
there is no automatic watcher applying partially written editor files.

The installer updates the daemon without launching or restarting desktop
windows. If an editor/protocol update requires reopening, choose **Quit viewer**
from the tray and run `~/.local/bin/knobby-gui`. Your saved configuration and
recoverable draft remain on disk.

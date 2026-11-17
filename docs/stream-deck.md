# Elgato Stream Deck

Hardware notes for monofuel's Stream Deck and its possible use with Knobby.
The daemon controls its numbered key images and brightness directly through
Linux hidraw. Its buttons remain separate from the Arduino bindings.

## Our Device

| Detail | Status |
|--------|--------|
| Model / generation | Stream Deck MK.2, as reported over USB. |
| Key count and layout | 15 keys, 3 rows by 5 columns; labels 1–15 run left-to-right, top-to-bottom. |
| Key image size | 72×72 JPEG, rotated 180° before upload. |
| USB vendor and product IDs | `0fd9:0080`. |
| HID interfaces | One interface, bound to `hid-generic`. |
| Firmware | Not yet queried; USB device revision is not a firmware readout. |
| Linux behavior | Enumerates at 480 Mb/s; direct hidraw access is available to the desktop user. |

The Stream Deck family includes devices with different layouts,
displays, and additional controls.

## Linux Support

Elgato's [product FAQ](https://www.elgato.com/us/en/p/stream-deck) says its
Stream Deck software supports Windows and macOS, with Linux unsupported.
However, Elgato publishes an official
[USB HID API](https://docs.elgato.com/streamdeck/hid/intro/) for direct hardware
communication. Lack of the desktop application does not prevent us from
investigating the device on Linux.

Support information checked on 2026-11-15.

## How It Communicates

Stream Deck hardware communicates over USB HID. At a high level:

| Direction | Purpose |
|-----------|---------|
| Device to host | Input reports describe control state changes, such as key presses. |
| Host to device | Output reports transfer display content such as key images. |
| Host to/from device | Feature reports handle settings and information such as brightness and firmware. |

Elgato's [main protocol reference](https://docs.elgato.com/streamdeck/hid/general/)
describes the report families and image transfer. Model-specific documentation
determines the actual report layout, image format, dimensions, and orientation;
the main protocol must not be assumed to apply to every older model.

The [MK.2 protocol reference](https://docs.elgato.com/streamdeck/hid/stream-deck-classic/)
covers this device's layout and image orientation. Knobby's module uses
Linux's existing HID driver and hidraw interface; HIDAPI and another device
daemon are not required.

## Numbered-Key Demo

From the checkout:

```sh
systemctl --user stop knobby
nix develop --command nim r examples/stream_deck.nim
```

The demo sets 30% brightness and displays white numbers on black. Holding a
key changes it to black text on light grey; releasing it restores the normal
image. The terminal logs presses and releases using the displayed numbers,
including simultaneous keys.

Device discovery follows USB identity rather than a fixed `/dev/hidrawN`
number. The demo waits if the deck is absent and redraws the page after a
reconnect. The desktop user's current seat ACL provides read/write access
on high-steel. Permission failures are reported without changing udev rules.
Ctrl+C restores the Elgato logo and closes the device.

The 30 prepared JPEGs are embedded into the demo. To regenerate them, use
`nim r examples/generate_stream_deck_assets.nim` with FFmpeg, fontconfig's
`fc-match`, and DejaVu Sans Bold installed. These are asset-generation tools,
not runtime dependencies.

The daemon runs the same numbered page automatically. Standalone display tools
reject a second writer. Restart `knobby.service` after diagnostics to restore
normal device handling. Future bindings and animations remain unassigned.

## JPEG Compatibility Checks

Physical checks on this MK.2 (`0fd9:0080`) on 2026-11-15, using FFmpeg
8.1.3, 72×72 baseline JPEGs, 180° rotation and `-q:v 2`:

| FFmpeg pixel format | Huffman setting | Display result |
|---------------------|-----------------|----------------|
| `yuvj444p` (4:4:4) | `optimal` | No number displayed. |
| `yuvj444p` (4:4:4) | `default` | No number displayed. |
| `yuvj420p` (4:2:0) | `optimal` | Number displayed. |
| `yuvj420p` (4:2:0) | `default` | Number displayed. |

The demo assets use `yuvj420p` with `-huffman optimal`. Optimized Huffman
tables work; switching to standard tables was unnecessary. The complete
numbered demo and press/release highlights were also physically confirmed.

These results describe files from this encoder on this device. They do not
establish that every possible 4:4:4 JPEG is unsupported. In particular,
FFmpeg's failing files use sampling factors `0x12` for all three components;
other encoders may encode 4:4:4 differently. Other encoders, 4:2:2, grayscale
and progressive JPEGs have not been tested. The transport accepts prepared
JPEG bytes without restricting sampling or Huffman tables.

Elgato's [image-upload documentation](https://docs.elgato.com/streamdeck/hid/stream-deck-classic/#uploading-images)
specifies JPEG dimensions and rotation, but does not state these encoding
restrictions. The table above is an observation, not an Elgato guarantee.

To repeat the four-way hardware check, stop the numbered demo and run:

```sh
nim r examples/stream_deck_jpeg_probe.nim
```

This needs the asset-generation tools listed above. It clears all keys to
a working black JPEG before uploading variants 1–4 to the first four keys
of the top row in table order. Rejected images therefore cannot leave an
old number visible. Presses are logged without replacing the probe images.
Ctrl+C restores the logo; restart the numbered demo afterward.

# Elgato Stream Deck

Hardware notes for monofuel's Stream Deck and its possible use with Knobby.
The device enumerates on high-steel. Button handling and display updates have
not been tested yet.

## Our Device

| Detail | Status |
|--------|--------|
| Model / generation | Stream Deck MK.2, as reported over USB. |
| Key count and layout | Not yet recorded. |
| USB vendor and product IDs | `0fd9:0080`. |
| HID interfaces | One interface, bound to `hid-generic`. |
| Firmware | Not yet queried; USB device revision is not a firmware readout. |
| Linux behavior | Enumerates at 480 Mb/s; button and display control remain untested. |

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

For Knobby, the useful split is receiving button state and updating the
display to reflect an action or state. The existing Arduino sends MIDI;
the Stream Deck would need its own input and display handling. No transport
library or integration approach has been selected.

## First Connection

1. Record the model label, controls, and USB vendor/product IDs from `lsusb`.
2. Inspect the USB interfaces, HID report descriptor, corresponding
   `/dev/hidraw*` nodes, and access permissions for the desktop user.
3. Match the device to the appropriate protocol reference and capture a
   press and release from each control to establish its physical mapping.
4. Test a single key image and brightness adjustment, then observe what
   happens when the controlling process exits or the device reconnects.

Record observations here as they become available. Initial questions are
which actions belong on it and what feedback its displays should show.

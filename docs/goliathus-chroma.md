# Razer Goliathus Chroma

Hardware notes for monofuel's RGB mousepad and its possible use with Knobby.
The device identifies as a Goliathus Extended Chroma on high-steel. It
enumerates successfully and supports grey breathing through OpenRazer.

## Our Device

| Detail | Status |
|--------|--------|
| Variant | Razer Goliathus Extended Chroma, as reported over USB. |
| Physical size / model label | Not yet recorded. |
| USB vendor and product IDs | `1532:0c02`. |
| HID interfaces | Three interfaces, bound to OpenRazer's `razeraccessory` driver. |
| Firmware | Not yet queried. |
| Lighting zones | OpenRazer reports a 1×1 matrix: one RGB zone for the whole edge. |
| Startup lighting and retained settings | Not yet observed. |
| Linux lighting control | OpenRazer D-Bus accepts brightness and two-color breathing commands. |

The Goliathus name covers several variants. OpenRazer's
[supported-device list](https://openrazer.github.io/#devices) identifies:

| Variant | USB vendor:product ID |
|---------|-----------------------|
| Goliathus | `1532:0c01` |
| Goliathus Extended | `1532:0c02` |
| Goliathus Chroma 3XL | `1532:0c06` |

Our mousepad matches the Extended variant's `1532:0c02` ID.

## Linux Support

Razer's [Synapse download page](https://www.razer.com/synapse-4) lists Windows
and a Mac preview, with no native Linux download. It also offers Synapse Web
for selected devices; compatibility with our mousepad has not been established.

[OpenRazer](https://openrazer.github.io/) is a community Linux implementation
that lists the Goliathus variants above. Its stack includes a kernel driver
and a userspace daemon. The existing `razeraccessory` kernel driver binds to
our mousepad automatically. No additional software has been installed for
this investigation. Its existing user daemon exposes lighting control over
D-Bus, which Knobby accesses with `busctl`.

Support information checked on 2026-11-15.

## How It Communicates

The mousepad's USB connection provides a lighting-control interface.
OpenRazer matches these models as USB HID devices and sends Razer-specific
lighting commands for effects and brightness. This gives us a starting point
for understanding the protocol without depending on the Synapse application.
See its [accessory driver](https://github.com/openrazer/openrazer/blob/dfe987c8b2053f1c111117ea20163cdb2a07f893/driver/razeraccessory_driver.c)
and [device ID definitions](https://github.com/openrazer/openrazer/blob/dfe987c8b2053f1c111117ea20163cdb2a07f893/driver/razeraccessory_driver.h).

Knobby uses lighting output; no input controls are bound for this device.
Persistence across power loss and the visual appearance of other effects
still need testing.

## MVP: Subtle Grey Breathing

The initial lighting alternates grey breathing pulses across the whole edge:
some illumination without bright colors or a distracting effect. It uses
`#484848` and `#606060` at 25% brightness.

The existing OpenRazer daemon selects the mousepad's native two-color
breathing effect; Knobby does not continuously animate colors. Each color
fades up from black and returns to black before the next color's pulse.
The two colors set pulse colors, not a minimum and maximum for a continuous
fade. Breathing speed is controlled by the firmware. Monofuel accepts this
appearance for the MVP.

Knobby applies the preset on startup, when it sees the mousepad reconnect,
and when the OpenRazer daemon restarts. Lighting runs independently of MIDI
and audio processing, and retries unavailable OpenRazer connections. Other
Razer devices keep their existing lighting.

## Future Idea: Microphone State Indicator

Use the illuminated edge to show whether the microphone is muted, with
distinct steady colors for muted and unmuted states. The exact colors,
brightness, and whether to follow system microphone mute or Discord self-mute
are still undecided. This is an idea, not an implemented feature.

## First Connection

1. Record the model label, size, and USB vendor/product IDs from `lsusb`.
2. Observe the default lighting before any control software takes ownership.
3. Inspect USB interfaces, the bound kernel driver, HID nodes, and user access
   permissions; match the device to the upstream implementation.
4. Test a static color, brightness, and off setting. Record whether those
   settings survive process exit, unplug/replug, and suspend/resume.

Record verified capabilities here as the grey breathing MVP is tested.

# Knobby Hardware

The controller is an Arduino Micro built from a basic 3D-printed "MIDI mixer"
kit. It has 12 buttons (classic Cherry switches) and 4 audio faders (standard
cheap sliding potentiometers). It shows up on ALSA as a sequencer client named
`Arduino Micro` (e.g. `client 36: 'Arduino Micro'`, port `36:0`).

All events are sent on MIDI channel 0.

## Board Variants

Several of these mixers were built. Some units came with cheap Arduino
knock-off boards that are physically Arduino Micros but shipped with Arduino
Leonardo firmware, so they enumerate over USB (and in ALSA client names) as
`Arduino Leonardo` instead of `Arduino Micro`. This makes no practical
difference; the boards work identically for this device.

Auto-detection in `src/knobby/midi_monitor.nim` matches any client name
containing `arduino` (case-insensitive), so both the `Arduino Micro` and
`Arduino Leonardo` variants are detected.

## Buttons

The buttons are a 3x4 grid of Cherry switches. Each button sends a Note On at
velocity 127 when pressed and a matching Note Off on release. Note numbers map
to the physical grid like this:

|            | Col 1 | Col 2 | Col 3 | Col 4 |
|------------|-------|-------|-------|-------|
| Top row    | 12    | 9     | 6     | 3     |
| Middle row | 11    | 8     | 5     | 2     |
| Bottom row | 10    | 7     | 4     | 1     |

Columns count down top-to-bottom, and note 1 is the bottom-right corner.

## Faders

The 4 sliding potentiometers send Control Change messages, left to right:

| Fader | CC number | Range              |
|-------|-----------|--------------------|
| 1     | 16        | 0 (0 vol) - 127 (max vol) |
| 2     | 17        | 0 (0 vol) - 127 (max vol) |
| 3     | 18        | 0 (0 vol) - 127 (max vol) |
| 4     | 19        | 0 (0 vol) - 127 (max vol) |

Faders report absolute position. Fast movements skip intermediate values, so
consumers should treat each CC value as the current position rather than
counting steps.

## Reference Capture

`docs/example_out.txt` is a full capture of every button press and full up/down
sweeps of all 4 faders, recorded with the monitor example:

```
nim r examples/midi_monitor.nim -- --auto
```

# Knobby

- Linux MIDI controller daemon.

## Development

- Run tests: `nimble test`
- Run the app scaffold: `nimble run`

## MIDI Monitor Demo

- List available ALSA MIDI ports: `nim r examples/midi_monitor.nim -- --list`
- Auto-detect Arduino Micro and monitor: `nim r examples/midi_monitor.nim`
- Explicit auto-detect mode: `nim r examples/midi_monitor.nim -- --auto`
- Start monitor with explicit port: `nim r examples/midi_monitor.nim -- 20:0`

## Audio Outputs Demo

- List active audio outputs with app names and volumes: `nim r examples/audio_outputs.nim`

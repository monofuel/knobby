# Knobby

- Linux MIDI controller daemon.
- Focus: stable background service behavior and predictable MIDI event handling.
- Currently hard-coded for monofuel's desktop (high-steel) by design: see the
  Scope section in README.md and docs/high-steel.md. Do not add configuration
  systems.
- Hardware is an Arduino Micro MIDI mixer documented in docs/hardware.md:
  12 buttons (notes 1-12) and 4 faders (CC 16-19).
- Faders drive PipeWire volumes through pactl; buttons launch apps. All
  bindings are consts in src/knobby/actions.nim.

## Layout

- `src/knobby.nim` - daemon entrypoint: detect the Arduino, dispatch event
  batches, reconnect on disconnect.
- `src/knobby/midi_monitor.nim` - aseqdump wrappers: port detection, per-line
  and batched sessions. Batches coalesce fader bursts so the last value wins.
- `src/knobby/midi_events.nim` - parse aseqdump output lines into MidiEvent.
- `src/knobby/actions.nim` - bindings, fader endpoint snap and deadband,
  pactl volume calls, detached app launchers.
- `src/knobby/audio_outputs.nim` - pactl sink-input listing.
- `examples/` - midi_monitor and audio_outputs demos (see README.md).
- `docs/example_out.txt` - real capture of every button and fader; the
  reference for parser behavior and test cases.

## Dependencies

- Nim >= 2.0.0, standard library only (no package dependencies).
- External command-line tools, all provided by the flake dev shell
  (`nix develop`): aseqdump and aconnect (alsa-utils), pactl (pulseaudio),
  wmctrl, curl. There is no C library linkage; everything shells out.

## Tests

- Run `nimble test` to run all tests
- Individual test files can be run individually `nim r tests/test_*.nim`
- Unit tests must not call pactl, launch apps, or need the hardware. Test
  pure logic (parsing, fader math, coalescing) against lines from
  docs/example_out.txt.

## Systemd User Service

The daemon runs as a systemd user service. The reference copy is
`docs/knobby.service`; the live copy is `~/.config/systemd/user/knobby.service`.

- After code changes: `systemctl --user restart knobby`. ExecStart runs
  `nim r` inside `nix develop`, so a restart recompiles automatically.
- After editing the service file, update the live copy from the repo copy:

```
cp docs/knobby.service ~/.config/systemd/user/knobby.service
systemctl --user daemon-reload
systemctl --user restart knobby
```

- Logs: `journalctl --user -u knobby -f`
- Never edit the live copy directly; edit docs/knobby.service and copy it, so
  the repo copy stays the source of truth.

## Nim

## Nim best practices

**Prefer letting errors bubble up naturally** - Nim's stack traces are excellent for debugging:

Default approach - let operations fail with full context:
```nim
# Simple and clear - if writeFile fails, we get a full stack trace
writeFile(filepath, content)

# Database operations - let them fail with complete error information
db.exec(sql"INSERT INTO users (name) VALUES (?)", username)
```

For validation and early returns, check conditions explicitly:
```nim
# Check preconditions and exit early with clear messages
if not fileExists(parentDir):
  error "Parent directory does not exist"
  quit(1)

if username.len == 0:
  error "Username cannot be empty"
  quit(1)

# Now proceed with the operation
writeFile(filepath, content)
```

This approach ensures full stack traces in CI environments and makes debugging straightforward.

### Nim Imports

- std imports should be first, then libraries, and then local imports
- use [] brackets to group when possible
- split imports on newlines
for example,
```
import
  std/[strformat, strutils],
  debby/[pools, postgres],
  ./[models, logs, llm] 
```

### Nim Procs

- do not put comments before functions! comments go inside functions.
- every proc should have a nimdoc comment
- nimdoc comments start with ##
- nimdoc comments should be complete sentences followed by punctuation
for example,
```
proc sumOfMultiples(limit: int): int =
  ## Calculate the sum of all multiples of 3 or 5 below the limit.
  var total = 0
  for i in 1..<limit:
    if i mod 3 == 0 or i mod 5 == 0:
      total += i
  return total
```

### Nim Properties

- if an object property is the same name as a nim keyword, you must wrap it in backticks
```
  DeleteModelResponse* = ref object
    id*: string
    `object`*: string
    deleted*: bool
```

### Variables

- please group const, let, and var variables together.
- please prefer const over let, and let over var.
- please use capitalized camelCase for consts
- use regular camelcase for var and let
- do not place 'magic variables' in the code, instead make them a const and pull them up to the top of the file
- for example:

```
const
  Version = "0.1.0"
  Model = "llama3.2:1b"
let
  embeddingModel = "nomic-embed-text"
```

## Programming

- Don't use try/catch unless you have a very, very good reason to be handling the error at this level.
- never mask errors with catch: discard
- it's OK to allow errors to bubble up. we want things to be easy to debug and fail fast.
- returning in the middle of files is confusing, avoid doing it.
  - early returns at the start of the file is ok.
- try to make things as idempotent as possible. if a job runs every day, we should make sure it can be robust.
- never use booleans for 'success' or 'error'. If a function was successful, return nothing and do not throw an error. if a function failed, throw an error.

### Comments

- functions should have doc comments
- however code should otherwise not need comments. functions should be named properly and the code should be readable.
- comments may be ok for 'spooky at a distance' things in rare cases.
- comments should be complete sentences that are followed with a period.

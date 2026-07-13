import
  std/strutils

type
  MidiEventKind* = enum
    NoteOn, NoteOff, ControlChange, OtherEvent

  MidiEvent* = object
    kind*: MidiEventKind
    note*: int
    velocity*: int
    controller*: int
    value*: int

proc numberAfter(line, marker: string): int =
  ## Parse the integer immediately following a marker in a line, or -1.
  result = -1
  let index = line.find(marker)
  if index >= 0:
    var digits = ""
    var i = index + marker.len
    while i < line.len and line[i].isDigit:
      digits.add(line[i])
      inc(i)
    if digits.len > 0:
      result = parseInt(digits)

proc parseMidiEvent*(line: string): MidiEvent =
  ## Parse one aseqdump output line into a MidiEvent.
  result = MidiEvent(kind: OtherEvent)
  if line.contains("Note on"):
    result = MidiEvent(
      kind: NoteOn,
      note: numberAfter(line, "note "),
      velocity: numberAfter(line, "velocity ")
    )
  elif line.contains("Note off"):
    result = MidiEvent(
      kind: NoteOff,
      note: numberAfter(line, "note "),
      velocity: numberAfter(line, "velocity ")
    )
  elif line.contains("Control change"):
    result = MidiEvent(
      kind: ControlChange,
      controller: numberAfter(line, "controller "),
      value: numberAfter(line, "value ")
    )

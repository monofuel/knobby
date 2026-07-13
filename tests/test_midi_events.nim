import
  std/unittest,
  knobby/midi_events

suite "parseMidiEvent":
  test "parses note on from a real capture line":
    let event = parseMidiEvent(" 36:0   Note on                 0, note 10, velocity 127")
    check event.kind == NoteOn
    check event.note == 10
    check event.velocity == 127

  test "parses note off from a real capture line":
    let event = parseMidiEvent(" 36:0   Note off                0, note 3, velocity 127")
    check event.kind == NoteOff
    check event.note == 3

  test "parses control change from a real capture line":
    let event = parseMidiEvent(" 36:0   Control change          0, controller 16, value 126")
    check event.kind == ControlChange
    check event.controller == 16
    check event.value == 126

  test "parses a zero value":
    let event = parseMidiEvent(" 36:0   Control change          0, controller 19, value 0")
    check event.kind == ControlChange
    check event.value == 0

  test "ignores aseqdump preamble lines":
    check parseMidiEvent("Waiting for data. Press Ctrl+C to end.").kind == OtherEvent
    check parseMidiEvent("Source  Event                  Ch  Data").kind == OtherEvent
    check parseMidiEvent("Auto-detected Arduino sequencer port: 36:0").kind == OtherEvent
    check parseMidiEvent("").kind == OtherEvent

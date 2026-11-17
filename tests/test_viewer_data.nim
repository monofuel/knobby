import
  std/[json, os, sequtils, strutils, unittest],
  knobby/[audio_status, bindings, daemon_workers, ipc, midi_events, status],
  ../gui/app/src/observers

proc audioFixture(): JsonNode =
  ## Build a local pactl-shaped fixture without accessing a running audio server.
  %*{
    "sinks": [{"name": "bose", "description": "Bose", "mute": false,
      "volume": {"front-left": {"value_percent": "72%"}, "front-right": {"value_percent": "65%"}}}],
    "sink_inputs": [
      {"properties": {"application.name": "Firefox", "application.process.id": "123"}, "mute": false,
        "volume": {"front-left": {"value_percent": "25%"}}},
      {"properties": {"application.name": "Firefox", "application.process.id": "124"}, "mute": true,
        "volume": {"front-left": {"value_percent": "40%"}}},
      {"properties": {"application.name": "Example", "media.role": "game"}, "mute": false, "volume": {}},
      {"properties": {"application.name": "FINAL FANTASY XIV"}, "mute": false, "volume": {}}],
    "sources": [
      {"name": "benq", "description": "BenQ", "mute": true, "volume": {}},
      {"name": "webcam", "description": "Webcam", "mute": false, "volume": {}},
      {"name": "bose.monitor", "description": "Output monitor", "mute": false, "volume": {}}]}

suite "Read-only viewer bindings":
  test "the physical grid contains every note exactly once":
    var notes: seq[int]
    for row in ButtonGrid:
      for note in row: notes.add(note)
    check notes.deduplicate().len == 12
    check ButtonGrid[0] == [12, 9, 6, 3]
    check ButtonGrid[2] == [10, 7, 4, 1]
    check buttonBinding(8).action == ToggleDiscord
    check buttonBinding(11).action == ToggleMicrophones
    check buttonBinding(1).action == Unassigned
    check bindingCatalog()["buttons"].len == 12
    check bindingCatalog()["faders"].len == 4

suite "Daemon viewer status":
  test "status fixtures encode an empty button configuration as an object":
    let encoded = encodeSnapshot(emptyMixer(), "fixture", 1000)
    check parseJson(encoded)["buttonConfig"].kind == JObject
    check decodeSnapshot(encoded).buttonConfig.kind == JObject

  test "positions start unknown and independent held notes are observed":
    var state = emptyMixer()
    check state.faders == [-1, -1, -1, -1]
    state.applyMidi(MidiEvent(kind: NoteOn, note: 12, velocity: 127), 1000)
    state.applyMidi(MidiEvent(kind: NoteOn, note: 1, velocity: 127), 1010)
    state.applyMidi(MidiEvent(kind: NoteOff, note: 12), 1020)
    check not state.held[11]
    check state.held[0]
    check state.lastPressMs[11] == 1000
    check buttonLit(state.held[11], state.lastPressMs[11], 1100)
    check not buttonLit(false, state.lastPressMs[11], 1200)
    state.applyMidi(MidiEvent(kind: NoteOn, note: 1, velocity: 0), 1030)
    check not state.held[0]
    state.applyMidi(MidiEvent(kind: ControlChange, controller: 17, value: 95), 1040)
    check state.faders == [-1, 95, -1, -1]
    check state.faderObserved == [false, true, false, false]

  test "restart and connection boundaries keep positions and clear transient input":
    initializeState("restored", [49, 127, -1, 10])
    check readFaderPositions() == [49, 127, -1, 10]
    check readKnobbyState().mixer.faderObserved == default(array[4, bool])
    setMixerPort("32:0")
    observeMidi([MidiEvent(kind: ControlChange, controller: 16, value: 49),
      MidiEvent(kind: NoteOn, note: 1, velocity: 127)])
    check readKnobbyState().mixer.faderObserved == [true, false, false, false]
    check readKnobbyState().mixer.held[0]
    setMixerPort("")
    let disconnected = readKnobbyState().mixer
    check disconnected.faders == [49, 127, -1, 10]
    check disconnected.faderObserved == default(array[4, bool])
    check disconnected.held == default(array[12, bool])
    check disconnected.lastPressMs == default(array[12, int64])
    setMixerPort("37:0")
    check readFaderPositions() == [49, 127, -1, 10]

  test "invalid and unrelated input cannot change physical state":
    var state = emptyMixer()
    for event in [MidiEvent(kind: NoteOn, note: 0, velocity: 127),
        MidiEvent(kind: NoteOn, note: 13, velocity: 127),
        MidiEvent(kind: ControlChange, controller: 16, value: 128),
        MidiEvent(kind: ControlChange, controller: 20, value: 50),
        MidiEvent(kind: OtherEvent)]:
      state.applyMidi(event, 1000)
    check state == emptyMixer()

  test "round trip, restart identity and stale heartbeat":
    var state = emptyMixer()
    state.port = "36:0"
    state.applyMidi(MidiEvent(kind: NoteOn, note: 9, velocity: 127), 100)
    let first = decodeSnapshot(encodeSnapshot(state, "first", 200))
    check first.mixer == state
    check isFresh(200, 210)
    check not isFresh(200, 2201)
    check not isFresh(200, 199)
    let restarted = decodeSnapshot(encodeSnapshot(emptyMixer(), "second", 300))
    check restarted.session != first.session
    check restarted.mixer.port.len == 0
    check restarted.mixer.held == default(array[12, bool])
    check restarted.mixer.faders == [-1, -1, -1, -1]

  test "malformed arrays and incompatible versions are rejected":
    var node = parseJson(encodeSnapshot(emptyMixer(), "test", 100))
    node["version"] = %99
    expect ValueError: discard decodeSnapshot($node)
    node["version"] = %StatusVersion
    node["mixer"]["held"] = %*[false]
    expect ValueError: discard decodeSnapshot($node)
    expect JsonParsingError: discard decodeSnapshot("{")

  test "older snapshots default to last-known and malformed flags are rejected":
    var node = parseJson(encodeSnapshot(emptyMixer(), "legacy", 100))
    node["mixer"].delete("faderObserved")
    check decodeSnapshot($node).mixer.faderObserved == default(array[4, bool])
    for flags in [%*[false], %*[false, false, 0, false], newJNull()]:
      node["mixer"]["faderObserved"] = flags
      expect ValueError: discard decodeSnapshot($node)

  test "initial socket snapshot shows existing knob positions without new movements":
    var mixer = emptyMixer()
    mixer.port = "32:0"
    mixer.faders = [49, 127, -1, -1]
    let snapshot = decodeSnapshot(encodeSnapshot(mixer, "daemon", 99999999))
    let state = viewerState(snapshot)
    check state.faderPosition(0) == 49
    check state.faderPosition(1) == 127
    check state.faderPosition(2) == -1
    check isFresh(100, 101)

  test "captions distinguish remembered and observed positions through disconnects":
    var snapshot = decodeSnapshot(encodeSnapshot(emptyMixer(), "captions", 100))
    snapshot.mixer.faders = [49, -1, 127, 0]
    var state = viewerState(snapshot)
    check state.faderCaption(0) == "Last known 49"
    check state.faderCaption(1) == "Not observed"
    state.snapshot.mixer.port = "32:0"
    state.snapshot.mixer.applyMidi(MidiEvent(kind: ControlChange, controller: 16, value: 49), 101)
    check state.faderCaption(0) == "MIDI 49"
    check state.faderCaption(2) == "Last known 127"
    state.mixerError = "Daemon unavailable"
    check state.faderPosition(0) == 49
    check state.faderCaption(0) == "Last known 49"
    check state.faderPosition(1) == -1

suite "Actual audio observations":
  test "default output preserves differing channel levels and microphone mute":
    let audio = parseAudioStatus($audioFixture(), "bose\n")
    check audio.master.name == "Bose"
    check audio.master.channels == @["front-left 72%", "front-right 65%"]
    check audio.microphones.len == 2
    check audio.microphones[0].muted
    check not audio.microphones[1].muted
    check audio.streams[1].muted
    check "muted" in audio.streams[1].levelText()
    check AudioLevel(name: "Microphone").levelText() == "Volume unavailable"

  test "multiple browser streams and the game's matching rules remain distinct":
    let audio = parseAudioStatus($audioFixture(), "bose")
    check audio.streams.filterIt(it.matchesFader(17, false)).len == 2
    check audio.streams.filterIt(it.matchesFader(18, false)).len == 0
    check audio.streams.filterIt(it.matchesFader(19, false)).len == 2
    check audio.streams[0].matchesFader(19, true)
    check not audio.streams[0].matchesFader(18, true)

  test "empty audio servers and malformed output":
    check parseAudioStatus("{\"sinks\":[],\"sink_inputs\":[],\"sources\":[]}", "missing").master.levelText() == "Unavailable"
    expect JsonParsingError: discard parseAudioStatus("invalid", "bose")

suite "Independent action execution":
  test "pending faders coalesce while buttons preserve their press order":
    var queue = emptyActions()
    queue.enqueue([MidiEvent(kind: NoteOn, note: 11),
      MidiEvent(kind: ControlChange, controller: 16, value: 30),
      MidiEvent(kind: NoteOn, note: 8),
      MidiEvent(kind: ControlChange, controller: 16, value: 90)])
    let events = queue.drain()
    check events.len == 3
    check events[0].note == 11
    check events[1].note == 8
    check events[2].value == 90
    check queue.drain().len == 0

  test "a full button queue is reported instead of growing without limit":
    var queue = emptyActions()
    for _ in 0..<MaxPendingButtons: queue.enqueue([MidiEvent(kind: NoteOn, note: 1)])
    expect IOError: queue.enqueue([MidiEvent(kind: NoteOn, note: 2)])

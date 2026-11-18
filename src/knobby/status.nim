import
  std/[json, locks, times],
  ./[audio_status, bindings, button_runtime, controls_state, fader_cache, ipc, midi_events,
    obs_state, stream_deck]

type
  MixerStatus* = object
    port*: string
    held*: array[12, bool]
    lastPressMs*: array[12, int64]
    faders*: FaderPositions
    faderObserved*: array[4, bool]
  StatusSnapshot* = object
    version*: int
    session*: string
    updatedMs*: int64
    mixer*: MixerStatus
    catalog*: JsonNode
    deckConnected*, mousepadPresent*: bool
    deckError*, audioError*, lightingError*, actionError*: string
    deckHeld*: StreamDeckKeys
    deckPressedMs*: array[StreamDeckKeyCount, int64]
    audio*: AudioStatus
    faderStreams*: array[3, seq[AudioLevel]]
    audioUpdatedMs*: int64
    buttonConfig*: JsonNode
    obs*: JsonNode
    controls*: JsonNode

const
  StatusVersion* = ProtocolVersion
  StatusStaleMs* = 2000
  PressFlashMs* = 200

var
  stateLock: Lock
  shared: StatusSnapshot

initLock(stateLock)

proc nowMs*(): int64 =
  ## Return wall time for cross-process event timestamps, never transport deadlines.
  int64(epochTime() * 1000)

proc emptyMixer*(): MixerStatus =
  ## Create a disconnected mixer with unknown physical fader positions.
  result.faders = UnknownFaders

proc initializeState*(session: string, faders = UnknownFaders) =
  ## Initialize observations with optional remembered positions, without dispatching actions.
  shared = StatusSnapshot(version: StatusVersion, session: session,
    mixer: emptyMixer(), catalog: bindingCatalog(), deckError: "Disconnected",
    audioError: "Waiting for audio")
  shared.mixer.faders = faders

proc readFaderPositions*(): FaderPositions =
  ## Copy only the fixed-size position array for the persistence worker.
  {.cast(gcsafe).}:
    withLock stateLock: result = shared.mixer.faders

proc readKnobbyState*(): StatusSnapshot =
  ## Return an owned snapshot copied while every shared reference is locked.
  {.cast(gcsafe).}:
    withLock stateLock:
      deepCopy(result, shared)
  result.updatedMs = nowMs()
  result.buttonConfig = buttonRuntimeStatus()
  result.obs = readObsStatus()
  result.controls = readControlStatus()
  if result.buttonConfig{"initialized"}.getBool():
    result.catalog = activeMixerCatalog()

proc applyMidi*(state: var MixerStatus, event: MidiEvent, timeMs: int64) =
  ## Observe physical input independently of action success or assignment.
  case event.kind
  of NoteOn, NoteOff:
    if event.note in 1..12:
      let pressed = event.kind == NoteOn and event.velocity > 0
      state.held[event.note - 1] = pressed
      if pressed: state.lastPressMs[event.note - 1] = timeMs
  of ControlChange:
    if event.controller in 16..19 and event.value in 0..127:
      state.faders[event.controller - 16] = event.value
      state.faderObserved[event.controller - 16] = true
  of OtherEvent: discard

proc resetMixerConnection*(state: var MixerStatus, port: string) =
  ## Clear transient input and freshness at a session boundary, preserving remembered positions.
  state = MixerStatus(port: port, faders: state.faders)

proc setMixerPort*(port: string) =
  ## Publish a new device session while retaining the last known fader positions.
  {.cast(gcsafe).}:
    withLock stateLock:
      shared.mixer.resetMixerConnection(port)
  resetMixerInput()

proc observeMidi*(events: openArray[MidiEvent]) =
  ## Retain input immediately, before it is queued for action execution.
  {.cast(gcsafe).}:
    withLock stateLock:
      for event in events: shared.mixer.applyMidi(event, nowMs())

proc setDeckConnection*(connected: bool, error = "") =
  ## Clear held keys at disconnect and describe the current device session.
  {.cast(gcsafe).}:
    withLock stateLock:
      shared.deckConnected = connected
      shared.deckError = error
      if not connected:
        shared.deckHeld = default(StreamDeckKeys)
        shared.deckPressedMs = default(array[StreamDeckKeyCount, int64])

proc observeDeck*(event: StreamDeckKeyEvent) =
  ## Retain a Stream Deck edge observed by its sole display owner.
  {.cast(gcsafe).}:
    withLock stateLock:
      shared.deckHeld[event.keyIndex] = event.pressed
      if event.pressed: shared.deckPressedMs[event.keyIndex] = nowMs()

proc setAudioState*(audio: AudioStatus, targets: array[3, seq[AudioLevel]]) =
  ## Publish complete audio observations without exposing mutable worker references.
  {.cast(gcsafe).}:
    withLock stateLock:
      deepCopy(shared.audio, audio)
      deepCopy(shared.faderStreams, targets)
      shared.audioUpdatedMs = nowMs()
      shared.audioError = ""

proc setComponentError*(component, message: string) =
  ## Publish a subsystem failure while other device workers continue operating.
  {.cast(gcsafe).}:
    withLock stateLock:
      case component
      of "audio": shared.audioError = message
      of "lighting": shared.lightingError = message
      of "actions": shared.actionError = message
      else: raise newException(ValueError, "Unknown component: " & component)

proc setMousepadPresence*(present: bool) =
  ## Publish physical presence independently of lighting preset application.
  {.cast(gcsafe).}:
    withLock stateLock: shared.mousepadPresent = present

proc encodeState*(state: StatusSnapshot): JsonNode =
  ## Encode authoritative observations for initial snapshots and live updates.
  var snapshot = state
  if snapshot.buttonConfig.isNil:
    snapshot.buttonConfig = newJObject()
  if snapshot.obs.isNil:
    snapshot.obs = unavailableObsStatus()
  if snapshot.controls.isNil:
    snapshot.controls = unavailableControlStatus()
  %snapshot

proc encodeSnapshot*(state: MixerStatus, session: string, timeMs: int64): string =
  ## Construct a full snapshot around a mixer fixture for pure tests.
  $encodeState(StatusSnapshot(version: StatusVersion, session: session,
    updatedMs: timeMs, mixer: state, catalog: bindingCatalog()))

proc decodeSnapshot*(data: string): StatusSnapshot =
  ## Reject incompatible state and invalid fixed-size device arrays.
  let node = parseJson(data)
  if node["version"].getInt() != StatusVersion:
    raise newException(ValueError, "Incompatible Knobby status version.")
  for (field, size) in [("held", 12), ("lastPressMs", 12), ("faders", 4)]:
    if node["mixer"][field].kind != JArray or node["mixer"][field].len != size:
      raise newException(ValueError, "Invalid mixer array: " & field)
  if not node["mixer"].hasKey("faderObserved"):
    node["mixer"]["faderObserved"] = %default(array[4, bool])
  let observed = node["mixer"]["faderObserved"]
  if observed.kind != JArray or observed.len != 4:
    raise newException(ValueError, "Invalid fader observation flags.")
  for value in observed:
    if value.kind != JBool:
      raise newException(ValueError, "Invalid fader observation flag.")
  if not node.hasKey("controls"):
    node["controls"] = unavailableControlStatus()
  if node["deckHeld"].len != StreamDeckKeyCount or node["deckPressedMs"].len != StreamDeckKeyCount or
      node["faderStreams"].len != 3:
    raise newException(ValueError, "Invalid device state arrays.")
  result = node.to(StatusSnapshot)
  if result.session.len == 0 or result.catalog["buttons"].len != 12 or result.catalog["faders"].len != 4:
    raise newException(ValueError, "Invalid Knobby status catalog.")
  for value in result.mixer.faders:
    if value notin -1..127: raise newException(ValueError, "Invalid MIDI fader position.")

proc isFresh*(receivedMs, timeMs: int64): bool =
  ## Check freshness using only the receiver's monotonic clock.
  receivedMs > 0 and timeMs >= receivedMs and timeMs - receivedMs <= StatusStaleMs

proc buttonLit*(held: bool, pressedMs, timeMs: int64): bool =
  ## Keep short taps visible after their release has already arrived.
  held or (pressedMs > 0 and timeMs >= pressedMs and timeMs - pressedMs < PressFlashMs)

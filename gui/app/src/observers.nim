import
  std/[atomics, json, locks, os],
  knobby/[audio_status, ipc, status]

type
  ViewerState* = object
    snapshot*: StatusSnapshot
    mixerError*, deckError*, audioError*: string
    deckConnected*, mousepadPresent*: bool
    deckHeld*: array[15, bool]
    deckPressedMs*: array[15, int64]
    audio*: AudioStatus
    faderStreams*: array[3, seq[AudioLevel]]
    audioUpdatedMs*: int64
    buttons*: JsonNode
    obs*: JsonNode
    controls*: JsonNode

var
  stateLock: Lock
  shared: ViewerState
  stopping: Atomic[bool]
  observerThread: Thread[void]

proc viewerState*(snapshot: StatusSnapshot): ViewerState =
  ## Adapt one authoritative daemon snapshot without inventing physical state.
  result = ViewerState(snapshot: snapshot, deckError: snapshot.deckError,
    audioError: snapshot.audioError, deckConnected: snapshot.deckConnected,
    mousepadPresent: snapshot.mousepadPresent, deckHeld: snapshot.deckHeld,
    deckPressedMs: snapshot.deckPressedMs, audio: snapshot.audio,
    faderStreams: snapshot.faderStreams, audioUpdatedMs: snapshot.audioUpdatedMs)

initLock(stateLock)

proc faderPosition*(state: ViewerState, index: int): int =
  ## Return the last received position, including while the device or daemon is offline.
  state.snapshot.mixer.faders[index]

proc faderCaption*(state: ViewerState, index: int): string =
  ## Distinguish unknown, remembered, and freshly observed positions without inferring from audio.
  let value = state.faderPosition(index)
  if value < 0:
    return "Not observed"
  if state.mixerError.len > 0 or state.snapshot.mixer.port.len == 0 or
      not state.snapshot.mixer.faderObserved[index]:
    return "Last known " & $value
  "MIDI " & $value

proc readState*(): ViewerState =
  ## Copy the last received state without sharing mutable references across threads.
  {.cast(gcsafe).}:
    withLock stateLock: deepCopy(result, shared)

proc unavailable(message: string) =
  ## Mark stale observations unavailable without discarding offline mapping descriptions.
  {.cast(gcsafe).}:
    withLock stateLock:
      shared.mixerError = message
      shared.deckConnected = false
      shared.deckError = message
      shared.audioError = message
      shared.mousepadPresent = false
      shared.buttons = nil
      shared.obs = nil
      shared.controls = nil

proc inputLoop() {.thread.} =
  ## Subscribe and reconnect; this process never opens hardware or queries audio.
  while not stopping.load():
    var peer: Peer
    try:
      peer = connectLocal(runtimePath("knobby", "daemon.sock"))
      peer.queueMessage(%*{"version": ProtocolVersion, "type": "subscribe"})
      var receivedMs = monotonicMs()
      while not stopping.load():
        for message in peer.pump():
          if message{"type"}.getStr() != "state":
            raise newException(ValueError, "Unexpected daemon message.")
          var state = viewerState(decodeSnapshot($message["state"]))
          state.buttons = message["state"]{"buttonConfig"}
          state.obs = message["state"]{"obs"}
          state.controls = message["state"]{"controls"}
          {.cast(gcsafe).}:
            withLock stateLock: deepCopy(shared, state)
          receivedMs = monotonicMs()
        if not isFresh(receivedMs, monotonicMs()):
          raise newException(IOError, "Daemon state connection is stale.")
        sleep(20)
    except CatchableError as error:
      unavailable("Daemon unavailable: " & error.msg)
    finally:
      if not peer.isNil: peer.close()
    for _ in 0..<50:
      if stopping.load(): break
      sleep(20)

proc startObservers*() =
  ## Start a single socket subscriber; hardware ownership remains with the daemon.
  shared.snapshot.mixer = emptyMixer()
  unavailable("Waiting for daemon")
  createThread(observerThread, inputLoop)

proc stopObservers*() =
  ## Stop the bounded subscriber without touching devices or daemon lifecycle.
  stopping.store(true)
  joinThread(observerThread)
proc previewState*(): ViewerState =
  ## Supply deterministic display data for isolated rendering tests only.
  var mixer = emptyMixer()
  mixer.port = "Arduino Micro 36:0"
  mixer.faders = [100, -1, 50, 95]
  mixer.faderObserved = [true, false, false, true]
  mixer.held[10] = true
  result.snapshot = decodeSnapshot(encodeSnapshot(mixer, "preview", nowMs()))
  result.deckConnected = true
  result.deckHeld[6] = true
  result.mousepadPresent = true
  result.audioUpdatedMs = nowMs()
  result.audio.master = AudioLevel(name: "Bose PC Desktop Controller", channels: @["front-left 78%", "front-right 78%"])
  result.audio.microphones = @[AudioLevel(name: "BenQ EX3210U", muted: true, channels: @["mono 100%"])]
  result.faderStreams[0] = @[AudioLevel(appName: "Firefox", name: "Firefox", channels: @["front-left 55%", "front-right 55%"])]

import
  std/[atomics, json, locks, os, strutils],
  ./[actions, audio_status, bindings, common, fader_cache, ipc, midi_events, runtime, status,
    stream_deck, stream_deck_page]

type
  PendingActions* = object
    buttons*: seq[MidiEvent]
    faders*: array[4, int]

const
  MaxPendingButtons* = 256
  WorkerPollMs = 10
  StateIntervalMs = 50
  HeartbeatMs = 1000
  RetryMs = 1000
  CachePollMs = 100

var
  actionLock: Lock
  pending: PendingActions
  actionThread, deckThread, audioThread, stateThread: Thread[void]
  persistenceThread: Thread[FaderPositions]
  persistenceStopping: Atomic[bool]

initLock(actionLock)

proc emptyActions*(): PendingActions =
  ## Create a bounded pending queue with no physical fader updates.
  result.faders = [-1, -1, -1, -1]

proc enqueue*(queue: var PendingActions, events: openArray[MidiEvent]) =
  ## Preserve button order while retaining only the newest pending fader positions.
  for event in events:
    if event.kind == NoteOn:
      if queue.buttons.len >= MaxPendingButtons:
        raise newException(IOError, "Button action queue is full.")
      queue.buttons.add(event)
    elif event.kind == ControlChange and event.controller in 16..19:
      queue.faders[event.controller - 16] = event.value

proc drain*(queue: var PendingActions): seq[MidiEvent] =
  ## Transfer ordered presses and final fader values to the action worker.
  result = move(queue.buttons)
  for index, value in queue.faders:
    if value >= 0:
      result.add(MidiEvent(kind: ControlChange, controller: index + 16, value: value))
  queue = emptyActions()

proc queueActions*(events: openArray[MidiEvent]) =
  ## Keep ingestion independent of potentially slow desktop and audio actions.
  {.cast(gcsafe).}:
    withLock actionLock: pending.enqueue(events)

proc runActions() {.thread.} =
  ## Own action dispatch and Discord RPC state exclusively on this worker.
  let dispatcher = newDispatcher()
  while not shouldStop():
    var events: seq[MidiEvent]
    {.cast(gcsafe).}:
      withLock actionLock: events = pending.drain()
    if events.len > 0:
      try:
        {.cast(gcsafe).}: dispatcher.handleBatch(events)
        setComponentError("actions", "")
      except CatchableError as error:
        setComponentError("actions", error.msg)
        stderr.writeLine("Action execution failed: " & error.msg)
    sleep(WorkerPollMs)

proc runDeck() {.thread.} =
  ## Own Stream Deck images and input without depending on GUI availability.
  var lastError = ""
  while not shouldStop():
    try:
      let path = discoverStreamDeck()
      if path.len == 0:
        setDeckConnection(false, "Disconnected")
      else:
        {.cast(gcsafe).}:
          runDemoSession(openStreamDeck(path), shouldStop, observeDeck,
            proc () =
              ## Announce a ready page only after all fifteen images are uploaded.
              setDeckConnection(true))
        lastError.setLen(0)
    except CatchableError as error:
      setDeckConnection(false, error.msg)
      if error.msg != lastError:
        stderr.writeLine("Stream Deck unavailable: " & error.msg)
        lastError = error.msg
    for _ in 0..<RetryMs div WorkerPollMs:
      if shouldStop(): break
      sleep(WorkerPollMs)

proc runAudio() {.thread.} =
  ## Publish actual audio and USB presence independently of input and UI loops.
  while not shouldStop():
    try:
      let audio = parseAudioStatus(runAudioCommand("pactl", @["--format=json", "list"]),
        runAudioCommand("pactl", @["get-default-sink"]))
      var targets: array[3, seq[AudioLevel]]
      for stream in audio.streams:
        let steam = isSteamGame(stream.processId)
        for index in 0..2:
          if stream.matchesFader(index + 17, steam): targets[index].add(stream)
      setAudioState(audio, targets)
    except CatchableError as error:
      setComponentError("audio", error.msg)
    var present = false
    try:
      for _, path in walkDir("/sys/bus/usb/devices"):
        if fileExists(path / "idVendor") and fileExists(path / "idProduct") and
            readFile(path / "idVendor").strip() == "1532" and readFile(path / "idProduct").strip() == "0c02":
          present = true
    except IOError:
      present = false
    setMousepadPresence(present)
    for _ in 0..<RetryMs div WorkerPollMs:
      if shouldStop(): break
      sleep(WorkerPollMs)

proc serveState*(server: LocalServer) =
  ## Service subscribers without blocking action workers or retaining update history.
  var
    previous = ""
    lastSent = 0'i64
  while not shouldStop():
    let snapshot = readKnobbyState()
    let message = %*{"version": ProtocolVersion, "type": "state", "state": encodeState(snapshot)}
    for request in server.pollRequests():
      if request.message{"type"}.getStr() == "subscribe":
        request.peer.subscribed = true
        request.peer.queueMessage(message)
      else: request.peer.close()
    var comparable = snapshot
    comparable.updatedMs = 0
    let content = $encodeState(comparable)
    if content != previous or monotonicMs() - lastSent >= HeartbeatMs:
      server.broadcast(message)
      previous = content
      lastSent = monotonicMs()
    sleep(StateIntervalMs)

proc runStateServer() {.thread.} =
  ## Retry optional IPC startup failures independently of physical controls.
  var lastError = ""
  while not shouldStop():
    try:
      let server = newLocalServer(runtimePath("knobby", "daemon.sock"))
      defer: server.close()
      serveState(server)
    except CatchableError as error:
      if error.msg != lastError:
        stderr.writeLine("GUI state socket unavailable: " & error.msg)
        lastError = error.msg
      sleep(RetryMs)

proc runPersistence(saved: FaderPositions) {.thread.} =
  ## Own optional cache I/O independently of MIDI ingestion, actions, and IPC.
  var
    writer = newFaderCacheWriter(faderCachePath(), saved, monotonicMs())
    lastError = ""
  proc save(force = false) =
    ## Report cache failures without stopping controls or logging identical errors repeatedly.
    try:
      writer.flush(readFaderPositions(), monotonicMs(), force)
    except IOError, OSError:
      let message = getCurrentExceptionMsg()
      if message != lastError:
        stderr.writeLine("Fader cache unavailable: " & message)
        lastError = message
  while not persistenceStopping.load():
    save()
    sleep(CachePollMs)
  save(force = true)

proc startDeviceWorkers*() =
  ## Start independently owned device, action, observation, and IPC workers.
  var saved = UnknownFaders
  try:
    saved = loadFaderCache(faderCachePath())
  except IOError, OSError, ValueError:
    stderr.writeLine("Fader cache ignored: " & getCurrentExceptionMsg())
  initializeState($getCurrentProcessId() & "-" & $nowMs(), saved)
  pending = emptyActions()
  persistenceStopping.store(false)
  createThread(actionThread, runActions)
  createThread(deckThread, runDeck)
  createThread(audioThread, runAudio)
  createThread(stateThread, runStateServer)
  createThread(persistenceThread, runPersistence, saved)

proc stopDeviceWorkers*() =
  ## Flush persistence only after ingestion returns, then join the stopped workers.
  requestStop()
  persistenceStopping.store(true)
  joinThread(actionThread)
  joinThread(deckThread)
  joinThread(audioThread)
  joinThread(stateThread)
  joinThread(persistenceThread)

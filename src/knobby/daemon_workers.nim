import
  std/[atomics, json, locks, os, strutils],
  ./[actions, audio_status, bindings, button_config, button_media, button_runtime,
    common, controls_state, discord_worker, fader_cache, ipc, midi_events, obs_state, obs_worker,
    razer_lighting, runtime, status, stream_deck]

from ./stream_deck_player import runConfiguredSession

type
  PendingActions* = object
    buttons*: seq[MidiEvent]
    faders*: array[4, int]
  DeckDriver* = object
    discover*: proc (): string
    open*: proc (path: string): StreamDeck
    log*: proc (message: string)
    retryMs*: int

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
  actionThread, faderThread, deckThread, audioThread, stateThread: Thread[void]
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
  ## Resolve button presses immediately and coalesce faders independently of slow actions.
  var faders: seq[MidiEvent]
  for event in events:
    case event.kind
    of NoteOn, NoteOff:
      try:
        routeMixerButton(event.note, event.kind == NoteOn and event.velocity > 0)
      except IOError as error:
        setComponentError("actions", error.msg)
        stderr.writeLine(error.msg)
    of ControlChange: faders.add(event)
    of OtherEvent: discard
  {.cast(gcsafe).}:
    withLock actionLock: pending.enqueue(faders)

proc runActions() {.thread.} =
  ## Dispatch button actions independently of physical faders and Discord RPC I/O.
  while not shouldStop():
    for captured in takeButtonActions():
      try:
        {.cast(gcsafe).}: executeButtonAction(captured["action"])
        setComponentError("actions", "")
      except CatchableError as error:
        setComponentError("actions", error.msg)
        stderr.writeLine("Button action failed: " & error.msg)
    sleep(WorkerPollMs)

proc runFaders() {.thread.} =
  ## Own coalesced fader dispatch so app launchers and desktop helpers cannot stall volume changes.
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

proc superviseDeck*(driver: DeckDriver, shouldStop: proc (): bool) =
  ## Own Stream Deck images and input, rediscovering the device by identity
  ## after absence, open failures, and session errors.
  var lastError = ""
  while not shouldStop():
    try:
      let path = driver.discover()
      if path.len == 0:
        setDeckConnection(false, "Disconnected")
        resetDeckInput()
      else:
        var connected = false
        runConfiguredSession(driver.open(path), shouldStop,
          proc (event: StreamDeckKeyEvent) =
            ## Observe all edges while routing only eligible fresh presses.
            observeDeck(event)
            try: routeDeckButton(event.keyIndex, event.pressed)
            except IOError as error:
              setComponentError("actions", error.msg)
              driver.log(error.msg),
          readDeckPage,
          proc () =
            ## Announce a ready page only after all fifteen images are uploaded.
            deckPageReady()
            setDeckConnection(true)
            if not connected:
              connected = true
              lastError.setLen(0)
              driver.log("Stream Deck connected at " & path & "."))
        resetDeckInput()
        lastError.setLen(0)
    except CatchableError as error:
      setDeckConnection(false, error.msg)
      resetDeckInput()
      if error.msg != lastError:
        driver.log("Stream Deck unavailable: " & error.msg)
        lastError = error.msg
    for _ in 0..<driver.retryMs div WorkerPollMs:
      if shouldStop(): break
      sleep(WorkerPollMs)

proc writeDeckLog(message: string) =
  ## Write a Stream Deck lifecycle message to the service log.
  stderr.writeLine(message)

proc runDeck() {.thread.} =
  ## Supervise the physical Stream Deck without depending on GUI availability.
  {.cast(gcsafe).}:
    superviseDeck(DeckDriver(
      discover: proc (): string =
        ## Find the MK.2 through the system hidraw class.
        discoverStreamDeck(),
      open: openStreamDeck, log: writeDeckLog, retryMs: RetryMs), shouldStop)

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
      observeMicrophones(audio.microphones)
    except CatchableError as error:
      setComponentError("audio", error.msg)
      observeMicrophoneFailure(error.msg)
    var present = false
    try:
      present = observeMousepadAttachment().len > 0
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
      elif request.message{"type"}.getStr().startsWith("config."):
        request.peer.queueMessage(processConfigRequest(request.message))
      elif request.message{"type"}.getStr() == "obs.status":
        request.peer.queueMessage(%*{"version": ProtocolVersion, "type": "result",
          "ok": true, "obs": readObsStatus()})
      elif request.message{"type"}.getStr() == "obs.command":
        try:
          let id = queueObsOperation(request.message{"operation"}.getStr())
          request.peer.queueMessage(%*{"version": ProtocolVersion, "type": "result",
            "ok": true, "queued": true, "id": id})
        except IOError, ValueError:
          request.peer.queueMessage(%*{"version": ProtocolVersion, "type": "result",
            "ok": false, "error": getCurrentExceptionMsg()})
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
  let paths = newButtonPaths()
  initializeButtons(paths, ButtonServices(
    prepare: proc (config: JsonNode): JsonNode {.gcsafe.} =
      ## Prepare all artwork independently of the active input and display loops.
      try:
        result = prepareButtonMedia(config, paths.configDir, paths.preparedDirectory(), knobbyFontPath())
      except MediaError as error:
        var failure = newException(ButtonConfigError, error.msg)
        failure.field = error.field
        raise failure,
    importAsset: proc (source: string): string {.gcsafe.} =
      ## Copy source artwork into the shared immutable asset directory.
      try:
        result = importButtonAsset(source, paths.configDir)
      except MediaError as error:
        var failure = newException(ButtonConfigError, error.msg)
        failure.field = error.field
        raise failure,
    maintain: proc () {.gcsafe.} =
      ## Reclaim old prepared files only after a successful configuration operation.
      let report = cleanPreparedCache(paths.preparedDirectory(), paths.manifestDirectory())
      for message in report.errors:
        stderr.writeLine("Button cache maintenance failed: " & message)))
  startButtonWorker()
  var saved = UnknownFaders
  try:
    saved = loadFaderCache(faderCachePath())
  except IOError, OSError, ValueError:
    stderr.writeLine("Fader cache ignored: " & getCurrentExceptionMsg())
  initializeState($getCurrentProcessId() & "-" & $nowMs(), saved)
  startObsWorker()
  startDiscordWorker()
  pending = emptyActions()
  persistenceStopping.store(false)
  createThread(actionThread, runActions)
  createThread(faderThread, runFaders)
  createThread(deckThread, runDeck)
  createThread(audioThread, runAudio)
  createThread(stateThread, runStateServer)
  createThread(persistenceThread, runPersistence, saved)

proc stopDeviceWorkers*() =
  ## Flush persistence only after ingestion returns, then join the stopped workers.
  requestStop()
  persistenceStopping.store(true)
  joinThread(actionThread)
  joinThread(faderThread)
  joinThread(deckThread)
  joinThread(audioThread)
  joinThread(stateThread)
  joinThread(persistenceThread)
  stopObsWorker()
  stopDiscordWorker()
  stopButtonWorker()

import
  std/[asyncdispatch, deques, json, monotimes, strutils],
  ./obs_client

const
  ObsBridgeOperations* = ["recordToggle", "pauseToggle", "micToggle", "open"]
  MaxCommandBacklog* = 16
  ReconnectDelayMs* = 1000
  HeartbeatMs* = 1000
  ResyncIntervalMs = 2000
  TickMs = 25
  XCompositeKind = "xcomposite_input"
  # Input kinds whose Minecraft target is chosen from an OBS property list.
  MinecraftTargetProperties = [
    (kind: XCompositeKind, property: "capture_window"),
    (kind: "pipewire_audio_application_capture", property: "TargetName")
  ]
  XCompositeValueSeparator = "\r\n"
  XCompositeClassField = 2

type
  ObsCommandError* = object of ObsError

  ObsStatus* = object
    connected*: bool
    workspaceReady*: bool
    minecraftReady*: bool
    recording*: bool
    paused*: bool
    micMuted*: bool
    transitioning*: bool
    error*: string

  ObsHooks* = object
    loadSettings*: proc (): tuple[url, password: string] {.gcsafe.}
    obsRunning*: proc (): bool {.gcsafe.}
    launchObs*: proc () {.gcsafe.}
    focusObs*: proc () {.gcsafe.}
    emit*: proc (line: JsonNode) {.gcsafe.}
    log*: proc (message: string) {.gcsafe.}

  BridgeCommand = object
    id: JsonNode
    operation: string

  WorkspaceSnapshot = object
    profile, collection: string
    sceneReady, videoReady, audioReady, micReady: bool
    recording, paused, micMuted: bool
    videoKind, audioKind: string

  ObsBridge* = ref object
    hooks: ObsHooks
    client: ObsClient
    status: ObsStatus
    emitted: ObsStatus
    lastEmitMs: int64
    commands: Deque[BridgeCommand]
    stateEpoch: int
    resyncWanted: bool
    lastResyncMs: int64
    nextConnectMs: int64
    lastLog: string
    stopped: bool

proc nowMs(): int64 =
  ## Return monotonic milliseconds for scheduling.
  getMonoTime().ticks div 1_000_000

proc statusJson*(status: ObsStatus): JsonNode =
  ## Render the shared status line consumed by the daemon.
  %*{
    "type": "status",
    "connected": status.connected,
    "workspaceReady": status.workspaceReady,
    "minecraftReady": status.minecraftReady,
    "recording": status.recording,
    "paused": status.paused,
    "micMuted": status.micMuted,
    "transitioning": status.transitioning,
    "error": status.error
  }

proc resultJson*(id: JsonNode, error: string): JsonNode =
  ## Render one command result line; error is "" on success.
  %*{
    "type": "result",
    "id": if id == nil: newJNull() else: id,
    "ok": error.len == 0,
    "error": error
  }

proc hasMinecraftIdentity(text: string): bool =
  ## Accept names that start with Minecraft and are not its launcher.
  let normalized = text.strip().toLowerAscii()
  normalized.startsWith("minecraft") and "launcher" notin normalized

proc isMinecraftItem*(inputKind, itemName, itemValue: string): bool =
  ## Decide whether an OBS list item is the Minecraft game itself.
  ## X11 window values carry "id\r\ntitle\r\nclass"; only the window class
  ## identifies the game, so browser tabs titled Minecraft never match.
  if inputKind == XCompositeKind:
    let fields = itemValue.split(XCompositeValueSeparator)
    result = fields.len > XCompositeClassField and
      hasMinecraftIdentity(fields[XCompositeClassField])
  else:
    result = hasMinecraftIdentity(itemName) or hasMinecraftIdentity(itemValue)

proc minecraftTargetProperty*(inputKind: string): string =
  ## Return the property that selects a Minecraft target, or "" when unsupported.
  for entry in MinecraftTargetProperties:
    if entry.kind == inputKind:
      return entry.property

proc requireField(node: JsonNode, key: string, kind: JsonNodeKind,
    requestType: string): JsonNode =
  ## Return a required response field; missing state must never default to idle.
  result = node{key}
  if result == nil or result.kind != kind:
    raise newException(ObsCommandError, "OBS " & requestType &
      " response lacks " & key & ".")

proc requireBool(node: JsonNode, key, requestType: string): bool =
  ## Read a required boolean response field.
  node.requireField(key, JBool, requestType).getBool()

proc requireStr(node: JsonNode, key, requestType: string): string =
  ## Read a required string response field.
  node.requireField(key, JString, requestType).getStr()

proc namesIn(node: JsonNode, listKey, nameKey, requestType: string): seq[string] =
  ## Collect names from an OBS response list.
  for item in node.requireField(listKey, JArray, requestType):
    result.add(item{nameKey}.getStr())

proc readRecordState(client: ObsClient): Future[tuple[active, paused: bool]] {.async.} =
  ## Query actual recording state.
  let record = await client.request("GetRecordStatus")
  result = (record.requireBool("outputActive", "GetRecordStatus"),
    record.requireBool("outputPaused", "GetRecordStatus"))

proc readProfileAndCollection(client: ObsClient): Future[tuple[profile,
    collection: string]] {.async.} =
  ## Query the active OBS profile and scene collection.
  let
    profiles = await client.request("GetProfileList")
    collections = await client.request("GetSceneCollectionList")
  result = (profiles.requireStr("currentProfileName", "GetProfileList"),
    collections.requireStr("currentSceneCollectionName", "GetSceneCollectionList"))

proc workspaceMismatch(profile, collection: string): string =
  ## Describe why OBS is not on the Minecraft workspace, or return "".
  if profile != ObsProfileName:
    result = "OBS profile is \"" & profile & "\"; expected \"" & ObsProfileName & "\"."
  elif collection != ObsCollectionName:
    result = "OBS scene collection is \"" & collection & "\"; expected \"" &
      ObsCollectionName & "\"."

proc readWorkspace(client: ObsClient): Future[WorkspaceSnapshot] {.async.} =
  ## Query profile, collection, required scene and inputs, recording, and mic state.
  let names = await client.readProfileAndCollection()
  result.profile = names.profile
  result.collection = names.collection
  let record = await client.readRecordState()
  result.recording = record.active
  result.paused = record.paused
  if workspaceMismatch(result.profile, result.collection).len == 0:
    let
      scenes = await client.request("GetSceneList")
      inputs = await client.request("GetInputList")
    result.sceneReady = ObsSceneName in scenes.namesIn("scenes", "sceneName",
      "GetSceneList")
    for input in inputs.requireField("inputs", JArray, "GetInputList"):
      let
        name = input{"inputName"}.getStr()
        kind = input{"inputKind"}.getStr()
      if name == ObsVideoName:
        result.videoReady = true
        result.videoKind = kind
      elif name == ObsAudioName:
        result.audioReady = true
        result.audioKind = kind
      elif name == ObsMicName:
        result.micReady = true
    if result.micReady:
      let mute = await client.request("GetInputMute", %*{"inputName": ObsMicName})
      result.micMuted = mute.requireBool("inputMuted", "GetInputMute")

proc workspaceError(snapshot: WorkspaceSnapshot): string =
  ## Describe the first missing workspace element, or return "".
  result = workspaceMismatch(snapshot.profile, snapshot.collection)
  if result.len > 0:
    return
  if not snapshot.sceneReady:
    result = "OBS scene \"" & ObsSceneName & "\" is missing."
  elif not snapshot.videoReady:
    result = "OBS input \"" & ObsVideoName & "\" is missing."
  elif not snapshot.audioReady:
    result = "OBS input \"" & ObsAudioName & "\" is missing."
  elif not snapshot.micReady:
    result = "OBS input \"" & ObsMicName & "\" is missing."

proc bindMinecraftInput*(client: ObsClient, inputName,
    inputKind: string): Future[bool] {.async.} =
  ## Point an input at Minecraft when it is present; never fall back to another target.
  ## Returns whether the input now targets Minecraft.
  let property = minecraftTargetProperty(inputKind)
  if property.len == 0:
    raise newException(ObsCommandError, "OBS input \"" & inputName &
      "\" uses unsupported source kind \"" & inputKind & "\".")
  let
    settings = await client.request("GetInputSettings",
      %*{"inputName": inputName})
    current = settings{"inputSettings"}{property}
    listed = await client.request("GetInputPropertiesListPropertyItems",
      %*{"inputName": inputName, "propertyName": property})
  var matches: seq[JsonNode]
  for item in listed.requireField("propertyItems", JArray,
      "GetInputPropertiesListPropertyItems"):
    let value = item{"itemValue"}
    if item{"itemEnabled"}.getBool(true) and value != nil and
        isMinecraftItem(inputKind, item{"itemName"}.getStr(), value.getStr()):
      matches.add(value)
  if matches.len > 0:
    result = true
    if current notin matches:
      discard await client.request("SetInputSettings", %*{
        "inputName": inputName,
        "inputSettings": {property: matches[0]},
        "overlay": true
      })

proc log(bridge: ObsBridge, message: string) =
  ## Write a diagnostic once until a different diagnostic replaces it.
  if message != bridge.lastLog:
    bridge.lastLog = message
    if bridge.hooks.log != nil:
      bridge.hooks.log(message)

proc publish(bridge: ObsBridge, force = false) =
  ## Emit status on change or when the heartbeat is due.
  let current = nowMs()
  if force or bridge.status != bridge.emitted or
      current - bridge.lastEmitMs >= HeartbeatMs:
    bridge.emitted = bridge.status
    bridge.lastEmitMs = current
    bridge.hooks.emit(statusJson(bridge.status))

proc setOffline(bridge: ObsBridge, message: string) =
  ## Report OBS as unavailable; unknown state never reads as stopped and ready.
  bridge.status = ObsStatus(error: message)
  bridge.log(message)
  bridge.publish()

proc handleEvent(bridge: ObsBridge, eventType: string, data: JsonNode) =
  ## Apply authoritative OBS state events and schedule a confirming resync.
  case eventType
  of "RecordStateChanged":
    inc bridge.stateEpoch
    case data{"outputState"}.getStr()
    of "OBS_WEBSOCKET_OUTPUT_STARTING", "OBS_WEBSOCKET_OUTPUT_STOPPING":
      bridge.status.transitioning = true
    of "OBS_WEBSOCKET_OUTPUT_STARTED", "OBS_WEBSOCKET_OUTPUT_RESUMED":
      bridge.status.recording = true
      bridge.status.paused = false
      bridge.status.transitioning = false
    of "OBS_WEBSOCKET_OUTPUT_PAUSED":
      bridge.status.recording = true
      bridge.status.paused = true
      bridge.status.transitioning = false
    of "OBS_WEBSOCKET_OUTPUT_STOPPED":
      bridge.status.recording = false
      bridge.status.paused = false
      bridge.status.transitioning = false
    else:
      discard
  of "InputMuteStateChanged":
    if data{"inputName"}.getStr() == ObsMicName and
        data{"inputMuted"} != nil and data{"inputMuted"}.kind == JBool:
      inc bridge.stateEpoch
      bridge.status.micMuted = data{"inputMuted"}.getBool()
  of "ExitStarted":
    bridge.status.workspaceReady = false
    bridge.status.minecraftReady = false
  else:
    discard
  bridge.resyncWanted = true
  bridge.publish()

proc resync(bridge: ObsBridge) {.async.} =
  ## Replace cached status with actual OBS state unless an event raced the reads.
  ## A failed read keeps the last actual recording and mute values.
  let
    client = bridge.client
    epoch = bridge.stateEpoch
  bridge.resyncWanted = false
  bridge.lastResyncMs = nowMs()
  var
    snapshot: WorkspaceSnapshot
    readOk = false
    disconnected = false
    minecraftReady = false
    error = ""
  try:
    snapshot = await client.readWorkspace()
    readOk = true
    error = snapshot.workspaceError()
    if error.len == 0:
      minecraftReady = await client.bindMinecraftInput(ObsVideoName,
        snapshot.videoKind)
      discard await client.bindMinecraftInput(ObsAudioName, snapshot.audioKind)
  except ObsConnectionError:
    # The connection supervisor reports disconnects.
    disconnected = true
  except ObsError:
    error = getCurrentExceptionMsg()
  if disconnected or client != bridge.client or not client.isOpen:
    discard
  elif epoch != bridge.stateEpoch:
    bridge.resyncWanted = true
  else:
    bridge.status.workspaceReady = error.len == 0
    bridge.status.minecraftReady = minecraftReady
    bridge.status.error = error
    if readOk:
      bridge.status.recording = snapshot.recording
      bridge.status.paused = snapshot.paused
      bridge.status.micMuted = snapshot.micMuted
      if not snapshot.recording:
        bridge.status.transitioning = false
    if error.len > 0:
      bridge.log(error)
    bridge.publish()

proc requireConnected(bridge: ObsBridge): ObsClient =
  ## Return the live client or fail without queueing work for a later connection.
  if not bridge.client.isOpen:
    raise newException(ObsCommandError, "OBS is not connected.")
  result = bridge.client

proc requireWorkspace(client: ObsClient) {.async.} =
  ## Fail unless OBS is on the Minecraft profile and scene collection.
  let
    names = await client.readProfileAndCollection()
    mismatch = workspaceMismatch(names.profile, names.collection)
  if mismatch.len > 0:
    raise newException(ObsCommandError, mismatch)

proc toggleRecording(bridge: ObsBridge) {.async.} =
  ## Stop an active recording or start one only when Minecraft is captured.
  let client = bridge.requireConnected()
  await client.requireWorkspace()
  let record = await client.readRecordState()
  if record.active:
    discard await client.request("StopRecord")
  else:
    let
      snapshot = await client.readWorkspace()
      error = snapshot.workspaceError()
    if error.len > 0:
      raise newException(ObsCommandError, error)
    if not await client.bindMinecraftInput(ObsVideoName, snapshot.videoKind):
      raise newException(ObsCommandError,
        "Minecraft is not running, so recording was not started.")
    discard await client.request("StartRecord")

proc togglePause(bridge: ObsBridge) {.async.} =
  ## Pause or resume the active Minecraft recording.
  let client = bridge.requireConnected()
  await client.requireWorkspace()
  let record = await client.readRecordState()
  if not record.active:
    raise newException(ObsCommandError, "OBS is not recording.")
  if record.paused:
    discard await client.request("ResumeRecord")
  else:
    discard await client.request("PauseRecord")

proc toggleMic(bridge: ObsBridge) {.async.} =
  ## Flip the actual mute state of the Commentary input only.
  let client = bridge.requireConnected()
  await client.requireWorkspace()
  let mute = await client.request("GetInputMute", %*{"inputName": ObsMicName})
  discard await client.request("SetInputMute", %*{
    "inputName": ObsMicName,
    "inputMuted": not mute.requireBool("inputMuted", "GetInputMute")
  })

proc activateProjectWhenIdle(client: ObsClient) {.async.} =
  ## Switch to the Minecraft profile, collection, and scene unless recording or streaming.
  let
    record = await client.readRecordState()
    stream = await client.request("GetStreamStatus")
  if not record.active and not stream.requireBool("outputActive", "GetStreamStatus"):
    let names = await client.readProfileAndCollection()
    if names.profile != ObsProfileName:
      discard await client.request("SetCurrentProfile",
        %*{"profileName": ObsProfileName})
    if names.collection != ObsCollectionName:
      discard await client.request("SetCurrentSceneCollection",
        %*{"sceneCollectionName": ObsCollectionName})
    let scene = await client.request("GetCurrentProgramScene")
    if scene{"currentProgramSceneName"}.getStr() != ObsSceneName:
      discard await client.request("SetCurrentProgramScene",
        %*{"sceneName": ObsSceneName})

proc openObs(bridge: ObsBridge) {.async.} =
  ## Launch or focus OBS, activating the project only while no output is active.
  if bridge.client.isOpen:
    await bridge.client.activateProjectWhenIdle()
    bridge.hooks.focusObs()
  elif bridge.hooks.obsRunning():
    bridge.hooks.focusObs()
  else:
    bridge.hooks.launchObs()

proc runOperation*(bridge: ObsBridge, operation: string) {.async.} =
  ## Execute one bridge operation against actual OBS state, raising on failure.
  case operation
  of "recordToggle":
    await bridge.toggleRecording()
  of "pauseToggle":
    await bridge.togglePause()
  of "micToggle":
    await bridge.toggleMic()
  of "open":
    await bridge.openObs()
  else:
    raise newException(ObsCommandError, "Unknown OBS operation \"" &
      operation & "\".")

proc execute(bridge: ObsBridge, command: BridgeCommand) {.async.} =
  ## Run one command once and report its result; failures are never retried.
  var error = ""
  try:
    await bridge.runOperation(command.operation)
  except ObsConnectionError:
    error = "OBS disconnected; the outcome of " & command.operation &
      " is unknown: " & getCurrentExceptionMsg()
  except ObsError, OSError, IOError:
    # Launcher and window commands fail with OSError; report them per command.
    error = getCurrentExceptionMsg()
  bridge.hooks.emit(resultJson(command.id, error))
  bridge.resyncWanted = true

proc submitCommand*(bridge: ObsBridge, id: JsonNode, operation: string) =
  ## Queue a command or reject it immediately; offline commands are never deferred.
  if operation notin ObsBridgeOperations:
    bridge.hooks.emit(resultJson(id, "Unknown OBS operation \"" & operation & "\"."))
  elif operation != "open" and not bridge.client.isOpen:
    bridge.hooks.emit(resultJson(id, "OBS is not connected."))
  elif bridge.commands.len >= MaxCommandBacklog:
    bridge.hooks.emit(resultJson(id, "The OBS command backlog is full."))
  else:
    bridge.commands.addLast(BridgeCommand(id: id, operation: operation))

proc submitLine*(bridge: ObsBridge, line: string) =
  ## Parse one stdin command line and queue it or report why it was rejected.
  var command: JsonNode
  try:
    command = parseJson(line)
  except JsonParsingError:
    bridge.hooks.emit(resultJson(nil, "Command is not valid JSON."))
    return
  if command.kind != JObject:
    bridge.hooks.emit(resultJson(nil, "Command must be a JSON object."))
  elif command{"operation"} == nil or command{"operation"}.kind != JString:
    bridge.hooks.emit(resultJson(command{"id"}, "Command lacks an operation."))
  else:
    bridge.submitCommand(command{"id"}, command{"operation"}.getStr())

proc connectLoop(bridge: ObsBridge) {.async.} =
  ## Keep one OBS connection, retrying every second without touching commands.
  while not bridge.stopped:
    if bridge.client.isOpen:
      await sleepAsync(TickMs)
      continue
    if bridge.client != nil:
      bridge.setOffline(bridge.client.closeReason)
      bridge.client = nil
    if nowMs() < bridge.nextConnectMs:
      await sleepAsync(TickMs)
      continue
    bridge.nextConnectMs = nowMs() + ReconnectDelayMs
    try:
      let
        settings = bridge.hooks.loadSettings()
        handler = proc (eventType: string, data: JsonNode) {.closure, gcsafe.} =
          bridge.handleEvent(eventType, data)
        client = await connectObs(settings.url, settings.password, handler)
      if bridge.stopped:
        client.close()
        return
      bridge.client = client
      bridge.status = ObsStatus(connected: true)
      bridge.resyncWanted = true
      bridge.log("Connected to OBS.")
      bridge.publish()
    except CatchableError:
      # Configuration and connection failures are reported, then retried.
      bridge.setOffline(getCurrentExceptionMsg())

proc workLoop(bridge: ObsBridge) {.async.} =
  ## Serialize commands and resyncs so stale reads never overwrite newer results.
  while not bridge.stopped:
    if bridge.commands.len > 0:
      await bridge.execute(bridge.commands.popFirst())
    elif bridge.client.isOpen and (bridge.resyncWanted or
        nowMs() - bridge.lastResyncMs >= ResyncIntervalMs):
      await bridge.resync()
    else:
      await sleepAsync(TickMs)

proc heartbeatLoop(bridge: ObsBridge) {.async.} =
  ## Emit status at least once per second.
  while not bridge.stopped:
    bridge.publish()
    await sleepAsync(TickMs)

proc newObsBridge*(hooks: ObsHooks): ObsBridge =
  ## Create a bridge whose external effects all go through hooks.
  result = ObsBridge(hooks: hooks, status: ObsStatus(error: "Connecting to OBS."))

proc start*(bridge: ObsBridge) =
  ## Start connection, work, and heartbeat loops on the current dispatcher.
  bridge.publish(force = true)
  asyncCheck bridge.connectLoop()
  asyncCheck bridge.workLoop()
  asyncCheck bridge.heartbeatLoop()

proc stop*(bridge: ObsBridge) =
  ## Stop all loops and close the OBS connection.
  bridge.stopped = true
  if bridge.client != nil:
    bridge.client.close()

proc status*(bridge: ObsBridge): ObsStatus =
  ## Return the latest status snapshot.
  bridge.status

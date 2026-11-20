import
  std/[asyncdispatch, deques, json, monotimes, strutils],
  knobby/obs_projects,
  ./[obs_client, minecraft_window]

const
  ObsBridgeOperations* = ["recordToggle", "pauseToggle", "micToggle", "open", "minecraft1080",
    "selectMinecraft", "selectFirefox", "selectWow", "firefox1080", "wow1080"]
  # Operations accepted without an OBS connection; resizing still requires one.
  LocalOperations = ["open", "minecraft1080", "firefox1080", "wow1080"]
  AppAudioKind = "pipewire_audio_application_capture"
  MaxCommandBacklog* = 16
  ReconnectDelayMs* = 1000
  HeartbeatMs* = 1000
  PresenceIntervalMs* = 1000
  ResyncIntervalMs = 2000
  TickMs = 25
  XCompositeKind = "xcomposite_input"
  # Input kinds whose Minecraft target is chosen from an OBS property list.
  MinecraftTargetProperties = [
    (kind: XCompositeKind, property: "capture_window"),
    (kind: "pipewire_audio_application_capture", property: "TargetName")
  ]
  XCompositeValueSeparator = "\r\n"
  XCompositeIdField = 0
  XCompositeClassField = 2
  AsyncTracebackHeader = "\nAsync traceback:"

type
  ObsCommandError* = object of ObsError

  ObsStatus* = object
    ## OBS connection state plus app presence observed without OBS.
    ## activeProject names the recognized profile and collection pair, or is "".
    ## captureReady means OBS can record the active setup's video and isolated
    ## audio; minecraftReady additionally requires that setup to be Minecraft.
    connected*: bool
    obsRunning*: bool
    minecraftRunning*: bool
    minecraftSized*: bool
    firefoxRunning*: bool
    firefoxSized*: bool
    wowRunning*: bool
    wowSized*: bool
    customScene*: bool
    workspaceReady*: bool
    minecraftReady*: bool
    captureReady*: bool
    audioPending*: bool
    recording*: bool
    paused*: bool
    streaming*: bool
    micMuted*: bool
    transitioning*: bool
    activeProject*: string
    profile*: string
    collection*: string
    error*: string

  ObsHooks* = object
    loadSettings*: proc (): tuple[url, password: string] {.gcsafe.}
    obsRunning*: proc (): bool {.gcsafe.}
    launchObs*: proc () {.gcsafe.}
    focusObs*: proc () {.gcsafe.}
    minecraftState*: proc (): tuple[running, sized: bool] {.gcsafe.}
    launchPrism*: proc () {.gcsafe.}
    resizeMinecraft*: proc () {.gcsafe.}
    audioTarget*: proc (): string {.gcsafe.}
    videoTarget*: proc (): string {.gcsafe.}
    firefoxState*: proc (): tuple[running, sized: bool] {.gcsafe.}
    launchFirefox*: proc () {.gcsafe.}
    resizeFirefox*: proc () {.gcsafe.}
    firefoxVideoTarget*: proc (): string {.gcsafe.}
    firefoxAudioTarget*: proc (): tuple[target: string, pending: bool] {.gcsafe.}
    focusFirefox*: proc () {.gcsafe.}
    wowState*: proc (): tuple[running, sized: bool] {.gcsafe.}
    resizeWow*: proc () {.gcsafe.}
    wowVideoTarget*: proc (): string {.gcsafe.}
    wowAudioTarget*: proc (): tuple[target: string, pending: bool] {.gcsafe.}
    emit*: proc (line: JsonNode) {.gcsafe.}
    log*: proc (message: string) {.gcsafe.}

  BridgeCommand = object
    id: JsonNode
    operation: string

  WorkspaceSnapshot = object
    profile, collection, programScene: string
    known: bool
    project: ObsProject
    sceneReady, videoReady, audioReady, micReady: bool
    recording, paused, streaming, micMuted: bool
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
    lastPresenceLog: string
    lastFirefoxPresenceLog: string
    lastWowPresenceLog: string
    lastPresenceMs: int64
    stopped: bool

proc nowMs(): int64 =
  ## Return monotonic milliseconds for scheduling.
  getMonoTime().ticks div 1_000_000

proc statusJson*(status: ObsStatus): JsonNode =
  ## Render the shared status line consumed by the daemon.
  %*{
    "type": "status",
    "connected": status.connected,
    "obsRunning": status.obsRunning,
    "minecraftRunning": status.minecraftRunning,
    "minecraftSized": status.minecraftSized,
    "firefoxRunning": status.firefoxRunning,
    "firefoxSized": status.firefoxSized,
    "wowRunning": status.wowRunning,
    "wowSized": status.wowSized,
    "customScene": status.customScene,
    "workspaceReady": status.workspaceReady,
    "minecraftReady": status.minecraftReady,
    "captureReady": status.captureReady,
    "audioPending": status.audioPending,
    "recording": status.recording,
    "paused": status.paused,
    "streaming": status.streaming,
    "micMuted": status.micMuted,
    "transitioning": status.transitioning,
    "activeProject": status.activeProject,
    "profile": status.profile,
    "collection": status.collection,
    "error": status.error
  }

proc conciseError*(message: string): string =
  ## Reduce an error to its first line without async tracebacks for status and results.
  let
    cut = message.find(AsyncTracebackHeader)
    text = if cut >= 0: message[0 ..< cut] else: message
  result = text.strip().splitLines()[0].strip()

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

proc stringsIn(node: JsonNode, listKey, requestType: string): seq[string] =
  ## Collect a required list of names that OBS returns as plain strings.
  for item in node.requireField(listKey, JArray, requestType):
    if item.kind != JString:
      raise newException(ObsCommandError, "OBS " & requestType & " response has a malformed " &
        listKey & " entry.")
    result.add(item.getStr())

proc knownProject(profile, collection: string): tuple[known: bool, project: ObsProject] =
  ## Identify a supported setup only when the actual profile and collection are its pair.
  let id = projectId(profile, collection)
  for project in ObsProject:
    if id.len > 0 and projectSpec(project).id == id:
      result = (true, project)

proc readStreamActive(client: ObsClient): Future[bool] {.async.} =
  ## Query whether streaming is active or reconnecting; malformed state is an error.
  let stream = await client.request("GetStreamStatus")
  result = stream.requireBool("outputActive", "GetStreamStatus") or
    stream.requireBool("outputReconnecting", "GetStreamStatus")

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
  ## Describe why OBS is not on a recognized setup pair, or return "".
  if not knownProject(profile, collection).known:
    var labels: seq[string]
    for spec in ObsProjects: labels.add(spec.label)
    result = "OBS profile \"" & profile & "\" with scene collection \"" & collection &
      "\" is not a known setup; choose " & labels.join(" or ") & "."

proc observedPair(profile, collection: string): string =
  ## Describe the actual OBS profile and scene collection.
  "OBS is on profile \"" & profile & "\" with scene collection \"" & collection & "\"."

proc readWorkspace(client: ObsClient): Future[WorkspaceSnapshot] {.async.} =
  ## Query the active setup, its required scene and inputs, outputs, and mic state.
  let names = await client.readProfileAndCollection()
  result.profile = names.profile
  result.collection = names.collection
  result.programScene = (await client.request("GetCurrentProgramScene")).requireStr(
    "currentProgramSceneName", "GetCurrentProgramScene")
  let record = await client.readRecordState()
  result.recording = record.active
  result.paused = record.paused
  result.streaming = await client.readStreamActive()
  (result.known, result.project) = knownProject(result.profile, result.collection)
  if result.known:
    let
      spec = projectSpec(result.project)
      scenes = await client.request("GetSceneList")
      inputs = await client.request("GetInputList")
    result.sceneReady = spec.scene in scenes.namesIn("scenes", "sceneName",
      "GetSceneList")
    for input in inputs.requireField("inputs", JArray, "GetInputList"):
      let
        name = input{"inputName"}.getStr()
        kind = input{"inputKind"}.getStr()
      if name == spec.video:
        result.videoReady = true
        result.videoKind = kind
      elif name == spec.audio:
        result.audioReady = true
        result.audioKind = kind
      elif name == spec.mic:
        result.micReady = true
    if result.micReady:
      let mute = await client.request("GetInputMute", %*{"inputName": spec.mic})
      result.micMuted = mute.requireBool("inputMuted", "GetInputMute")

proc workspaceError(snapshot: WorkspaceSnapshot): string =
  ## Describe the first missing workspace element, or return "".
  result = workspaceMismatch(snapshot.profile, snapshot.collection)
  if result.len > 0:
    return
  let spec = projectSpec(snapshot.project)
  if not snapshot.sceneReady:
    result = "OBS scene \"" & spec.scene & "\" is missing."
  elif not snapshot.videoReady:
    result = "OBS input \"" & spec.video & "\" is missing."
  elif not snapshot.audioReady:
    result = "OBS input \"" & spec.audio & "\" is missing."
  elif not snapshot.micReady:
    result = "OBS input \"" & spec.mic & "\" is missing."

proc customProgramScene(snapshot: WorkspaceSnapshot): bool =
  ## Distinguish a human-selected scene from a managed demo scene without changing either.
  ## Any scene outside a recognized setup is the human's own.
  snapshot.programScene.len > 0 and (not snapshot.known or
    snapshot.programScene != projectSpec(snapshot.project).scene)

proc bindMinecraftInput*(client: ObsClient, inputName,
    inputKind: string, exactTarget = ""): Future[bool] {.async.} =
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
  if exactTarget.len > 0:
    if inputKind == "pipewire_audio_application_capture":
      let values = settings{"inputSettings"}
      if current.getStr() != exactTarget or values{"CaptureMode"}.getInt() != 0 or
          values{"ExceptApp"}.getBool() or values{"MatchPriorty"}.getInt() != 1:
        discard await client.request("SetInputSettings", %*{"inputName": inputName,
          "inputSettings": {"TargetName": exactTarget, "CaptureMode": 0,
            "ExceptApp": false, "MatchPriorty": 1}, "overlay": true})
    elif current.getStr() != exactTarget:
      discard await client.request("SetInputSettings", %*{"inputName": inputName,
        "inputSettings": {property: exactTarget}, "overlay": true})
    return true
  let
    listed = await client.request("GetInputPropertiesListPropertyItems",
      %*{"inputName": inputName, "propertyName": property})
  var matches: seq[JsonNode]
  for item in listed.requireField("propertyItems", JArray,
      "GetInputPropertiesListPropertyItems"):
    let value = item{"itemValue"}
    if item{"itemEnabled"}.getBool(true) and value != nil and
        (if exactTarget.len > 0: value.getStr() == exactTarget
         else: isMinecraftItem(inputKind, item{"itemName"}.getStr(), value.getStr())):
      matches.add(value)
  if matches.len > 0:
    result = true
    if current notin matches:
      discard await client.request("SetInputSettings", %*{
        "inputName": inputName,
        "inputSettings": {property: matches[0]},
        "overlay": true
      })

proc bindGameAudio(bridge: ObsBridge, kind: string) {.async.} =
  ## Require the dedicated Minecraft stream label before enabling application capture.
  let client = bridge.client
  try:
    let target = if bridge.hooks.audioTarget == nil: "" else: bridge.hooks.audioTarget()
    if not await client.bindMinecraftInput(ObsAudioName, kind, target):
      raise newException(ObsCommandError, "Minecraft audio is not available.")
  except CatchableError as error:
    if client.isOpen:
      let settings = await client.request("GetInputSettings", %*{"inputName": ObsAudioName})
      let values = settings{"inputSettings"}
      if values{"TargetName"}.getStr().len > 0 or
          values{"CaptureMode"}.getInt() != 0 or values{"ExceptApp"}.getBool():
        discard await client.request("SetInputSettings", %*{"inputName": ObsAudioName,
          "inputSettings": {"TargetName": "", "CaptureMode": 0, "ExceptApp": false}, "overlay": true})
    raise newException(ObsCommandError, error.msg)

proc bindGameVideo(bridge: ObsBridge, kind: string): Future[bool] {.async.} =
  ## Bind the actual X11 client without enumerating OBS property lists.
  let target = if bridge.hooks.videoTarget == nil: "" else: bridge.hooks.videoTarget()
  if bridge.hooks.videoTarget != nil and target.len == 0: return false
  return await bridge.client.bindMinecraftInput(ObsVideoName, kind, target)

proc sameXCompositeWindow*(current, target: string): bool =
  ## Compare OBS window-capture values by window id and class; titles follow page changes.
  let
    a = current.split(XCompositeValueSeparator)
    b = target.split(XCompositeValueSeparator)
  a.len > XCompositeClassField and b.len > XCompositeClassField and
    a[XCompositeIdField] == b[XCompositeIdField] and
    a[XCompositeClassField] == b[XCompositeClassField]

proc exactAudioSettings(values: JsonNode, target: string): bool =
  ## Report whether application capture already selects only target.
  values{"TargetName"}.getStr() == target and values{"CaptureMode"}.getInt() == 0 and
    not values{"ExceptApp"}.getBool() and values{"MatchPriorty"}.getInt() == 1

proc clearAppAudio(client: ObsClient, name: string) {.async.} =
  ## Leave idle application audio capture selecting nothing after a failed verification.
  let
    settings = await client.request("GetInputSettings", %*{"inputName": name})
    values = settings{"inputSettings"}
  if values{"TargetName"}.getStr().len > 0 or values{"CaptureMode"}.getInt() != 0 or
      values{"ExceptApp"}.getBool():
    discard await client.request("SetInputSettings", %*{"inputName": name,
      "inputSettings": {"TargetName": "", "CaptureMode": 0, "ExceptApp": false}, "overlay": true})

proc clearWindowCapture(client: ObsClient, name: string) {.async.} =
  ## Leave idle window capture selecting no window after its client could not be proven.
  let settings = await client.request("GetInputSettings", %*{"inputName": name})
  if settings{"inputSettings"}{"capture_window"}.getStr().len > 0:
    discard await client.request("SetInputSettings", %*{"inputName": name,
      "inputSettings": {"capture_window": ""}, "overlay": true})

proc captureSubject(project: ObsProject): string =
  ## Name the exclusive window a setup captures, for status and errors.
  case project
  of FirefoxProject: "Firefox demo"
  of WowProject: "WoW client"
  of MinecraftProject: "Minecraft"

proc windowCaptureTargets(bridge: ObsBridge, project: ObsProject): tuple[video: string,
    audio: tuple[target: string, pending: bool]] =
  ## Read the exact window and audio targets for an exclusively captured setup.
  let subject = captureSubject(project)
  var
    videoHook: proc (): string {.gcsafe.}
    audioHook: proc (): tuple[target: string, pending: bool] {.gcsafe.}
  case project
  of FirefoxProject:
    videoHook = bridge.hooks.firefoxVideoTarget
    audioHook = bridge.hooks.firefoxAudioTarget
  of WowProject:
    videoHook = bridge.hooks.wowVideoTarget
    audioHook = bridge.hooks.wowAudioTarget
  of MinecraftProject:
    discard
  if videoHook == nil or audioHook == nil:
    raise newException(ObsCommandError, subject & " capture is not available.")
  result.video = videoHook()
  if result.video.len == 0:
    raise newException(ObsCommandError, "The " & subject & " window is not open.")
  result.audio = audioHook()

proc verifyWindowCapture(bridge: ObsBridge, snapshot: WorkspaceSnapshot, project: ObsProject,
    frozen: bool): Future[bool] {.async.} =
  ## Point a setup's capture at its single exact window and isolated audio.
  ## While an output is active (frozen) settings are only verified, never rebound.
  ## An empty pending audio target leaves audio capturing nothing until proven.
  ## Raises when capture is not exact; returns whether game or page audio is still pending.
  let
    client = bridge.client
    spec = projectSpec(project)
    subject = captureSubject(project)
  if snapshot.videoKind != XCompositeKind or snapshot.audioKind != AppAudioKind:
    raise newException(ObsCommandError, spec.label & " inputs must be X11 window capture " &
      "and application audio capture.")
  let
    targets = bridge.windowCaptureTargets(project)
    videoSettings = await client.request("GetInputSettings", %*{"inputName": spec.video})
    audioSettings = await client.request("GetInputSettings", %*{"inputName": spec.audio})
    videoBound = sameXCompositeWindow(
      videoSettings{"inputSettings"}{"capture_window"}.getStr(), targets.video)
    awaitingAudio = targets.audio.target.len == 0
    audioBound = exactAudioSettings(audioSettings{"inputSettings"}, targets.audio.target) or
      (frozen and awaitingAudio)
  if frozen and not (videoBound and audioBound):
    raise newException(ObsCommandError, subject & " capture changed while OBS output is " &
      "active; capture was left unchanged.")
  if not videoBound:
    discard await client.request("SetInputSettings", %*{"inputName": spec.video,
      "inputSettings": {"capture_window": targets.video}, "overlay": true})
  if awaitingAudio and not frozen:
    await client.clearAppAudio(spec.audio)
  elif not audioBound:
    discard await client.request("SetInputSettings", %*{"inputName": spec.audio,
      "inputSettings": {"TargetName": targets.audio.target, "CaptureMode": 0,
        "ExceptApp": false, "MatchPriorty": 1}, "overlay": true})
  result = targets.audio.pending

proc bindWindowCapture(bridge: ObsBridge, snapshot: WorkspaceSnapshot, project: ObsProject,
    frozen: bool): Future[bool] {.async.} =
  ## Verify exclusive capture, clearing idle capture when its window cannot be proven.
  ## Firefox keeps its last window binding; WoW clears both inputs so a stale or
  ## reused window id never stays selected.
  let
    client = bridge.client
    spec = projectSpec(project)
  var failure: ref ObsError
  try:
    result = await bridge.verifyWindowCapture(snapshot, project, frozen)
  except ObsError as error:
    failure = error
  if failure != nil:
    if failure of ObsConnectionError: raise failure
    if not frozen and client.isOpen:
      if snapshot.audioKind == AppAudioKind:
        await client.clearAppAudio(spec.audio)
      if project == WowProject and snapshot.videoKind == XCompositeKind:
        await client.clearWindowCapture(spec.video)
    raise newException(ObsCommandError, failure.msg)

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

proc replaceObsState(bridge: ObsBridge, next: ObsStatus) =
  ## Replace WebSocket-derived state while keeping independently observed presence.
  var status = next
  status.obsRunning = bridge.status.obsRunning
  status.minecraftRunning = bridge.status.minecraftRunning
  status.minecraftSized = bridge.status.minecraftSized
  status.firefoxRunning = bridge.status.firefoxRunning
  status.firefoxSized = bridge.status.firefoxSized
  status.wowRunning = bridge.status.wowRunning
  status.wowSized = bridge.status.wowSized
  bridge.status = status

proc refreshPresence(bridge: ObsBridge) =
  ## Observe OBS and Minecraft presence directly; a failed read keeps the last values.
  bridge.lastPresenceMs = nowMs()
  bridge.status.obsRunning = bridge.hooks.obsRunning()
  try:
    let minecraft = bridge.hooks.minecraftState()
    bridge.status.minecraftRunning = minecraft.running
    bridge.status.minecraftSized = minecraft.running and minecraft.sized
    bridge.lastPresenceLog = ""
  except ObsError, OSError, IOError, MinecraftWindowError:
    # Unknown presence is not absence; report the failure once until it changes.
    let message = conciseError(getCurrentExceptionMsg())
    if message != bridge.lastPresenceLog:
      bridge.lastPresenceLog = message
      if bridge.hooks.log != nil:
        bridge.hooks.log("Minecraft presence unavailable: " & message)
  if bridge.hooks.firefoxState != nil:
    try:
      let firefox = bridge.hooks.firefoxState()
      bridge.status.firefoxRunning = firefox.running
      bridge.status.firefoxSized = firefox.running and firefox.sized
      bridge.lastFirefoxPresenceLog = ""
    except ObsError, OSError, IOError, MinecraftWindowError:
      let message = conciseError(getCurrentExceptionMsg())
      if message != bridge.lastFirefoxPresenceLog:
        bridge.lastFirefoxPresenceLog = message
        if bridge.hooks.log != nil:
          bridge.hooks.log("Firefox demo presence unavailable: " & message)
  if bridge.hooks.wowState != nil:
    try:
      let wow = bridge.hooks.wowState()
      bridge.status.wowRunning = wow.running
      bridge.status.wowSized = wow.running and wow.sized
      bridge.lastWowPresenceLog = ""
    except ObsError, OSError, IOError, MinecraftWindowError:
      let message = conciseError(getCurrentExceptionMsg())
      if message != bridge.lastWowPresenceLog:
        bridge.lastWowPresenceLog = message
        if bridge.hooks.log != nil:
          bridge.hooks.log("WoW presence unavailable: " & message)

proc setOffline(bridge: ObsBridge, message: string) =
  ## Report OBS as unavailable; unknown state never reads as stopped and ready.
  let concise = conciseError(message)
  bridge.replaceObsState(ObsStatus(error: concise))
  bridge.log(concise)
  bridge.publish()

proc handleEvent(bridge: ObsBridge, eventType: string, data: JsonNode) =
  ## Apply authoritative OBS state events and schedule a confirming resync.
  case eventType
  of "CurrentProfileChanging", "CurrentProfileChanged",
      "CurrentSceneCollectionChanging", "CurrentSceneCollectionChanged",
      "CurrentProgramSceneChanged":
    inc bridge.stateEpoch
    bridge.status.workspaceReady = false
    bridge.status.minecraftReady = false
    bridge.status.captureReady = false
    bridge.status.audioPending = false
    bridge.status.customScene = false
    let
      profile = data{"profileName"}
      collection = data{"sceneCollectionName"}
    if eventType == "CurrentProfileChanged" and profile != nil and profile.kind == JString:
      bridge.status.profile = profile.getStr()
    elif eventType == "CurrentSceneCollectionChanged" and collection != nil and
        collection.kind == JString:
      bridge.status.collection = collection.getStr()
    if eventType.endsWith("Changing"):
      bridge.status.activeProject = ""
    else:
      bridge.status.activeProject = projectId(bridge.status.profile, bridge.status.collection)
  of "StreamStateChanged":
    inc bridge.stateEpoch
    # Starting, stopping, and reconnecting streams all block setup switches.
    let active = data{"outputActive"}
    bridge.status.streaming = data{"outputState"}.getStr() != "OBS_WEBSOCKET_OUTPUT_STOPPED" or
      (active != nil and active.kind == JBool and active.getBool())
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
    bridge.status.captureReady = false
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
    captureReady = false
    audioPending = false
    workspaceReady = false
    error = ""
  try:
    snapshot = await client.readWorkspace()
    readOk = true
    error = snapshot.workspaceError()
    workspaceReady = error.len == 0
    if error.len == 0 and not snapshot.customProgramScene():
      case snapshot.project
      of MinecraftProject:
        captureReady = await bridge.bindGameVideo(snapshot.videoKind)
        await bridge.bindGameAudio(snapshot.audioKind)
      of FirefoxProject, WowProject:
        audioPending = await bridge.bindWindowCapture(snapshot, snapshot.project,
          snapshot.recording or snapshot.streaming)
        captureReady = snapshot.project != WowProject or not audioPending
  except ObsConnectionError:
    # The connection supervisor reports disconnects.
    disconnected = true
  except ObsError:
    error = conciseError(getCurrentExceptionMsg())
    captureReady = false
    audioPending = false
  if disconnected or client != bridge.client or not client.isOpen:
    discard
  elif epoch != bridge.stateEpoch:
    bridge.resyncWanted = true
  else:
    bridge.status.workspaceReady = workspaceReady
    bridge.status.captureReady = captureReady
    bridge.status.audioPending = audioPending
    bridge.status.minecraftReady = captureReady and readOk and snapshot.known and
      snapshot.project == MinecraftProject
    bridge.status.error = error
    bridge.status.activeProject = ""
    bridge.status.customScene = readOk and snapshot.customProgramScene()
    if readOk:
      bridge.status.profile = snapshot.profile
      bridge.status.collection = snapshot.collection
      if snapshot.known:
        bridge.status.activeProject = projectSpec(snapshot.project).id
      bridge.status.recording = snapshot.recording
      bridge.status.paused = snapshot.paused
      bridge.status.streaming = snapshot.streaming
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

proc requireWorkspace(client: ObsClient): Future[ObsProject] {.async.} =
  ## Return the recognized setup, failing when the profile and collection are not a known pair.
  let
    names = await client.readProfileAndCollection()
    mismatch = workspaceMismatch(names.profile, names.collection)
  if mismatch.len > 0:
    raise newException(ObsCommandError, mismatch)
  result = knownProject(names.profile, names.collection).project

proc toggleRecording(bridge: ObsBridge) {.async.} =
  ## Stop the actual recording, record a human-selected scene as is, or start a
  ## managed setup scene only once its capture is proven.
  let
    client = bridge.requireConnected()
    record = await client.readRecordState()
  if record.active:
    discard await client.request("StopRecord")
  else:
    let
      names = await client.readProfileAndCollection()
      current = knownProject(names.profile, names.collection)
      selectedScene = (await client.request("GetCurrentProgramScene")).requireStr(
        "currentProgramSceneName", "GetCurrentProgramScene")
    if selectedScene.len == 0:
      raise newException(ObsCommandError, "Select an OBS scene before recording.")
    if not current.known or selectedScene != projectSpec(current.project).scene:
      discard await client.request("StartRecord")
      return
    let
      project = current.project
      snapshot = await client.readWorkspace()
      error = snapshot.workspaceError()
    if error.len > 0:
      raise newException(ObsCommandError, error)
    if snapshot.project != project:
      raise newException(ObsCommandError, "The OBS setup changed; recording was not started.")
    if (await client.request("GetCurrentProgramScene")).requireStr(
        "currentProgramSceneName", "GetCurrentProgramScene") != selectedScene:
      raise newException(ObsCommandError, "The OBS scene changed; press Record again.")
    case project
    of MinecraftProject:
      if not await bridge.bindGameVideo(snapshot.videoKind):
        raise newException(ObsCommandError,
          "Minecraft is not running, so recording was not started.")
      await bridge.bindGameAudio(snapshot.audioKind)
    of FirefoxProject, WowProject:
      let pending = await bridge.bindWindowCapture(snapshot, project, snapshot.streaming)
      if project == WowProject and pending:
        raise newException(ObsCommandError, "WoW has not opened its game audio stream yet; recording was not started.")
    discard await client.request("StartRecord")

proc togglePause(bridge: ObsBridge) {.async.} =
  ## Pause or resume the actual recording, whichever scene or setup it records.
  let
    client = bridge.requireConnected()
    record = await client.readRecordState()
  if not record.active:
    raise newException(ObsCommandError, "OBS is not recording.")
  if record.paused:
    discard await client.request("ResumeRecord")
  else:
    discard await client.request("PauseRecord")

proc toggleMic(bridge: ObsBridge) {.async.} =
  ## Flip the actual mute state of the active setup's Commentary input only.
  let
    client = bridge.requireConnected()
    mic = projectSpec(await client.requireWorkspace()).mic
    mute = await client.request("GetInputMute", %*{"inputName": mic})
  discard await client.request("SetInputMute", %*{
    "inputName": mic,
    "inputMuted": not mute.requireBool("inputMuted", "GetInputMute")
  })

proc requireOutputsIdle(bridge: ObsBridge, action: string) {.async.} =
  ## Refuse an action unless a fresh read shows no recording, stream, reconnect, or transition.
  let
    client = bridge.requireConnected()
    record = await client.readRecordState()
    streaming = await client.readStreamActive()
  if record.active or record.paused:
    raise newException(ObsCommandError, "OBS is recording; stop recording before " &
      action & ".")
  if streaming:
    raise newException(ObsCommandError, "OBS is streaming; stop streaming before " &
      action & ".")
  if bridge.status.transitioning:
    raise newException(ObsCommandError, "OBS output is changing; retry " & action &
      " once it settles.")

proc requireSwitchIdle(bridge: ObsBridge, label: string) {.async.} =
  ## Refuse a setup change unless every OBS output is freshly observed idle.
  await bridge.requireOutputsIdle("switching to " & label)

proc requireResizeIdle(bridge: ObsBridge, subject: string) {.async.} =
  ## Refuse resizing unless OBS is connected and every output is freshly observed idle.
  ## A running OBS without its WebSocket is never assumed idle.
  if not bridge.client.isOpen:
    raise newException(ObsCommandError, "OBS is not connected; resizing " & subject &
      " needs OBS connected and idle.")
  await bridge.requireOutputsIdle("resizing " & subject)

proc switchProject(bridge: ObsBridge, spec: ObsProjectSpec) {.async.} =
  ## Move to an existing profile, collection, and scene, checking outputs before each change.
  ## Prefer the shared demo profile when installed, falling back to the legacy profile.
  let
    client = bridge.client
    profiles = await client.request("GetProfileList")
    collections = await client.request("GetSceneCollectionList")
    profile = profiles.requireStr("currentProfileName", "GetProfileList")
    collection = collections.requireStr("currentSceneCollectionName", "GetSceneCollectionList")
    installed = profiles.stringsIn("profiles", "GetProfileList")
    target = spec.preferredProfile(installed)
  if target notin installed:
    raise newException(ObsCommandError, "OBS profile \"" & target &
      "\" does not exist; run the OBS setup tool.")
  if spec.collection notin collections.stringsIn("sceneCollections", "GetSceneCollectionList"):
    raise newException(ObsCommandError, "OBS scene collection \"" & spec.collection &
      "\" does not exist; run the OBS setup tool.")
  if profile != target:
    await bridge.requireSwitchIdle(spec.label)
    discard await client.request("SetCurrentProfile", %*{"profileName": target})
  if collection != spec.collection:
    await bridge.requireSwitchIdle(spec.label)
    discard await client.request("SetCurrentSceneCollection",
      %*{"sceneCollectionName": spec.collection})
  let scenes = await client.request("GetSceneList")
  if spec.scene notin scenes.namesIn("scenes", "sceneName", "GetSceneList"):
    raise newException(ObsCommandError, "OBS scene \"" & spec.scene & "\" is missing.")
  let scene = await client.request("GetCurrentProgramScene")
  if scene.requireStr("currentProgramSceneName", "GetCurrentProgramScene") != spec.scene:
    await bridge.requireSwitchIdle(spec.label)
    discard await client.request("SetCurrentProgramScene", %*{"sceneName": spec.scene})

proc selectProject(bridge: ObsBridge, project: ObsProject) {.async.} =
  ## Select an existing paired setup once; an already selected setup is left untouched.
  ## Failures after a change report the pair OBS actually shows and are never retried.
  let
    client = bridge.requireConnected()
    spec = projectSpec(project)
    names = await client.readProfileAndCollection()
    profiles = await client.request("GetProfileList")
    target = spec.preferredProfile(profiles.stringsIn("profiles", "GetProfileList"))
  var selected = names.profile == target and names.collection == spec.collection
  if selected:
    let scene = await client.request("GetCurrentProgramScene")
    selected = scene.requireStr("currentProgramSceneName", "GetCurrentProgramScene") == spec.scene
  if not selected:
    await bridge.requireSwitchIdle(spec.label)
    var failure: ref ObsError
    try:
      await bridge.switchProject(spec)
    except ObsError as error:
      failure = error
    if failure != nil and failure of ObsConnectionError: raise failure
    let actual = await client.readProfileAndCollection()
    if failure != nil:
      raise newException(ObsCommandError, conciseError(failure.msg) & " " &
        observedPair(actual.profile, actual.collection))
    if actual.profile != target or actual.collection != spec.collection:
      raise newException(ObsCommandError, spec.label & " was not selected. " &
        observedPair(actual.profile, actual.collection))

proc openObs(bridge: ObsBridge) {.async.} =
  ## Focus OBS without changing its setup, or launch its original Minecraft default when closed.
  if bridge.client.isOpen:
    bridge.hooks.focusObs()
  elif bridge.hooks.obsRunning():
    bridge.hooks.focusObs()
  else:
    bridge.hooks.launchObs()

proc resizeOrLaunchFirefox(bridge: ObsBridge) {.async.} =
  ## Open the dedicated Firefox demo when absent, focus it once sized, or resize it while OBS is idle.
  if bridge.hooks.firefoxState == nil:
    raise newException(ObsCommandError, "Firefox demo control is not available.")
  let firefox = bridge.hooks.firefoxState()
  if not firefox.running:
    bridge.hooks.launchFirefox()
  elif firefox.sized and bridge.hooks.focusFirefox != nil:
    bridge.hooks.focusFirefox()
  else:
    await bridge.requireResizeIdle("the Firefox demo")
    bridge.hooks.resizeFirefox()

proc resizeOrLaunchMinecraft(bridge: ObsBridge) {.async.} =
  ## Open Prism when no game window exists, or resize Minecraft to 1920x1080 while OBS is idle.
  if not bridge.hooks.minecraftState().running:
    bridge.hooks.launchPrism()
  else:
    await bridge.requireResizeIdle("Minecraft")
    bridge.hooks.resizeMinecraft()

proc resizeWow(bridge: ObsBridge) {.async.} =
  ## Resize the single WoW client to 1920x1080 while OBS is idle; WoW is never launched.
  if bridge.hooks.wowState == nil or bridge.hooks.resizeWow == nil:
    raise newException(ObsCommandError, "WoW control is not available.")
  if not bridge.hooks.wowState().running:
    raise newException(ObsCommandError, "The WoW client is not open.")
  await bridge.requireResizeIdle("WoW")
  bridge.hooks.resizeWow()

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
  of "minecraft1080":
    await bridge.resizeOrLaunchMinecraft()
  of "firefox1080":
    await bridge.resizeOrLaunchFirefox()
  of "wow1080":
    await bridge.resizeWow()
  of "selectMinecraft", "selectFirefox", "selectWow":
    await bridge.selectProject(projectForOperation(operation))
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
      " is unknown: " & conciseError(getCurrentExceptionMsg())
  except ObsError, OSError, IOError, MinecraftWindowError:
    # Launcher and window commands fail with OSError; report them per command.
    let detail = getCurrentExceptionMsg()
    error = conciseError(detail)
    if detail.strip() != error:
      # Results stay one line; command stderr and tracebacks go to the log.
      bridge.log(detail)
  bridge.refreshPresence()
  bridge.publish()
  bridge.hooks.emit(resultJson(command.id, error))
  bridge.resyncWanted = true

proc submitCommand*(bridge: ObsBridge, id: JsonNode, operation: string) =
  ## Queue a command or reject it immediately; offline commands are never deferred.
  if operation notin ObsBridgeOperations:
    bridge.hooks.emit(resultJson(id, "Unknown OBS operation \"" & operation & "\"."))
  elif operation notin LocalOperations and not bridge.client.isOpen:
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
      bridge.replaceObsState(ObsStatus(connected: true))
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
  ## Refresh presence and emit status at least once per second, connected or not.
  while not bridge.stopped:
    if nowMs() - bridge.lastPresenceMs >= PresenceIntervalMs:
      bridge.refreshPresence()
    bridge.publish()
    await sleepAsync(TickMs)

proc newObsBridge*(hooks: ObsHooks): ObsBridge =
  ## Create a bridge whose external effects all go through hooks.
  result = ObsBridge(hooks: hooks, status: ObsStatus(error: "Connecting to OBS."))

proc start*(bridge: ObsBridge) =
  ## Start connection, work, and heartbeat loops on the current dispatcher.
  bridge.refreshPresence()
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

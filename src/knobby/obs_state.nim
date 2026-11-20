import
  std/[json, locks, strutils],
  ./obs_projects

const
  ObsOperations* = ["recordToggle", "pauseToggle", "micToggle", "open",
    ObsProjectOperations[0], ObsProjectOperations[1], ObsProjectOperations[2],
    "minecraft1080", "firefox1080", "wow1080"]
  # Operations that observe or launch desktop apps; the helper itself refuses
  # resizing unless a fresh OBS read shows every output idle.
  ObsLocalOperations* = ["open", "minecraft1080", "firefox1080", "wow1080"]
  ObsVisualStates* = ["recording", "paused", "muted", "unavailable", "running", "ready",
    "active", "blocked"]
  VisualStates* = ["recording", "paused", "muted", "unavailable", "running", "ready",
    "active", "blocked", "mixed", "deafened"]
  ObsStatusFields* = ["connected", "workspaceReady", "minecraftReady", "captureReady",
    "recording", "paused", "streaming", "micMuted", "transitioning", "error", "obsRunning",
    "minecraftRunning", "minecraftSized", "firefoxRunning", "firefoxSized", "wowRunning", "wowSized", "audioPending",
    "activeProject", "profile", "collection", "customScene"]
  ObsStatusTextFields = ["error", "activeProject", "profile", "collection"]
  RecordingState = "recording"
  PausedState = "paused"
  MutedState = "muted"
  UnavailableState = "unavailable"
  ActiveState = "active"
  BlockedState = "blocked"
  BaseState = ""

var
  statusLock: Lock
  # Stored as text so no JSON reference is shared between threads.
  statusText {.guard: statusLock.}: string

initLock(statusLock)

proc unavailableObsStatus*(): JsonNode =
  ## Return the status reported before OBS is known: everything false, no error.
  result = newJObject()
  for field in ObsStatusFields:
    result[field] = if field in ObsStatusTextFields: %"" else: %false

proc setObsStatus*(status: JsonNode) {.gcsafe.} =
  ## Replace the shared OBS status snapshot with an owned copy of an object.
  if status.isNil or status.kind != JObject:
    raise newException(ValueError, "OBS status must be a JSON object.")
  let text = $status
  # The lock serializes access and string assignment copies the bytes.
  {.cast(gcsafe).}:
    withLock statusLock:
      statusText = text

proc readObsStatus*(): JsonNode {.gcsafe.} =
  ## Return an owned copy of the newest OBS status, unavailable until one is set.
  var text: string
  {.cast(gcsafe).}:
    withLock statusLock:
      text = statusText
  result = if text.len == 0: unavailableObsStatus() else: parseJson(text)

proc isObsOperation*(operation: string): bool =
  ## Report whether an operation name is one OBS buttons may run.
  operation in ObsOperations

proc obsOperationLabel*(operation: string): string =
  ## Return a short human label for an OBS operation.
  case operation
  of "recordToggle": "Record"
  of "pauseToggle": "Pause"
  of "micToggle": "Mic"
  of "open": "Open OBS"
  of "minecraft1080": "Minecraft 1080p"
  of "selectMinecraft": "Minecraft setup"
  of "selectFirefox": "Firefox setup"
  of "selectWow": "WoW setup"
  of "firefox1080": "Firefox 1080p"
  of "wow1080": "WoW 1080p"
  else: operation

proc obsOperationDescription*(operation: string): string =
  ## Describe what an OBS operation does, as shown in status catalogs and editors.
  case operation
  of "recordToggle": "Start or stop the OBS recording."
  of "pauseToggle": "Pause or resume the OBS recording."
  of "micToggle": "Mute or unmute the OBS Commentary microphone."
  of "open": "Open or focus OBS."
  of "minecraft1080": "Launch Prism when Minecraft is closed, or resize Minecraft to 1920 by 1080 pixels " &
    "while OBS is connected and idle."
  of "selectMinecraft", "selectFirefox", "selectWow":
    "Switch OBS to the " & projectSpec(projectForOperation(operation)).label &
      " profile, scene collection, and scene while nothing is recording or streaming."
  of "firefox1080": "Open the dedicated Firefox demo window, resize it to 1920 by 1080 pixels, " &
    "or focus it once sized; resizing needs OBS connected and idle."
  of "wow1080": "Resize the single running WoW client to 1920 by 1080 pixels while OBS is " &
    "connected and idle."
  else: "Unknown OBS operation " & operation & "."

proc flag(status: JsonNode, field: string): bool =
  ## Read a boolean status field, treating anything else as false.
  let node = status{field}
  result = not node.isNil and node.kind == JBool and node.getBool()

proc captureReady*(status: JsonNode): bool =
  ## Report whether the active setup can capture, falling back to the Minecraft-only legacy field.
  if not status.isNil and status.kind == JObject and status{"captureReady"} != nil:
    result = status.flag("captureReady")
  else:
    result = status.flag("minecraftReady")

proc activeProjectId*(status: JsonNode): string =
  ## Return the recognized paired setup, treating legacy status without the field as Minecraft.
  if status.isNil or status.kind != JObject: return ""
  let active = status{"activeProject"}
  if active.isNil:
    result = projectSpec(MinecraftProject).id
  elif active.kind == JString:
    result = active.getStr()

proc activeProjectLabel(status: JsonNode): string =
  ## Name the recognized setup for descriptions, or "" when OBS is on an unknown pair.
  let id = activeProjectId(status)
  for spec in ObsProjects:
    if spec.id == id: result = spec.label

proc selectionBlocked(status: JsonNode): bool =
  ## Report whether an active or changing output forbids switching setups.
  status.flag("recording") or status.flag("paused") or status.flag("streaming") or
    status.flag("transitioning")

proc obsVisualState*(operation: string, status: JsonNode): string =
  ## Choose the visual state for an OBS-bound key, or "" for its base visual.
  ## Unknown or disconnected status is unavailable, never "stopped".
  let
    known = not status.isNil and status.kind == JObject
    connected = known and status.flag("connected")
    ready = connected and status.flag("workspaceReady")
  result = BaseState
  case operation
  of "recordToggle":
    if not connected or (not ready and not status.flag("customScene")): result = UnavailableState
    elif status.flag("paused"): result = PausedState
    elif status.flag("recording"): result = RecordingState
    elif not captureReady(status) and not status.flag("customScene"): result = UnavailableState
  of "pauseToggle":
    if not connected or (not ready and not status.flag("customScene")) or
        not status.flag("recording"): result = UnavailableState
    elif status.flag("paused"): result = PausedState
    else: result = RecordingState
  of "micToggle":
    let
      muted = status{"micMuted"}
      micReady = status{"micReady"}
      micMissing = muted.isNil or muted.kind != JBool or
        (not micReady.isNil and micReady.kind == JBool and not micReady.getBool())
    if not ready or micMissing: result = UnavailableState
    elif muted.getBool(): result = MutedState
  of "open":
    result = if status.flag("obsRunning") or connected: "running" else: UnavailableState
  of "minecraft1080":
    if not status.flag("minecraftRunning"): result = UnavailableState
    elif status.flag("minecraftSized"): result = "ready"
    else: result = "running"
  of "firefox1080":
    if not status.flag("firefoxRunning"): result = UnavailableState
    elif status.flag("firefoxSized"): result = "ready"
    else: result = "running"
  of "wow1080":
    if not status.flag("wowRunning"): result = UnavailableState
    elif status.flag("wowSized"): result = "ready"
    else: result = "running"
  of "selectMinecraft", "selectFirefox", "selectWow":
    if not connected: result = UnavailableState
    elif activeProjectId(status) == projectSpec(projectForOperation(operation)).id:
      result = ActiveState
    elif selectionBlocked(status): result = BlockedState
  else:
    discard

proc resizeDescription(status: JsonNode, subject: string): string =
  ## Describe an available resize, or why the helper will refuse it.
  if not status.flag("connected"): result = "Connect OBS before resizing " & subject
  elif status.flag("recording") or status.flag("paused"):
    result = "Stop recording before resizing " & subject
  elif status.flag("streaming"): result = "Stop streaming before resizing " & subject
  elif status.flag("transitioning"): result = "OBS output is changing; wait to resize " & subject
  else: result = "Resize " & subject & " to 1920 by 1080"

proc obsStatusDescription*(operation: string, status: JsonNode): string =
  ## Explain the current action or missing prerequisite without conflating app presence with capture readiness.
  case operation
  of "open":
    if status.flag("obsRunning") or status.flag("connected"):
      result = if status.flag("connected"): "OBS open" else: "OBS open; control connection unavailable"
    else: result = "OBS closed; press to open"
  of "minecraft1080":
    if not status.flag("minecraftRunning"): result = "Minecraft closed; press to open Prism"
    elif status.flag("minecraftSized"): result = "Minecraft is 1920 by 1080"
    else: result = resizeDescription(status, "Minecraft")
  of "firefox1080":
    if not status.flag("firefoxRunning"): result = "Firefox demo closed; press to open it"
    elif status.flag("firefoxSized"): result = "Firefox demo is 1920 by 1080; press to focus"
    else: result = resizeDescription(status, "the Firefox demo")
  of "wow1080":
    if not status.flag("wowRunning"): result = "WoW client not open"
    elif status.flag("wowSized"): result = "WoW is 1920 by 1080"
    else: result = resizeDescription(status, "WoW")
  of "selectMinecraft", "selectFirefox", "selectWow":
    let label = projectSpec(projectForOperation(operation)).label
    if not status.flag("connected"): result = "OBS control unavailable"
    elif activeProjectId(status) == projectSpec(projectForOperation(operation)).id:
      result = label & " selected"
    elif status.flag("recording") or status.flag("paused"):
      result = "Stop recording before switching to " & label
    elif status.flag("streaming"): result = "Stop streaming before switching to " & label
    elif status.flag("transitioning"): result = "OBS output is changing; wait to switch"
    else: result = "Switch OBS to " & label
  else:
    let
      label = activeProjectLabel(status)
      firefox = label == projectSpec(FirefoxProject).label
      wow = label == projectSpec(WowProject).label
    if not status.flag("connected"): result = "OBS control unavailable"
    elif operation in ["recordToggle", "pauseToggle"] and status.flag("customScene"):
      if status.flag("paused"): result = "Recording paused"
      elif status.flag("recording"): result = "Recording"
      elif operation == "pauseToggle": result = "Not recording"
      else: result = "Record the selected OBS scene"
    elif label.len == 0: result = "OBS setup not recognized; choose an OBS setup"
    elif not status.flag("workspaceReady"): result = label & " workspace unavailable"
    elif operation == "recordToggle":
      if status.flag("paused"): result = "Recording paused"
      elif status.flag("recording"): result = "Recording"
      elif firefox and not status.flag("firefoxRunning"):
        result = "Open the Firefox demo before recording"
      elif firefox and not captureReady(status): result = "Waiting for Firefox demo capture"
      elif firefox and status.flag("audioPending"):
        result = "Ready to record; Firefox audio joins when the page plays sound"
      elif wow and not status.flag("wowRunning"): result = "Open WoW before recording"
      elif wow and not captureReady(status): result = "Waiting for WoW capture"
      elif wow and status.flag("audioPending"):
        result = "Ready to record; WoW audio is not bound until the game plays sound"
      elif wow: result = "Ready to record"
      elif not firefox and not status.flag("minecraftRunning"):
        result = "Open Minecraft before recording"
      elif not captureReady(status): result = "Waiting for Minecraft capture"
      else: result = "Ready to record"
    elif operation == "pauseToggle":
      if not status.flag("recording"): result = "Not recording"
      elif status.flag("paused"): result = "Recording paused"
      else: result = "Recording"
    elif operation == "micToggle":
      result = if status.flag("micMuted"): "Commentary muted" else: "Commentary enabled"
    if operation == "recordToggle" and not captureReady(status) and not status.flag("recording") and
        not status.flag("customScene"):
      let error = status{"error"}.getStr().splitLines()
      if error.len > 0 and error[0].len > 0: result = error[0]

proc selectObsVisual*(entry: JsonNode, status: JsonNode): JsonNode =
  ## Return the prepared variant of a manifest key entry for the status, or the
  ## entry itself when it has no OBS binding or no variant for the state.
  result = entry
  if not entry.isNil and entry.kind == JObject:
    let
      operation = entry{"obsOperation"}
      states = entry{"states"}
    if not operation.isNil and operation.kind == JString and
        not states.isNil and states.kind == JObject:
      let state = obsVisualState(operation.getStr(), status)
      if state.len > 0 and states{state} != nil and states[state].kind == JObject:
        result = states[state]

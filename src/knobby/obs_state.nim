import
  std/[json, locks]

const
  ObsOperations* = ["recordToggle", "pauseToggle", "micToggle", "open", "minecraft1080"]
  ObsVisualStates* = ["recording", "paused", "muted", "unavailable"]
  ObsStatusFields* = ["connected", "workspaceReady", "minecraftReady",
    "recording", "paused", "micMuted", "transitioning", "error"]
  RecordingState = "recording"
  PausedState = "paused"
  MutedState = "muted"
  UnavailableState = "unavailable"
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
    result[field] = if field == "error": %"" else: %false

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
  else: operation

proc obsOperationDescription*(operation: string): string =
  ## Describe what an OBS operation does, as shown in status catalogs and editors.
  case operation
  of "recordToggle": "Start or stop the OBS recording."
  of "pauseToggle": "Pause or resume the OBS recording."
  of "micToggle": "Mute or unmute the OBS Commentary microphone."
  of "open": "Open or focus OBS."
  of "minecraft1080": "Resize the Minecraft window content to 1920 by 1080 pixels."
  else: "Unknown OBS operation " & operation & "."

proc flag(status: JsonNode, field: string): bool =
  ## Read a boolean status field, treating anything else as false.
  let node = status{field}
  result = not node.isNil and node.kind == JBool and node.getBool()

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
    if not ready: result = UnavailableState
    elif status.flag("paused"): result = PausedState
    elif status.flag("recording"): result = RecordingState
    elif not status.flag("minecraftReady"): result = UnavailableState
  of "pauseToggle":
    if not ready or not status.flag("recording"): result = UnavailableState
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
    if not connected: result = UnavailableState
  else:
    discard

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

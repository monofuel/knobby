import
  std/[json, locks, strutils]

const
  ObsOperations* = ["recordToggle", "pauseToggle", "micToggle", "open", "minecraft1080"]
  ObsVisualStates* = ["recording", "paused", "muted", "unavailable", "running", "ready"]
  VisualStates* = ["recording", "paused", "muted", "unavailable", "running", "ready",
    "mixed", "deafened"]
  ObsStatusFields* = ["connected", "workspaceReady", "minecraftReady",
    "recording", "paused", "micMuted", "transitioning", "error", "obsRunning",
    "minecraftRunning", "minecraftSized"]
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
  of "minecraft1080": "Launch Prism when Minecraft is closed, or resize Minecraft to 1920 by 1080 pixels."
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
    result = if status.flag("obsRunning") or connected: "running" else: UnavailableState
  of "minecraft1080":
    if not status.flag("minecraftRunning"): result = UnavailableState
    elif status.flag("minecraftSized"): result = "ready"
    else: result = "running"
  else:
    discard

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
    else: result = "Resize Minecraft to 1920 by 1080"
  else:
    if not status.flag("connected"): result = "OBS control unavailable"
    elif not status.flag("workspaceReady"): result = "Minecraft AI Demos workspace unavailable"
    elif operation == "recordToggle":
      if status.flag("paused"): result = "Recording paused"
      elif status.flag("recording"): result = "Recording"
      elif not status.flag("minecraftRunning"): result = "Open Minecraft before recording"
      elif not status.flag("minecraftReady"): result = "Waiting for Minecraft capture"
      else: result = "Ready to record"
    elif operation == "pauseToggle":
      if not status.flag("recording"): result = "Not recording"
      elif status.flag("paused"): result = "Recording paused"
      else: result = "Recording"
    elif operation == "micToggle":
      result = if status.flag("micMuted"): "Commentary muted" else: "Commentary enabled"
    if operation == "recordToggle" and not status.flag("minecraftReady") and not status.flag("recording"):
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

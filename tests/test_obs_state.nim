import
  std/[json, unittest],
  knobby/obs_state

proc status(connected = true, workspaceReady = true, recording = false,
    paused = false, micMuted: JsonNode = %false, minecraftReady = true): JsonNode =
  ## Build a helper-shaped OBS status snapshot.
  result = %*{"connected": connected, "workspaceReady": workspaceReady,
    "minecraftReady": minecraftReady, "recording": recording, "paused": paused,
    "transitioning": false, "error": ""}
  if not micMuted.isNil:
    result["micMuted"] = micMuted

proc variantEntry(): JsonNode =
  ## Build a prepared manifest entry with recording and unavailable variants.
  %*{"normal": [{"path": "/c/base.jpg", "durationMs": 0}], "pressed": "/c/base-p.jpg",
    "obsOperation": "recordToggle", "states": {
      "recording": {"normal": [{"path": "/c/rec.jpg", "durationMs": 0}], "pressed": "/c/rec-p.jpg"},
      "unavailable": {"normal": [{"path": "/c/off.jpg", "durationMs": 0}], "pressed": "/c/off-p.jpg"}}}

suite "OBS state":
  test "shared status starts unavailable and is stored and read as owned copies":
    let initial = readObsStatus()
    check initial == unavailableObsStatus()
    for field in ObsStatusFields:
      check initial.hasKey(field)
    check obsVisualState("recordToggle", initial) == "unavailable"
    var written = status(recording = true)
    setObsStatus(written)
    written["recording"] = %false
    let first = readObsStatus()
    check first["recording"].getBool()
    first["recording"] = %false
    check readObsStatus()["recording"].getBool()
    expect ValueError: setObsStatus(nil)
    expect ValueError: setObsStatus(%*[1])
    check readObsStatus()["recording"].getBool()

  test "unknown or disconnected status never looks stopped":
    for snapshot in [JsonNode(nil), newJNull(), newJObject(), status(connected = false),
        status(workspaceReady = false), status(connected = false, recording = true)]:
      for operation in ["recordToggle", "pauseToggle", "micToggle"]:
        check obsVisualState(operation, snapshot) == "unavailable"
    check obsVisualState("open", status(connected = false)) == "unavailable"
    check obsVisualState("open", status(workspaceReady = false)) == ""

  test "operation precedence selects recording, paused and muted states":
    check obsVisualState("recordToggle", status()) == ""
    check obsVisualState("recordToggle", status(recording = true)) == "recording"
    check obsVisualState("recordToggle", status(recording = true, paused = true)) == "paused"
    check obsVisualState("pauseToggle", status()) == "unavailable"
    check obsVisualState("pauseToggle", status(recording = true)) == "recording"
    check obsVisualState("pauseToggle", status(recording = true, paused = true)) == "paused"
    check obsVisualState("micToggle", status()) == ""
    check obsVisualState("micToggle", status(micMuted = %true)) == "muted"
    check obsVisualState("micToggle", status(micMuted = nil)) == "unavailable"
    check obsVisualState("micToggle", status(micMuted = newJNull())) == "unavailable"
    var missingMic = status(micMuted = %true)
    missingMic["micReady"] = %false
    check obsVisualState("micToggle", missingMic) == "unavailable"
    check obsVisualState("open", status(recording = true)) == ""
    check obsVisualState("stream", status()) == ""
    for operation in ObsOperations:
      check isObsOperation(operation)
      check obsOperationDescription(operation).len > 0
    check not isObsOperation("stream")

  test "missing Minecraft blocks idle recording but keeps actual output state":
    let notReady = status(minecraftReady = false)
    check obsVisualState("recordToggle", notReady) == "unavailable"
    check obsVisualState("pauseToggle", notReady) == "unavailable"
    check obsVisualState("recordToggle",
      status(recording = true, minecraftReady = false)) == "recording"
    check obsVisualState("recordToggle",
      status(recording = true, paused = true, minecraftReady = false)) == "paused"
    check obsVisualState("pauseToggle",
      status(recording = true, minecraftReady = false)) == "recording"
    check obsVisualState("pauseToggle",
      status(recording = true, paused = true, minecraftReady = false)) == "paused"
    check obsVisualState("micToggle", notReady) == ""
    check obsVisualState("open", notReady) == ""

  test "selection returns a prepared variant or the base entry":
    let entry = variantEntry()
    check selectObsVisual(entry, status(recording = true)) == entry["states"]["recording"]
    check selectObsVisual(entry, status(connected = false)) == entry["states"]["unavailable"]
    check selectObsVisual(entry, status(recording = true, paused = true)) == entry
    check selectObsVisual(entry, status()) == entry
    let plain = %*{"builtinNumber": 4}
    check selectObsVisual(plain, status(connected = false)) == plain
    var noStates = %*{"builtinNumber": 4, "obsOperation": "open"}
    check selectObsVisual(noStates, status(connected = false)) == noStates
    check selectObsVisual(nil, status()).isNil

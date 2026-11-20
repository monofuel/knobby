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
    check obsVisualState("open", status(workspaceReady = false)) == "running"

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
    check obsVisualState("open", status(recording = true)) == "running"
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
    check obsVisualState("open", notReady) == "running"

  test "launcher artwork follows app presence independently of OBS control":
    let offline = status(connected = false, minecraftReady = false)
    check obsVisualState("minecraft1080", offline) == "unavailable"
    offline["obsRunning"] = %true
    check obsVisualState("open", offline) == "running"
    check obsStatusDescription("open", offline) == "OBS open; control connection unavailable"
    offline["minecraftRunning"] = %true
    check obsVisualState("minecraft1080", offline) == "running"
    check obsStatusDescription("minecraft1080", offline) == "Resize Minecraft to 1920 by 1080"
    offline["minecraftSized"] = %true
    check obsVisualState("minecraft1080", offline) == "ready"
    check obsStatusDescription("minecraft1080", offline) == "Minecraft is 1920 by 1080"
    offline["minecraftRunning"] = %false
    check obsVisualState("minecraft1080", offline) == "unavailable"
    check obsStatusDescription("minecraft1080", offline) == "Minecraft closed; press to open Prism"

  test "record details explain capture prerequisites and retain actual recording state":
    let waiting = status(minecraftReady = false)
    check obsStatusDescription("recordToggle", waiting) == "Open Minecraft before recording"
    waiting["minecraftRunning"] = %true
    check obsStatusDescription("recordToggle", waiting) == "Waiting for Minecraft capture"
    waiting["error"] = %"Minecraft audio is missing\nAsync traceback: private details"
    check obsStatusDescription("recordToggle", waiting) == "Minecraft audio is missing"
    waiting["recording"] = %true
    check obsStatusDescription("recordToggle", waiting) == "Recording"

  test "setup selection faces follow the observed pair and active outputs":
    let minecraft = status()
    minecraft["activeProject"] = %"minecraft"
    minecraft["captureReady"] = %true
    check obsVisualState("selectMinecraft", minecraft) == "active"
    check obsVisualState("selectFirefox", minecraft) == ""
    check obsStatusDescription("selectMinecraft", minecraft) == "Minecraft AI Demos selected"
    check obsStatusDescription("selectFirefox", minecraft) == "Switch OBS to Firefox Demos"
    for field in ["recording", "paused", "streaming", "transitioning"]:
      let busy = minecraft.copy()
      busy[field] = %true
      check obsVisualState("selectFirefox", busy) == "blocked"
      check obsVisualState("selectMinecraft", busy) == "active"
    let recording = minecraft.copy()
    recording["recording"] = %true
    check obsStatusDescription("selectFirefox", recording) ==
      "Stop recording before switching to Firefox Demos"
    let streaming = minecraft.copy()
    streaming["streaming"] = %true
    check obsStatusDescription("selectFirefox", streaming) ==
      "Stop streaming before switching to Firefox Demos"
    let unknown = status(workspaceReady = false)
    unknown["activeProject"] = %""
    check obsVisualState("selectMinecraft", unknown) == ""
    check obsVisualState("selectFirefox", unknown) == ""
    check obsVisualState("recordToggle", unknown) == "unavailable"
    check obsStatusDescription("recordToggle", unknown) ==
      "OBS setup not recognized; choose an OBS setup"
    for operation in ["selectMinecraft", "selectFirefox"]:
      check obsVisualState(operation, unavailableObsStatus()) == "unavailable"
      check obsStatusDescription(operation, unavailableObsStatus()) == "OBS control unavailable"
      check isObsOperation(operation)
    check unavailableObsStatus()["activeProject"] == %""

  test "capture readiness follows the active setup with a Minecraft-only legacy fallback":
    let firefox = status(minecraftReady = false)
    firefox["activeProject"] = %"firefox"
    firefox["captureReady"] = %true
    firefox["firefoxRunning"] = %true
    check captureReady(firefox)
    check obsVisualState("recordToggle", firefox) == ""
    check obsStatusDescription("recordToggle", firefox) == "Ready to record"
    firefox["audioPending"] = %true
    check obsStatusDescription("recordToggle", firefox) ==
      "Ready to record; Firefox audio joins when the page plays sound"
    firefox["captureReady"] = %false
    check obsVisualState("recordToggle", firefox) == "unavailable"
    check obsStatusDescription("recordToggle", firefox) == "Waiting for Firefox demo capture"
    firefox["firefoxRunning"] = %false
    check obsStatusDescription("recordToggle", firefox) == "Open the Firefox demo before recording"
    firefox["workspaceReady"] = %false
    check obsStatusDescription("micToggle", firefox) == "Firefox Demos workspace unavailable"
    let mismatch = status(minecraftReady = true)
    mismatch["captureReady"] = %false
    check not captureReady(mismatch)
    check captureReady(status(minecraftReady = true))
    check activeProjectId(status()) == "minecraft"

  test "Firefox demo artwork follows dedicated window presence without OBS":
    let offline = status(connected = false)
    check obsVisualState("firefox1080", offline) == "unavailable"
    check obsStatusDescription("firefox1080", offline) == "Firefox demo closed; press to open it"
    offline["firefoxRunning"] = %true
    check obsVisualState("firefox1080", offline) == "running"
    check obsStatusDescription("firefox1080", offline) == "Resize the Firefox demo to 1920 by 1080"
    offline["firefoxSized"] = %true
    check obsVisualState("firefox1080", offline) == "ready"
    check obsStatusDescription("firefox1080", offline) ==
      "Firefox demo is 1920 by 1080; press to focus"
    check obsOperationLabel("firefox1080") == "Firefox 1080p"
    check obsOperationLabel("selectFirefox") == "Firefox setup"

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

import
  std/[asyncdispatch, json, os, osproc, streams, strtabs, strutils, tables, tempfiles],
  ws,
  obs_client, obs_workspace, obs_targets, minecraft_window, ./fake_obs

const
  MinecraftWindow = "4194307\r\nMinecraft* 1.21.4 - Singleplayer\r\nMinecraft* 1.21.4"
  WikiWindow = "62914561\r\nMinecraft Wiki - Mozilla Firefox\r\nfirefox"
  TerminalWindow = "71303169\r\nfish\r\nAlacritty"
  FirefoxDemoWindow = "83886081\r\nDemo page - Mozilla Firefox\r\nknobby-firefox-demos"
  RetitledDemoWindow = "83886081\r\nAnother page - Mozilla Firefox\r\nknobby-firefox-demos"
  OtherDemoWindow = "92274689\r\nDemo page - Mozilla Firefox\r\nknobby-firefox-demos"
  FirefoxAudioLabel = "knobby-firefox"
  FirefoxProfile = "Firefox Demos"
  FirefoxIsolationFailure = "Audio label knobby-firefox also captures Firefox (PID 77) outside the Firefox demo."
  MinecraftApp = "Minecraft* 1.21.4"
  MinecraftAudioLabel = "knobby-minecraft-audio"
  JavaApp = "java"
  AmbiguousWindow = "Multiple Minecraft windows are open."
  AudioGuardFailure = "Minecraft audio is not isolated to the game process."
  BridgeBinaryTimeoutMs = 60000
  # Longer than the bridge's periodic resync interval.
  CleanResyncWaitMs = 2500
  PresenceFailure = "Cannot open X display \":0\" to resize Minecraft."
  TracedFailure = PresenceFailure & "\nAsync traceback:\n  obs_workspace.nim(1) runOperation\n" &
    "Exception message: " & PresenceFailure & "\n"

type
  Harness = ref object
    fake: FakeObs
    bridge: ObsBridge
    lines: seq[JsonNode]
    logs: seq[string]
    launches, focuses: int
    running: bool
    minecraftRunning, minecraftSized: bool
    presenceError: string
    prismLaunches, resizes: int
    port: int
    videoTarget, audioTarget: string
    videoError, audioError: string
    firefoxRunning, firefoxSized: bool
    firefoxLaunches, firefoxResizes: int
    firefoxVideo, firefoxVideoError, firefoxAudioError: string
    firefoxPending: bool

proc windowItems(values: varargs[string]): JsonNode =
  ## Build xcomposite capture_window property items.
  result = newJArray()
  for value in values:
    result.add(%*{"itemName": value.split("\r\n")[1], "itemValue": value,
      "itemEnabled": true})

proc appItems(names: varargs[string]): JsonNode =
  ## Build application audio property items.
  result = newJArray()
  for name in names:
    result.add(%*{"itemName": name, "itemValue": name, "itemEnabled": true})

proc newHarness(minecraft = true, port = 0, targets = false, present = false): Harness =
  ## Start a fake OBS and a bridge whose effects are recorded.
  ## With targets, exact video and audio targets come from harness fields, and a
  ## non-empty error field makes that hook raise ObsError instead. With present,
  ## OBS and a 1920x1080 Minecraft window are observed from the first status.
  let harness = Harness(fake: newFakeObs("pw"), videoTarget: MinecraftWindow,
    audioTarget: MinecraftAudioLabel, running: present,
    minecraftRunning: present, minecraftSized: present, firefoxVideo: FirefoxDemoWindow)
  harness.port = if port == 0: harness.fake.port else: port
  harness.fake.settings["Minecraft Video"] = %*{"capture_window": TerminalWindow}
  harness.fake.settings["Minecraft Audio"] = %*{"TargetName": JavaApp}
  if minecraft:
    harness.fake.items["Minecraft Video"] = windowItems(WikiWindow, MinecraftWindow)
    harness.fake.items["Minecraft Audio"] = appItems(JavaApp, MinecraftApp)
  else:
    harness.fake.items["Minecraft Video"] = windowItems(WikiWindow, TerminalWindow)
    harness.fake.items["Minecraft Audio"] = appItems(JavaApp)
  var hooks: ObsHooks
  hooks.loadSettings = proc (): tuple[url, password: string] {.gcsafe.} =
    ("ws://127.0.0.1:" & $harness.port, "pw")
  hooks.obsRunning = proc (): bool {.gcsafe.} = harness.running
  hooks.launchObs = proc () {.gcsafe.} =
    inc harness.launches
  hooks.focusObs = proc () {.gcsafe.} =
    inc harness.focuses
  hooks.minecraftState = proc (): tuple[running, sized: bool] {.gcsafe.} =
    if harness.presenceError.len > 0:
      raise newException(ObsError, harness.presenceError)
    (harness.minecraftRunning, harness.minecraftSized)
  hooks.launchPrism = proc () {.gcsafe.} =
    inc harness.prismLaunches
  hooks.resizeMinecraft = proc () {.gcsafe.} =
    inc harness.resizes
    harness.minecraftSized = true
  hooks.firefoxState = proc (): tuple[running, sized: bool] {.gcsafe.} =
    (harness.firefoxRunning, harness.firefoxSized)
  hooks.launchFirefox = proc () {.gcsafe.} =
    inc harness.firefoxLaunches
  hooks.resizeFirefox = proc () {.gcsafe.} =
    inc harness.firefoxResizes
    harness.firefoxSized = true
  hooks.firefoxVideoTarget = proc (): string {.gcsafe.} =
    if harness.firefoxVideoError.len > 0:
      raise newException(ObsError, harness.firefoxVideoError)
    harness.firefoxVideo
  hooks.firefoxAudioTarget = proc (): tuple[target: string, pending: bool] {.gcsafe.} =
    if harness.firefoxAudioError.len > 0:
      raise newException(ObsError, harness.firefoxAudioError)
    (FirefoxAudioLabel, harness.firefoxPending)
  hooks.emit = proc (line: JsonNode) {.gcsafe.} =
    harness.lines.add(line)
  hooks.log = proc (message: string) {.gcsafe.} =
    harness.logs.add(message)
  if targets:
    hooks.videoTarget = proc (): string {.gcsafe.} =
      if harness.videoError.len > 0:
        raise newException(ObsError, harness.videoError)
      harness.videoTarget
    hooks.audioTarget = proc (): string {.gcsafe.} =
      if harness.audioError.len > 0:
        raise newException(ObsError, harness.audioError)
      harness.audioTarget
  harness.bridge = newObsBridge(hooks)
  harness.bridge.start()
  result = harness

proc close(harness: Harness) =
  ## Stop the bridge and fake server.
  ## Driving the dispatcher while a failed assertion unwinds loses that failure,
  ## so the final drain runs only on success.
  harness.bridge.stop()
  harness.fake.stop()
  if getCurrentException() == nil:
    pumpFor(50)

proc resultFor(harness: Harness, id: int): JsonNode =
  ## Wait for the result line of one command.
  let found = pump(proc (): bool =
    for line in harness.lines:
      if line["type"].getStr() == "result" and line["id"] == %id:
        return true)
  doAssert found, "no result for command " & $id
  for line in harness.lines:
    if line["type"].getStr() == "result" and line["id"] == %id:
      return line

proc command(harness: Harness, id: int, operation: string): JsonNode =
  ## Submit one stdin command line and wait for its result.
  harness.bridge.submitLine($(%*{"id": id, "operation": operation}))
  result = harness.resultFor(id)

proc waitStatus(harness: Harness, check: proc (status: ObsStatus): bool): bool =
  ## Wait until the bridge status satisfies check.
  pump(proc (): bool = check(harness.bridge.status))

proc ready(harness: Harness): bool =
  ## Wait for a connected, resynced, ready workspace.
  harness.waitStatus(proc (status: ObsStatus): bool =
    status.connected and status.workspaceReady and status.minecraftReady)

proc testRecordWithActualState() =
  ## Bind Minecraft, start and stop recording from actual state, and report events.
  let harness = newHarness()
  defer: harness.close()
  doAssert harness.ready()
  doAssert harness.fake.settings["Minecraft Video"]["capture_window"].getStr() ==
    MinecraftWindow
  doAssert harness.fake.settings["Minecraft Audio"]["TargetName"].getStr() ==
    MinecraftApp
  doAssert harness.bridge.status.micMuted
  doAssert harness.command(1, "recordToggle")["ok"].getBool()
  doAssert harness.fake.recording
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.recording and not status.transitioning)
  doAssert harness.command(2, "pauseToggle")["ok"].getBool()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = status.paused)
  doAssert harness.command(3, "pauseToggle")["ok"].getBool()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.recording and not status.paused)
  doAssert harness.command(4, "recordToggle")["ok"].getBool()
  doAssert not harness.fake.recording
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = not status.recording)
  doAssert harness.fake.count("StartRecord") == 1
  doAssert harness.fake.count("StopRecord") == 1
  doAssert harness.fake.count("ToggleRecord") == 0
  var statusLines = 0
  for line in harness.lines:
    if line["type"].getStr() == "status":
      inc statusLines
      for field in ["connected", "obsRunning", "minecraftRunning", "minecraftSized",
          "workspaceReady", "minecraftReady", "recording", "paused", "micMuted",
          "transitioning"]:
        doAssert line[field].kind == JBool
      doAssert line["error"].kind == JString
  doAssert statusLines > 0

proc testExternalStateIsAuthoritative() =
  ## Stop a recording OBS started on its own and flip the actual mic state.
  let harness = newHarness()
  defer: harness.close()
  harness.fake.recording = true
  harness.fake.micMuted = false
  doAssert harness.ready()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.recording and not status.micMuted)
  doAssert harness.command(1, "recordToggle")["ok"].getBool()
  doAssert harness.fake.count("StartRecord") == 0
  doAssert harness.fake.count("StopRecord") == 1
  doAssert harness.command(2, "micToggle")["ok"].getBool()
  doAssert harness.fake.micMuted
  doAssert harness.fake.requestData[^1]["inputName"].getStr() == ObsMicName
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = status.micMuted)
  let pause = harness.command(3, "pauseToggle")
  doAssert not pause["ok"].getBool()
  doAssert "not recording" in pause["error"].getStr()

proc testMinecraftAbsent() =
  ## Never fall back to another window or all Java; still allow stopping.
  let harness = newHarness(minecraft = false)
  defer: harness.close()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.connected and status.workspaceReady)
  pumpFor(100)
  doAssert not harness.bridge.status.minecraftReady
  doAssert harness.fake.settings["Minecraft Video"]["capture_window"].getStr() == TerminalWindow
  doAssert harness.fake.settings["Minecraft Audio"]["TargetName"].getStr() == "",
    "unproven audio selects nothing rather than every Java program"
  let start = harness.command(1, "recordToggle")
  doAssert not start["ok"].getBool()
  doAssert "Minecraft is not running" in start["error"].getStr()
  doAssert harness.fake.count("StartRecord") == 0
  harness.fake.recording = true
  doAssert harness.command(2, "recordToggle")["ok"].getBool()
  doAssert harness.fake.count("StopRecord") == 1

proc testWorkspaceMismatch() =
  ## Refuse controls outside the Minecraft profile and report why.
  let harness = newHarness()
  defer: harness.close()
  harness.fake.profile = "Untitled"
  harness.fake.recording = true
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.connected and "profile" in status.error)
  doAssert not harness.bridge.status.workspaceReady
  doAssert harness.bridge.status.recording
  for (id, operation) in [(1, "recordToggle"), (2, "pauseToggle"), (3, "micToggle")]:
    let response = harness.command(id, operation)
    doAssert not response["ok"].getBool()
    doAssert "Untitled" in response["error"].getStr()
  doAssert harness.fake.count("StopRecord") == 0
  doAssert harness.fake.count("SetInputMute") == 0
  harness.fake.profile = ObsProfileName
  harness.fake.inputs.setLen(2)
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    ObsMicName in status.error)
  doAssert not harness.bridge.status.workspaceReady

proc testOpenPreservesActiveOutput() =
  ## Focus without switching while recording; activate the project only when idle.
  let harness = newHarness()
  defer: harness.close()
  harness.fake.profile = "Untitled"
  harness.fake.collection = "Untitled"
  harness.fake.programScene = "Scene"
  harness.fake.recording = true
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = status.connected)
  doAssert harness.command(1, "open")["ok"].getBool()
  doAssert harness.focuses == 1
  doAssert harness.fake.profile == "Untitled"
  doAssert harness.fake.count("SetCurrentProfile") == 0
  doAssert harness.fake.count("SetCurrentSceneCollection") == 0
  harness.fake.recording = false
  harness.fake.streaming = true
  doAssert harness.command(2, "open")["ok"].getBool()
  doAssert harness.fake.count("SetCurrentProfile") == 0
  harness.fake.streaming = false
  doAssert harness.command(3, "open")["ok"].getBool()
  doAssert harness.focuses == 3
  doAssert harness.fake.profile == ObsProfileName
  doAssert harness.fake.collection == ObsCollectionName
  doAssert harness.fake.programScene == ObsSceneName
  doAssert harness.launches == 0

proc testOffline() =
  ## Report unavailability, reject controls, and launch or focus OBS for open.
  let harness = newHarness(port = closedPort())
  defer: harness.close()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    not status.connected and status.error.len > 0)
  let status = harness.bridge.status
  doAssert not (status.recording or status.workspaceReady or status.minecraftReady)
  for (id, operation) in [(1, "recordToggle"), (2, "pauseToggle"), (3, "micToggle")]:
    let response = harness.command(id, operation)
    doAssert not response["ok"].getBool()
    doAssert "not connected" in response["error"].getStr()
  doAssert harness.command(4, "open")["ok"].getBool()
  doAssert harness.launches == 1
  harness.running = true
  doAssert harness.command(5, "open")["ok"].getBool()
  doAssert harness.launches == 1
  doAssert harness.focuses == 1
  doAssert harness.fake.requests.len == 0
  let before = harness.lines.len
  pumpFor(HeartbeatMs + 300)
  doAssert harness.lines.len > before, "heartbeat continues while offline"

proc statusLines(harness: Harness, first = 0): seq[JsonNode] =
  ## Return emitted status lines from index first onward.
  for line in harness.lines[first .. ^1]:
    if line["type"].getStr() == "status":
      result.add(line)

proc testPresenceWhileOffline() =
  ## Track OBS and Minecraft presence independently while OBS has no WebSocket.
  let harness = newHarness(port = closedPort())
  defer: harness.close()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    not status.connected and status.error.len > 0)
  doAssert harness.statusLines()[0]["obsRunning"].getBool() == false
  harness.minecraftRunning = true
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.minecraftRunning and not status.minecraftSized and not status.obsRunning)
  harness.minecraftSized = true
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = status.minecraftSized)
  harness.running = true
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.obsRunning and status.minecraftRunning and not status.connected)
  let status = harness.bridge.status
  doAssert not (status.minecraftReady or status.workspaceReady or status.recording)
  harness.minecraftRunning = false
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.obsRunning and not status.minecraftRunning and not status.minecraftSized)
  doAssert harness.statusLines()[^1]["obsRunning"].getBool()
  harness.presenceError = TracedFailure
  harness.running = false
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = not status.obsRunning)
  harness.minecraftRunning = true
  pumpFor(2 * PresenceIntervalMs + 300)
  doAssert not harness.bridge.status.minecraftRunning,
    "a failed presence read keeps the last observation"
  var presenceLogs: seq[string]
  for message in harness.logs:
    if "presence" in message: presenceLogs.add(message)
  doAssert presenceLogs == @["Minecraft presence unavailable: " & PresenceFailure],
    $presenceLogs
  for line in harness.statusLines():
    doAssert '\n' notin line["error"].getStr(), line["error"].getStr()
  harness.presenceError = ""
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = status.minecraftRunning)
  doAssert harness.fake.requests.len == 0

proc testMinecraft1080Offline() =
  ## Launch Prism without a game window, otherwise resize, all without OBS.
  let harness = newHarness(port = closedPort())
  defer: harness.close()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = not status.connected)
  doAssert harness.command(1, "minecraft1080")["ok"].getBool()
  doAssert harness.prismLaunches == 1 and harness.resizes == 0
  doAssert not harness.bridge.status.minecraftRunning
  harness.minecraftRunning = true
  doAssert harness.command(2, "minecraft1080")["ok"].getBool()
  doAssert harness.prismLaunches == 1 and harness.resizes == 1
  let status = harness.bridge.status
  doAssert status.minecraftRunning and status.minecraftSized and not status.connected,
    "a command refreshes presence before its result"
  doAssert harness.command(3, "minecraft1080")["ok"].getBool()
  doAssert harness.prismLaunches == 1 and harness.resizes == 2
  harness.presenceError = TracedFailure
  let failed = harness.command(4, "minecraft1080")
  doAssert not failed["ok"].getBool()
  doAssert failed["error"].getStr() == PresenceFailure
  doAssert harness.prismLaunches == 1 and harness.resizes == 2
  doAssert harness.bridge.status.minecraftSized
  doAssert harness.launches == 0 and harness.focuses == 0
  doAssert harness.fake.requests.len == 0

proc testPresenceSurvivesConnectionChanges() =
  ## Connecting and disconnecting OBS never resets observed presence to false.
  let harness = newHarness(present = true)
  defer: harness.close()
  doAssert harness.ready()
  harness.fake.hangupOn = @["GetRecordStatus"]
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = not status.connected)
  harness.fake.hangupOn = @[]
  doAssert harness.ready()
  doAssert harness.command(1, "minecraft1080")["ok"].getBool()
  doAssert harness.resizes == 1 and harness.prismLaunches == 0
  let lines = harness.statusLines()
  doAssert lines.len > 3
  for line in lines:
    doAssert line["obsRunning"].getBool() and line["minecraftRunning"].getBool()
    doAssert line["minecraftSized"].getBool()
  doAssert harness.fake.count("StartRecord") == 0

proc testDisconnectNoReplay() =
  ## Report an unknown outcome on disconnect and never resend after reconnecting.
  let harness = newHarness()
  defer: harness.close()
  doAssert harness.ready()
  harness.fake.hangupOn = @["StartRecord"]
  let response = harness.command(1, "recordToggle")
  doAssert not response["ok"].getBool()
  doAssert "unknown" in response["error"].getStr()
  harness.fake.hangupOn = @[]
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = not status.connected)
  doAssert harness.ready()
  pumpFor(300)
  doAssert harness.fake.count("StartRecord") == 1
  doAssert harness.fake.identifies == 2

proc testCommandValidation() =
  ## Reject malformed lines, unknown operations, and backlog overflow.
  let harness = newHarness()
  defer: harness.close()
  doAssert harness.ready()
  harness.bridge.submitLine("{nope")
  harness.bridge.submitLine("[1]")
  harness.bridge.submitLine("""{"id": 7}""")
  harness.bridge.submitLine("""{"id": 8, "operation": "startStream"}""")
  for id in 100 ..< 100 + MaxCommandBacklog + 1:
    harness.bridge.submitLine($(%*{"id": id, "operation": "micToggle"}))
  let errors = block:
    var found: seq[string]
    for line in harness.lines:
      if line["type"].getStr() == "result":
        found.add(line["error"].getStr())
    found
  doAssert errors.len == 5, $errors
  doAssert "valid JSON" in errors[0]
  doAssert "object" in errors[1]
  doAssert "operation" in errors[2]
  doAssert "startStream" in errors[3]
  doAssert "backlog" in errors[4]
  doAssert harness.resultFor(100 + MaxCommandBacklog - 1)["ok"].getBool()

proc testBridgeProcess() =
  ## Run the CLI against a private config: request output and bridge stdin framing.
  let directory = createTempDir("knobby_obs_", "")
  defer: removeDir(directory)
  let fake = newFakeObs("pw")
  defer: fake.stop()
  let configDir = directory / "obs-studio/plugin_config/obs-websocket"
  createDir(configDir)
  writeFile(configDir / "config.json", $(%*{"auth_required": true,
    "server_password": "pw", "server_port": fake.port}))
  let binary = directory / "knobby_obs"
  let build = execCmdEx("nim c --hints:off -o:" & quoteShell(binary) & " " &
    quoteShell(currentSourcePath().parentDir() / "knobby_obs.nim"))
  doAssert build.exitCode == 0, build.output
  var environment = newStringTable()
  for key, value in envPairs():
    environment[key] = value
  environment["XDG_CONFIG_HOME"] = directory
  # Production presence hooks must not read the desktop's X display in tests.
  environment.del("DISPLAY")

  let request = startProcess(binary, args = ["request", "GetRecordStatus"],
    env = environment, options = {})
  doAssert pump(proc (): bool = not request.running, BridgeBinaryTimeoutMs)
  let output = request.outputStream.readAll()
  doAssert request.peekExitCode() == 0
  doAssert parseJson(output)["outputActive"].getBool() == false
  doAssert "pw" notin output
  request.close()

  fake.stop()
  let bridge = startProcess(binary, args = ["bridge"], env = environment,
    options = {})
  bridge.inputStream.write(repeat('x', 1024 * 1024 + 10) & "\n")
  bridge.inputStream.write("""{"id": "a", "operation": "micToggle"}""" & "\n")
  bridge.inputStream.close()
  doAssert pump(proc (): bool = not bridge.running, BridgeBinaryTimeoutMs)
  doAssert bridge.peekExitCode() == 0
  var results: seq[JsonNode]
  for line in bridge.outputStream.readAll().splitLines():
    if line.len > 0:
      let parsed = parseJson(line)
      if parsed["type"].getStr() == "result":
        results.add(parsed)
  bridge.close()
  doAssert results.len == 2, $results
  doAssert results[0]["id"].kind == JNull
  doAssert "1 MiB" in results[0]["error"].getStr()
  doAssert results[1]["id"].getStr() == "a"
  doAssert not results[1]["ok"].getBool()

proc testExactTargetsSkipPropertyLists() =
  ## Bind exact targets without the list request that crashed OBS 32.1.2.
  let harness = newHarness(targets = true)
  defer: harness.close()
  harness.fake.hangupOn = @["GetInputPropertiesListPropertyItems"]
  harness.fake.settings["Minecraft Audio"] = %*{"TargetName": JavaApp,
    "CaptureMode": 1, "ExceptApp": true, "MatchPriorty": 0}
  doAssert harness.ready()
  doAssert harness.fake.settings["Minecraft Video"]["capture_window"].getStr() ==
    MinecraftWindow
  let audio = harness.fake.settings["Minecraft Audio"]
  doAssert audio["TargetName"].getStr() == MinecraftAudioLabel
  doAssert audio["CaptureMode"].getInt() == 0
  doAssert not audio["ExceptApp"].getBool()
  doAssert audio["MatchPriorty"].getInt() == 1
  doAssert harness.command(1, "recordToggle")["ok"].getBool()
  doAssert harness.fake.recording
  pumpFor(300)
  doAssert harness.fake.count("GetInputPropertiesListPropertyItems") == 0
  doAssert harness.fake.identifies == 1

proc testWindowErrorsStayInHelper() =
  ## Report missing and ambiguous windows as errors while the helper keeps running.
  let harness = newHarness(targets = true)
  defer: harness.close()
  harness.videoTarget = ""
  harness.audioError = "No Minecraft window is open."
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.connected and status.workspaceReady and
      "No Minecraft window" in status.error)
  doAssert not harness.bridge.status.minecraftReady
  let missing = harness.command(1, "recordToggle")
  doAssert not missing["ok"].getBool()
  doAssert "Minecraft is not running" in missing["error"].getStr()
  harness.videoError = AmbiguousWindow
  harness.audioError = AmbiguousWindow
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.connected and AmbiguousWindow in status.error)
  doAssert not harness.bridge.status.minecraftReady
  let ambiguous = harness.command(2, "recordToggle")
  doAssert not ambiguous["ok"].getBool()
  doAssert AmbiguousWindow in ambiguous["error"].getStr()
  doAssert harness.command(3, "micToggle")["ok"].getBool()
  doAssert harness.fake.count("StartRecord") == 0
  doAssert harness.fake.count("GetInputPropertiesListPropertyItems") == 0
  doAssert harness.fake.identifies == 1
  harness.videoError = ""
  harness.audioError = ""
  harness.videoTarget = MinecraftWindow
  doAssert harness.ready()

proc testAudioGuardFailureWhileRecording() =
  ## Keep actual recording state visible and stop/pause usable when audio is unsafe.
  let harness = newHarness(targets = true)
  defer: harness.close()
  harness.fake.recording = true
  harness.fake.paused = true
  harness.audioError = AudioGuardFailure
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.connected and AudioGuardFailure in status.error)
  let status = harness.bridge.status
  doAssert status.workspaceReady
  doAssert not status.minecraftReady
  doAssert status.recording and status.paused
  doAssert harness.command(1, "pauseToggle")["ok"].getBool()
  doAssert not harness.fake.paused
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.recording and not status.paused and AudioGuardFailure in status.error)
  doAssert harness.command(2, "pauseToggle")["ok"].getBool()
  doAssert harness.fake.paused
  doAssert harness.command(3, "recordToggle")["ok"].getBool()
  doAssert not harness.fake.recording
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    not status.recording and not status.paused and status.workspaceReady and
      AudioGuardFailure in status.error)
  let start = harness.command(4, "recordToggle")
  doAssert not start["ok"].getBool()
  doAssert AudioGuardFailure in start["error"].getStr()
  doAssert harness.fake.count("StartRecord") == 0
  doAssert harness.fake.count("StopRecord") == 1

proc testCustomProgramSceneRecording() =
  ## Record the human-selected WoW scene without selecting or rebinding Minecraft sources.
  let harness = newHarness(targets = true)
  defer: harness.close()
  doAssert harness.ready()
  harness.fake.scenes.add("wow")
  harness.fake.programScene = "wow"
  harness.fake.inputs = @[]
  harness.videoError = "Minecraft is not running."
  harness.audioError = "Minecraft audio is absent."
  let before = harness.fake.count("SetInputSettings")
  doAssert harness.command(1, "recordToggle")["ok"].getBool()
  doAssert harness.fake.recording
  doAssert harness.fake.programScene == "wow"
  doAssert harness.fake.count("SetCurrentProgramScene") == 0
  doAssert harness.fake.count("SetInputSettings") == before
  doAssert harness.command(2, "pauseToggle")["ok"].getBool()
  doAssert harness.fake.paused
  doAssert harness.command(3, "pauseToggle")["ok"].getBool()
  doAssert not harness.fake.paused
  doAssert harness.command(4, "recordToggle")["ok"].getBool()
  doAssert not harness.fake.recording
  doAssert harness.fake.count("StartRecord") == 1
  harness.fake.override = proc (socket: WebSocket, requestType, requestId: string,
      data: JsonNode): Future[bool] {.async, gcsafe.} =
    if requestType == "StartRecord":
      await socket.respond(requestType, requestId, ok = false, code = 500,
        comment = "Recording encoder unavailable.")
      result = true
  let failed = harness.command(5, "recordToggle")
  doAssert not failed["ok"].getBool()
  doAssert "Recording encoder unavailable" in failed["error"].getStr()
  doAssert not harness.fake.recording
  doAssert harness.fake.count("StartRecord") == 2

proc testStartRefusals() =
  ## Refuse to start the managed Minecraft scene without its application audio input.
  let harness = newHarness(targets = true)
  defer: harness.close()
  doAssert harness.ready()
  harness.fake.programScene = ObsSceneName
  harness.fake.inputs = @[("Minecraft Video", "xcomposite_input"),
    ("Commentary", "pulse_input_capture")]
  let missing = harness.command(2, "recordToggle")
  doAssert not missing["ok"].getBool()
  doAssert ObsAudioName in missing["error"].getStr()
  doAssert harness.fake.count("StartRecord") == 0
  doAssert not harness.fake.recording

proc testAudioCleanupWithEmptyTarget() =
  ## Reset capture mode and exclusion even when the audio target name is already empty.
  let harness = newHarness(targets = true)
  defer: harness.close()
  harness.fake.settings["Minecraft Audio"] = %*{"TargetName": "",
    "CaptureMode": 1, "ExceptApp": true}
  harness.audioError = AudioGuardFailure
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.connected and AudioGuardFailure in status.error)
  let audio = harness.fake.settings["Minecraft Audio"]
  doAssert audio["TargetName"].getStr() == ""
  doAssert audio["CaptureMode"].getInt() == 0
  doAssert not audio["ExceptApp"].getBool()
  let writes = harness.fake.count("SetInputSettings")
  pumpFor(CleanResyncWaitMs)
  doAssert harness.fake.count("SetInputSettings") == writes,
    "clean settings are not rewritten on every resync"


proc mutations(harness: Harness): int =
  ## Count requests that change OBS setup, outputs, mute, or capture settings.
  for request in ["SetCurrentProfile", "SetCurrentSceneCollection", "SetCurrentProgramScene",
      "StartRecord", "StopRecord", "PauseRecord", "ResumeRecord", "SetInputMute",
      "SetInputSettings", "CreateProfile", "CreateSceneCollection"]:
    result += harness.fake.count(request)

proc firefoxReady(harness: Harness): bool =
  ## Wait for the Firefox Demos pair to be recognized and captured.
  harness.waitStatus(proc (status: ObsStatus): bool =
    status.connected and status.activeProject == "firefox" and status.workspaceReady and
      status.captureReady and not status.minecraftReady)

proc testSwitchPairsBetweenRecordings() =
  ## Switch to Firefox Demos and back, recording each setup only through its own pair.
  let harness = newHarness(targets = true)
  defer: harness.close()
  doAssert harness.ready()
  doAssert harness.bridge.status.activeProject == "minecraft"
  doAssert harness.bridge.status.captureReady
  doAssert harness.command(1, "selectFirefox")["ok"].getBool()
  doAssert harness.fake.profile == FirefoxProfile
  doAssert harness.fake.collection == FirefoxProfile
  doAssert harness.fake.programScene == "Firefox"
  doAssert harness.firefoxReady()
  doAssert harness.fake.settings["Firefox Video"]["capture_window"].getStr() == FirefoxDemoWindow
  let audio = harness.fake.settings["Firefox Audio"]
  doAssert audio["TargetName"].getStr() == FirefoxAudioLabel
  doAssert audio["CaptureMode"].getInt() == 0 and not audio["ExceptApp"].getBool()
  doAssert audio["MatchPriorty"].getInt() == 1
  let statusLine = harness.statusLines()[^1]
  doAssert statusLine["activeProject"].getStr() == "firefox"
  doAssert statusLine["profile"].getStr() == FirefoxProfile
  doAssert not statusLine["minecraftReady"].getBool()
  doAssert harness.command(2, "recordToggle")["ok"].getBool()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.recording and not status.transitioning)
  let before = harness.mutations()
  for (id, operation) in [(3, "selectMinecraft"), (4, "selectFirefox")]:
    let refused = harness.command(id, operation)
    if operation == "selectMinecraft":
      doAssert not refused["ok"].getBool()
      doAssert "recording" in refused["error"].getStr(), refused["error"].getStr()
    else:
      doAssert refused["ok"].getBool(), "the selected setup is a no-op while recording"
  doAssert harness.command(5, "pauseToggle")["ok"].getBool()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = status.paused)
  let paused = harness.command(6, "selectMinecraft")
  doAssert not paused["ok"].getBool() and "recording" in paused["error"].getStr()
  doAssert harness.mutations() == before + 1, "only PauseRecord changed OBS"
  doAssert harness.command(7, "recordToggle")["ok"].getBool()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = not status.recording)
  doAssert harness.command(8, "selectMinecraft")["ok"].getBool()
  doAssert harness.fake.profile == ObsProfileName and harness.fake.programScene == ObsSceneName
  doAssert harness.ready()
  doAssert harness.bridge.status.activeProject == "minecraft"
  let idle = harness.mutations()
  doAssert harness.command(9, "selectMinecraft")["ok"].getBool()
  doAssert harness.mutations() == idle, "selecting the active setup changes nothing"
  doAssert harness.fake.count("SetInputMute") == 0
  doAssert harness.command(10, "recordToggle")["ok"].getBool()
  doAssert harness.fake.recording
  doAssert harness.fake.count("StartRecord") == 2

proc respondMalformed(field: string): FakeOverride =
  ## Answer one status request with a wrongly typed or missing field.
  result = proc (socket: WebSocket, requestType, requestId: string,
      data: JsonNode): Future[bool] {.async, gcsafe.} =
    if requestType == field:
      let body = if field == "GetRecordStatus": %*{"outputActive": "no", "outputPaused": false}
        else: %*{"outputActive": false}
      await socket.respond(requestType, requestId, body)
      result = true

proc testSelectionRefusals() =
  ## Refuse streaming, malformed, missing, and mid-switch output changes before mutating.
  let harness = newHarness(targets = true)
  defer: harness.close()
  doAssert harness.ready()
  pumpFor(100)
  let bound = harness.mutations()
  harness.fake.streaming = true
  let streaming = harness.command(1, "selectFirefox")
  doAssert not streaming["ok"].getBool() and "streaming" in streaming["error"].getStr()
  harness.fake.streaming = false
  harness.fake.reconnecting = true
  doAssert not harness.command(2, "selectFirefox")["ok"].getBool()
  harness.fake.reconnecting = false
  for (id, request) in [(3, "GetRecordStatus"), (4, "GetStreamStatus")]:
    harness.fake.override = respondMalformed(request)
    let malformed = harness.command(id, "selectFirefox")
    doAssert not malformed["ok"].getBool()
    doAssert "lacks" in malformed["error"].getStr(), malformed["error"].getStr()
  harness.fake.override = nil
  harness.fake.profiles = @[ObsProfileName]
  let missing = harness.command(5, "selectFirefox")
  doAssert not missing["ok"].getBool() and "does not exist" in missing["error"].getStr()
  doAssert harness.mutations() == bound
  harness.fake.profiles.add(FirefoxProfile)
  let fake = harness.fake
  fake.override = proc (socket: WebSocket, requestType, requestId: string,
      data: JsonNode): Future[bool] {.async, gcsafe.} =
    if requestType == "SetCurrentProfile":
      fake.recording = true
  let raced = harness.command(6, "selectFirefox")
  doAssert not raced["ok"].getBool()
  let error = raced["error"].getStr()
  doAssert "recording" in error and "profile \"Firefox Demos\"" in error and
    "scene collection \"Minecraft AI Demos\"" in error, error
  doAssert harness.fake.count("SetCurrentProfile") == 1
  doAssert harness.fake.count("SetCurrentSceneCollection") == 0
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.connected and status.activeProject == "" and not status.workspaceReady and
      status.recording)
  doAssert harness.command(7, "recordToggle")["ok"].getBool() == false
  doAssert harness.fake.count("StopRecord") == 0, "an unknown pair is never controlled"
  doAssert harness.fake.count("StartRecord") == 0

proc testSelectionNeverReplays() =
  ## A selection whose result was lost is reported unknown and never resent.
  let harness = newHarness(targets = true)
  defer: harness.close()
  doAssert harness.ready()
  harness.fake.hangupOn = @["SetCurrentSceneCollection"]
  let lost = harness.command(1, "selectFirefox")
  doAssert not lost["ok"].getBool() and "unknown" in lost["error"].getStr()
  harness.fake.hangupOn = @[]
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = status.connected)
  pumpFor(CleanResyncWaitMs)
  doAssert harness.fake.count("SetCurrentSceneCollection") == 1
  doAssert harness.fake.identifies == 2
  doAssert harness.bridge.status.activeProject == ""
  doAssert harness.fake.count("StartRecord") == 0

proc testUnknownPairNeverCaptures() =
  ## A half-matching pair is unrecognized: no capture binding, recording, or mic control.
  let harness = newHarness(targets = true)
  defer: harness.close()
  harness.fake.profile = FirefoxProfile
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.connected and "not a known setup" in status.error)
  pumpFor(100)
  let status = harness.bridge.status
  doAssert status.activeProject == "" and not status.workspaceReady and not status.captureReady
  for (id, operation) in [(1, "recordToggle"), (2, "micToggle"), (3, "pauseToggle")]:
    doAssert not harness.command(id, operation)["ok"].getBool()
  doAssert harness.mutations() == 0

proc testFirefoxCaptureIsolation() =
  ## Bind only the exact demo window and label; ambiguity or loss is unavailable.
  let harness = newHarness(targets = true)
  defer: harness.close()
  harness.firefoxPending = true
  doAssert harness.ready()
  doAssert harness.command(1, "selectFirefox")["ok"].getBool()
  doAssert harness.firefoxReady()
  doAssert harness.bridge.status.audioPending
  doAssert harness.statusLines()[^1]["audioPending"].getBool()
  harness.firefoxVideo = RetitledDemoWindow
  pumpFor(CleanResyncWaitMs)
  doAssert harness.fake.settings["Firefox Video"]["capture_window"].getStr() == FirefoxDemoWindow,
    "a page title change does not rebind the same window"
  harness.firefoxAudioError = FirefoxIsolationFailure
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    not status.captureReady and FirefoxIsolationFailure in status.error)
  doAssert harness.fake.settings["Firefox Audio"]["TargetName"].getStr() == ""
  let refused = harness.command(2, "recordToggle")
  doAssert not refused["ok"].getBool() and "also captures" in refused["error"].getStr()
  harness.firefoxAudioError = ""
  harness.firefoxVideoError = "Found 2 Firefox demo windows; refusing to guess."
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    not status.captureReady and "refusing to guess" in status.error)
  harness.firefoxVideoError = ""
  harness.firefoxVideo = ""
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    not status.captureReady and "not open" in status.error)
  doAssert not harness.command(3, "recordToggle")["ok"].getBool()
  doAssert harness.fake.count("StartRecord") == 0
  harness.firefoxVideo = FirefoxDemoWindow
  harness.firefoxPending = false
  doAssert harness.firefoxReady()
  doAssert not harness.bridge.status.audioPending
  doAssert harness.command(4, "recordToggle")["ok"].getBool()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = status.recording)
  let settled = harness.fake.count("SetInputSettings")
  harness.firefoxVideo = OtherDemoWindow
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.recording and not status.captureReady and "left unchanged" in status.error)
  harness.firefoxVideoError = "Found 2 Firefox demo windows; refusing to guess."
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.recording and "refusing to guess" in status.error)
  pumpFor(CleanResyncWaitMs)
  doAssert harness.fake.count("SetInputSettings") == settled, "recording never rebinds"
  doAssert harness.fake.settings["Firefox Video"]["capture_window"].getStr() == FirefoxDemoWindow
  doAssert harness.fake.settings["Firefox Audio"]["TargetName"].getStr() == FirefoxAudioLabel
  doAssert harness.command(5, "micToggle")["ok"].getBool()
  doAssert harness.fake.requestData[^1]["inputName"].getStr() == ObsMicName
  doAssert harness.command(6, "recordToggle")["ok"].getBool()
  doAssert not harness.fake.recording

proc testFirefoxSceneAndOpen() =
  ## Record a custom scene unchanged and keep the selected setup when opening OBS.
  let harness = newHarness(targets = true)
  defer: harness.close()
  doAssert harness.ready()
  doAssert harness.command(1, "selectFirefox")["ok"].getBool()
  doAssert harness.firefoxReady()
  harness.fake.scenes.add("Intro")
  harness.fake.programScene = "Intro"
  let scene = harness.command(2, "recordToggle")
  doAssert scene["ok"].getBool()
  doAssert harness.fake.programScene == "Intro" and harness.fake.recording
  doAssert harness.command(4, "recordToggle")["ok"].getBool()
  doAssert harness.command(3, "open")["ok"].getBool()
  doAssert harness.focuses == 1
  doAssert harness.fake.profile == FirefoxProfile and harness.fake.programScene == "Firefox"
  doAssert harness.fake.count("SetCurrentProfile") == 1
  doAssert harness.fake.count("StartRecord") == 1

proc testFirefox1080Offline() =
  ## Launch the dedicated demo when absent, otherwise resize or focus it, without OBS.
  let harness = newHarness(port = closedPort())
  defer: harness.close()
  doAssert harness.waitStatus(proc (status: ObsStatus): bool = not status.connected)
  doAssert harness.command(1, "firefox1080")["ok"].getBool()
  doAssert harness.firefoxLaunches == 1 and harness.firefoxResizes == 0
  harness.firefoxRunning = true
  doAssert harness.waitStatus(proc (status: ObsStatus): bool =
    status.firefoxRunning and not status.firefoxSized)
  doAssert harness.command(2, "firefox1080")["ok"].getBool()
  doAssert harness.firefoxLaunches == 1 and harness.firefoxResizes == 1
  doAssert harness.bridge.status.firefoxSized
  for (id, operation) in [(3, "selectFirefox"), (4, "selectMinecraft")]:
    let response = harness.command(id, operation)
    doAssert not response["ok"].getBool() and "not connected" in response["error"].getStr()
  doAssert harness.prismLaunches == 0 and harness.resizes == 0
  doAssert harness.fake.requests.len == 0

proc main() =
  ## Run bridge tests against a local fake OBS server.
  testCustomProgramSceneRecording()
  doAssert isMinecraftItem("xcomposite_input", "", MinecraftWindow)
  doAssert not isMinecraftItem("xcomposite_input", "", WikiWindow)
  doAssert not isMinecraftItem("pipewire_audio_application_capture", JavaApp, JavaApp)
  doAssert not isMinecraftItem("pipewire_audio_application_capture",
    "Minecraft Launcher", "Minecraft Launcher")
  doAssert isMinecraftItem("pipewire_audio_application_capture", MinecraftApp,
    MinecraftApp)
  doAssert minecraftTargetProperty("pulse_output_capture") == ""
  doAssert conciseError(TracedFailure) == PresenceFailure
  doAssert conciseError("") == ""
  let
    game = ClientWindow(id: 1, instance: "Minecraft* 1.20.1", class: "Minecraft* 1.20.1",
      width: TargetWidth, height: TargetHeight)
    launcher = ClientWindow(id: 2, instance: "prismlauncher", class: "PrismLauncher")
    server = ClientWindow(id: 3, instance: "java", class: "java")
  doAssert minecraftPresence([launcher, server]) == (running: false, sized: false)
  doAssert minecraftPresence([launcher, game]) == (running: true, sized: true)
  var fullscreen = game
  fullscreen.states = {wsFullscreen}
  doAssert minecraftPresence([fullscreen]) == (running: true, sized: false)
  var small = game
  small.width = 854
  doAssert minecraftPresence([small]) == (running: true, sized: false)
  doAssert minecraftPresence([game, small]) == (running: true, sized: false)
  testRecordWithActualState()
  testExternalStateIsAuthoritative()
  testMinecraftAbsent()
  testWorkspaceMismatch()
  testOpenPreservesActiveOutput()
  testOffline()
  testPresenceWhileOffline()
  testMinecraft1080Offline()
  testPresenceSurvivesConnectionChanges()
  testDisconnectNoReplay()
  testCommandValidation()
  testExactTargetsSkipPropertyLists()
  testWindowErrorsStayInHelper()
  testAudioGuardFailureWhileRecording()
  testStartRefusals()
  testAudioCleanupWithEmptyTarget()
  testSwitchPairsBetweenRecordings()
  testSelectionRefusals()
  testSelectionNeverReplays()
  testUnknownPairNeverCaptures()
  testFirefoxCaptureIsolation()
  testFirefoxSceneAndOpen()
  testFirefox1080Offline()
  doAssert sameXCompositeWindow(FirefoxDemoWindow, RetitledDemoWindow)
  doAssert not sameXCompositeWindow(FirefoxDemoWindow, OtherDemoWindow)
  doAssert not sameXCompositeWindow(WikiWindow, FirefoxDemoWindow)
  testBridgeProcess()

when isMainModule:
  main()

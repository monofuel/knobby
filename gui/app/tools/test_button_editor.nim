import
  std/[atomics, json, locks, os, osproc, strutils],
  pixie,
  knobby/[button_client, button_config, button_media, button_runtime, common, ipc, status],
  ../src/[button_editor_model, smoke_input]

const
  RepositoryAssets = currentSourcePath().parentDir().parentDir().parentDir().parentDir() / "assets"
  DeckAssets = RepositoryAssets / "stream_deck"
  ObsArtAssets = RepositoryAssets / "obs"
  ObsArtSources = [("default", "record-idle.png"), ("recording", "record-recording.png"),
    ("paused", "record-paused.png"), ("muted", "mic-muted.png"), ("unavailable", "record-unavailable.png")]
  ObsArtMenu = "obs-art"
  ObsArtManifestName = "obs-art.json"
  FramePaths = [DeckAssets / "3-normal.jpg", DeckAssets / "4-normal.jpg"]
  PressedPath = DeckAssets / "4-pressed.jpg"
  FrameMs = 150
  FailingTitle = "FAIL"
  BroadcastMs = 50
  PhaseTimeoutMs = 180_000
  PixelTolerance = 2
  AllowedRequests = ["subscribe", "config.get", "config.apply", "config.preview", "config.importAsset"]
  UnicodeTitle = "Música 日本 ✓ 🎵"
  MixerTitle = "Música ✓"
  AudioName = "Écouteurs"
  LiveDeckTitle = "Grüße"
  SubmittedTitle = "Submitted ✓"
  LateTitle = "Late ✓"
  LateCommand = "notify-send late"
  GateTimeoutMs = 120_000
  GatePollMs = 10
  StateFrames = [("recording", 5), ("paused", 6), ("muted", 10), ("unavailable", 9)]
  ObsKey = 6
  DrawerMenu = "deck-navigation"
  DrawerNumbers = [11, 12, 13, 14, 15]
  DrawerLowerKey = 8

var
  serverThread: Thread[void]
  serverStopping: Atomic[bool]
  requestLock: Lock
  requestKinds: seq[string]
  failedReloads: Atomic[int]

initLock(requestLock)

proc obsArtManifestPath(): string {.gcsafe.} =
  ## Locate the prepared OBS art manifest inside the smoke run's private state directory.
  getEnv("XDG_STATE_HOME") / ObsArtManifestName

proc loadObsArt(): JsonNode {.gcsafe.} =
  ## Return prepared OBS art by state when the art smoke is enabled, or nil for numbered fixtures.
  if fileExists(obsArtManifestPath()): parseFile(obsArtManifestPath()) else: nil

proc prepareObsArt(directory: string) =
  ## Render the committed OBS PNGs through the real media pipeline and record their frames by state.
  let
    configDir = directory / "obs-art"
    cacheDir = configDir / "prepared"
  createDir(cacheDir)
  var deck = newJArray()
  for index, (state, file) in ObsArtSources:
    deck.add(%*{"key": index + 1, "title": state, "action": {"kind": "none"},
      "visual": {"image": importButtonAsset(ObsArtAssets / file, configDir), "showTitle": false}})
  let
    config = %*{"version": 1, "root": ObsArtMenu,
      "menus": [{"id": ObsArtMenu, "title": "OBS art", "deck": deck}]}
    keys = prepareButtonMedia(config, configDir, cacheDir, knobbyFontPath())["menus"][ObsArtMenu]
  var art = newJObject()
  for index, (state, file) in ObsArtSources:
    art[state] = keys[$(index + 1)]
  for (state, file) in ObsArtSources:
    for (other, otherFile) in ObsArtSources:
      if state < other:
        doAssert readImage(art[state]["normal"][0]["path"].getStr()).data !=
          readImage(art[other]["normal"][0]["path"].getStr()).data,
          "Prepared OBS art for " & state & " and " & other & " is identical."
  writeFile(obsArtManifestPath(), $art)

proc fixturePrepare(config: JsonNode): JsonNode {.gcsafe.} =
  ## Describe fixture media for a candidate: built-in numbers, animated images, and a forced failure.
  let gate = smokeControlPath(ApplyGateName)
  if fileExists(gate):
    let blocked = smokeControlPath(ApplyBlockedName)
    writeFile(blocked, "")
    let deadline = monotonicMs() + GateTimeoutMs
    while fileExists(gate):
      if monotonicMs() > deadline:
        raise newException(IOError, "The fixture apply gate was never released.")
      sleep(GatePollMs)
    removeFile(blocked)
  let canonical = canonicalButtonConfig(config)
  result = %*{"version": 1, "menus": {}}
  for menu in canonical["menus"]:
    var keys = newJObject()
    for entry in menu{"deck"}.getElems():
      if entry{"title"}.getStr() == FailingTitle:
        raise newException(ValueError, "Fixture media cannot render the title " & FailingTitle & ".")
      let visual = entry{"visual"}
      if visual.isNil: continue
      if visual.hasKey("builtinNumber"):
        keys[$entry["key"].getInt()] = %*{"builtinNumber": visual["builtinNumber"]}
      elif visual{"image"}.getStr().len > 0:
        keys[$entry["key"].getInt()] = %*{
          "normal": [{"path": FramePaths[0], "durationMs": FrameMs},
            {"path": FramePaths[1], "durationMs": FrameMs}],
          "pressed": PressedPath}
      if entry{"action"}{"kind"}.getStr() == $ObsAction and keys.hasKey($entry["key"].getInt()):
        let
          prepared = keys[$entry["key"].getInt()]
          art = loadObsArt()
        prepared["obsOperation"] = entry["action"]["operation"]
        if not art.isNil:
          prepared["normal"] = art["default"]["normal"]
          prepared["pressed"] = art["default"]["pressed"]
        for (state, number) in StateFrames:
          if not visual{"states"}.isNil and visual["states"].hasKey(state):
            if not prepared.hasKey("states"): prepared["states"] = newJObject()
            prepared["states"][state] = if not art.isNil: art[state] else: %*{
              "normal": [{"path": DeckAssets / ($number & "-normal.jpg"), "durationMs": 0}],
              "pressed": DeckAssets / ($number & "-pressed.jpg")}
    result["menus"][menu["id"].getStr()] = keys

proc fixtureImport(source: string): string {.gcsafe.} =
  ## Copy a source image into managed assets under a content-derived name.
  let
    data = readFile(source)
    name = sha256Hex(data)[0..<16] & source.splitFile().ext.toLowerAscii()
    directory = buttonConfigDirectory() / "assets"
  createDir(directory)
  writeFile(directory / name, data)
  "assets/" & name

proc fakeObsStatus(): JsonNode =
  ## Report a connected OBS that is recording, or paused once the script creates its control file.
  let paused = fileExists(smokeControlPath(ObsPausedName))
  %*{"connected": true, "workspaceReady": true, "minecraftReady": true, "recording": true,
    "paused": paused, "micMuted": false, "transitioning": false, "error": "",
    "updatedMs": nowMs()}

proc stateMessage(): JsonNode =
  ## Build a complete status frame carrying the real button runtime status.
  var state = parseJson(encodeSnapshot(emptyMixer(), "editor-fixture", nowMs()))
  state["buttonConfig"] = buttonRuntimeStatus()
  state["catalog"] = activeMixerCatalog()
  state["audio"]["master"]["name"] = %AudioName
  state["audioUpdatedMs"] = %nowMs()
  state["obs"] = fakeObsStatus()
  %*{"version": ProtocolVersion, "type": "state", "state": state}

proc serveLoop() {.thread.} =
  ## Serve config requests and status like the daemon, recording every request type.
  {.cast(gcsafe).}:
    let server = newLocalServer(daemonSocketPath())
    defer: server.close()
    var
      lastBroadcast = 0'i64
      reloadArmed = false
    while not serverStopping.load():
      for request in server.pollRequests():
        let kind = request.message{"type"}.getStr()
        withLock requestLock: requestKinds.add(kind)
        if kind == "config.apply" and fileExists(smokeControlPath(FailReloadName)):
          reloadArmed = true
        if kind == "config.get" and reloadArmed:
          # Drop the reload that follows an armed apply, as a daemon disconnect would.
          reloadArmed = false
          removeFile(smokeControlPath(FailReloadName))
          failedReloads.atomicInc()
          request.peer.close()
        elif kind == "subscribe":
          request.peer.subscribed = true
        elif kind.startsWith("config."):
          request.peer.queueMessage(processConfigRequest(request.message))
        else:
          request.peer.close()
      if monotonicMs() - lastBroadcast >= BroadcastMs:
        server.broadcast(stateMessage())
        lastBroadcast = monotonicMs()
      sleep(5)

proc runPhase(binary, phase, directory, fixture: string) =
  ## Run one scripted GUI process to completion on the isolated display.
  let process = startProcess(binary, args = ["--editor-smoke", phase, directory / phase, fixture],
    options = {poParentStreams})
  defer: process.close()
  let code = process.waitForExit(PhaseTimeoutMs)
  if process.running():
    process.kill()
    raise newException(IOError, "Editor smoke phase " & phase & " timed out.")
  doAssert code == 0, "Editor smoke phase " & phase & " failed with exit code " & $code

proc requestCount(kind: string): int =
  ## Count requests of one type received so far.
  withLock requestLock:
    for received in requestKinds:
      if received == kind: inc result

proc rectOf(directory, capture, name: string): tuple[x, y, w, h: int] =
  ## Read a control's recorded bounds for a capture.
  let node = parseFile(directory / (capture & ".json"))[name]
  (node[0].getFloat().int, node[1].getFloat().int, node[2].getFloat().int, node[3].getFloat().int)

proc upright(path: string): Image =
  ## Decode a prepared key image and rotate it upright as the editor must display it.
  result = readImage(path)
  result.flipHorizontal()
  result.flipVertical()

proc matches(frame: Image, x, y: int, expected: Image): bool =
  ## Compare a native-size preview region against exact decoded key pixels.
  for row in 0..<expected.height:
    for column in 0..<expected.width:
      let
        actual = frame[x + column, y + row]
        wanted = expected[column, row]
      if abs(actual.r.int - wanted.r.int) > PixelTolerance or
          abs(actual.g.int - wanted.g.int) > PixelTolerance or
          abs(actual.b.int - wanted.b.int) > PixelTolerance:
        return false
  true

proc checkPreview(directory, capture, name: string, candidates: openArray[string]) =
  ## Require a preview slot to show one of the exact upright JPEG frames at native size.
  let
    frame = readImage(directory / (capture & ".png"))
    bounds = rectOf(directory, capture, name)
  doAssert bounds.w == 72 and bounds.h == 72
  for path in candidates:
    if frame.matches(bounds.x, bounds.y, upright(path)): return
  raise newException(AssertionDefect, name & " in " & capture & " does not show an exact upright prepared frame.")

proc checkBlack(directory, capture, name: string) =
  ## Require a preview slot to show the black face of a key without prepared artwork.
  let
    frame = readImage(directory / (capture & ".png"))
    bounds = rectOf(directory, capture, name)
  for y in bounds.y..<bounds.y + bounds.h:
    for x in bounds.x..<bounds.x + bounds.w:
      let pixel = frame[x, y]
      doAssert pixel.r.int + pixel.g.int + pixel.b.int <= PixelTolerance * 3,
        name & " in " & capture & " is not black at " & $x & ", " & $y

proc checkStableText(directory: string, captures: openArray[string], regions: openArray[(int, int, int, int)]) =
  ## Require unchanged text pixels across window sizes, proving reflow without atlas resampling.
  let reference = readImage(directory / (captures[0] & ".png"))
  for capture in captures[1..^1]:
    let image = readImage(directory / (capture & ".png"))
    for (left, top, width, height) in regions:
      for y in top..<top + height:
        for x in left..<left + width:
          doAssert image[x, y] == reference[x, y],
            "Text pixels changed in " & capture & " at " & $x & ", " & $y

proc deckEntry(config: JsonNode, menu: string, key: int): JsonNode =
  ## Read one stored Deck entry from canonical configuration.
  config.entryAt(menu, DeckDevice, key)

proc putEntry(menu: JsonNode, device: string, entry: JsonNode) =
  ## Replace or add one stored slot in a menu's device list.
  var entries = newJArray()
  for existing in menu{device}.getElems():
    if existing["key"] != entry["key"]: entries.add(existing)
  entries.add(entry)
  menu[device] = entries

proc mixerSlot(config: JsonNode, key: int): JsonNode =
  ## Read one root-menu mixer slot from a configuration.
  config.entryAt(config.rootMenu(), MixerDevice, key)

proc main() =
  ## Exercise the editor end to end against the real core runtime with fixture media.
  doAssert getEnv("KNOBBY_GUI_SMOKE") == "1"
  doAssert paramCount() == 2
  let
    binary = paramStr(1).absolutePath()
    directory = paramStr(2).absolutePath()
    fixture = directory / "fixture.png"
  putEnv("XDG_CONFIG_HOME", directory / "config")
  putEnv("XDG_STATE_HOME", directory / "state")
  createDir(directory)
  let image = newImage(96, 64)
  image.fill(rgba(210, 80, 40, 255))
  image.writeFile(fixture)
  let paths = newButtonPaths()
  initializeButtons(paths, ButtonServices(prepare: fixturePrepare, importAsset: fixtureImport))
  startButtonWorker()
  createThread(serverThread, serveLoop)
  defer:
    serverStopping.store(true)
    joinThread(serverThread)
    stopButtonWorker()
  let initialRevision = buttonRuntimeStatus()["revision"].getStr()

  runPhase(binary, "edit", directory, fixture)
  let draft = readDraft(draftPath())
  doAssert not draft.isNil, "The edit phase did not autosave its draft."
  doAssert draft["baseRevision"].getStr() == initialRevision
  let draftKey = draft["config"].deckEntry(RootMenuId, 7)
  doAssert draftKey["title"].getStr() == UnicodeTitle
  doAssert draftKey["action"] == %*{"kind": "command", "command": "true"}
  doAssert buttonRuntimeStatus()["revision"].getStr() == initialRevision,
    "Editing without Save & Apply changed the live configuration."
  checkPreview(directory / "edit", "deck", "preview:8", [DeckAssets / "8-normal.jpg"])
  checkPreview(directory / "edit", "deck", "preview:1", [DeckAssets / "1-normal.jpg"])

  var external = requireConfigResult(requestConfig("config.get"))["envelope"]
  external["config"]["menus"][0]["title"] = %"Elsewhere"
  discard runConfigOperation("config.apply", %*{"envelope": external})
  doAssert buttonRuntimeStatus()["revision"].getStr() != initialRevision

  runPhase(binary, "recover", directory, fixture)
  let applied = parseFile(paths.configPath())
  validateButtonConfig(applied)
  doAssert applied.menuTitle(RootMenuId) == "Main", "Keep my draft must replace the external change."
  doAssert applied.deckEntry(RootMenuId, 7)["title"].getStr() == UnicodeTitle
  doAssert applied.deckEntry(RootMenuId, 7)["action"]["command"].getStr() == "true"
  doAssert applied.deckEntry(RootMenuId, 3)["title"].getStr() == "OK ✓"
  doAssert applied.deckEntry(RootMenuId, 5)["action"] ==
    %*{"kind": "menu", "menu": "spiele", "target": "deck"}
  doAssert applied.menuTitle("spiele") == "Spiele 🎮"
  let imageKey = applied.deckEntry("spiele", 2)
  doAssert isManagedAssetPath(imageKey["visual"]["image"].getStr())
  doAssert fileExists(paths.configDir / imageKey["visual"]["image"].getStr())
  doAssert not imageKey["visual"]["showTitle"].getBool()
  doAssert applied.deckEntry("spiele", 1)["action"]["kind"].getStr() == "back"
  doAssert not fileExists(draftPath()), "A successful apply must remove the draft."
  checkPreview(directory / "recover", "image", "preview:2", FramePaths)
  checkPreview(directory / "recover", "image", "detailPreview:Normal", FramePaths)
  checkPreview(directory / "recover", "image", "detailPreview:Pressed", [PressedPath])
  checkStableText(directory / "recover",
    ["applied", "applied-small", "applied-odd", "applied-large"],
    [(20, 28, 165, 38), (12, 399, 166, 100)])

  var live = requireConfigResult(requestConfig("config.get"))["envelope"]
  for menu in live["config"]["menus"]:
    if menu["id"].getStr() == RootMenuId:
      menu.putEntry("mixer", %*{"key": 1, "title": MixerTitle, "action": {"kind": "none"}})
    elif menu["id"].getStr() == "spiele":
      menu.putEntry("deck", %*{"key": 3, "title": LiveDeckTitle, "action": {"kind": "home"}})
  discard runConfigOperation("config.apply", %*{"envelope": live})
  discard readDeckPage(0)
  deckPageReady()
  routeDeckButton(4, true)
  routeDeckButton(4, false)
  let
    liveStatus = buttonRuntimeStatus()
    liveConfig = readFile(paths.configPath())
    appliesBefore = requestCount("config.apply")
  doAssert liveStatus["deckMenu"].getStr() == "spiele" and liveStatus["mixerMenu"].getStr() == RootMenuId
  runPhase(binary, "live", directory, fixture)
  let after = buttonRuntimeStatus()
  doAssert after["revision"] == liveStatus["revision"] and after["deckMenu"].getStr() == "spiele",
    "Viewing the live Deck or editing a draft changed the active configuration or navigation."
  doAssert readFile(paths.configPath()) == liveConfig
  doAssert takeButtonActions().len == 0, "The viewer dispatched a button action."
  doAssert requestCount("config.apply") == appliesBefore
  let liveDraft = readDraft(draftPath())
  doAssert not liveDraft.isNil and not liveDraft["config"].deckEntry("spiele", 2).hasImage()
  let liveDirectory = directory / "live"
  checkPreview(liveDirectory, "live-deck", "liveArt:2", FramePaths)
  checkPreview(liveDirectory, "live-deck", "liveDetail:Normal", FramePaths)
  checkPreview(liveDirectory, "live-deck", "liveDetail:Pressed", [PressedPath])
  checkBlack(liveDirectory, "live-deck", "liveArt:1")
  checkBlack(liveDirectory, "live-draft", "preview:2")
  checkPreview(liveDirectory, "live-after-draft", "liveArt:2", FramePaths)
  checkPreview(liveDirectory, "live-after-draft", "liveDetail:Normal", FramePaths)
  checkPreview(liveDirectory, "live-after-draft", "liveDetail:Pressed", [PressedPath])

  removeDraft(draftPath())
  let appliesBeforePending = requestCount("config.apply")
  runPhase(binary, "pending", directory, fixture)
  let
    firstApply = requireConfigResult(requestConfig("config.get"))["envelope"]
    pendingDraft = readDraft(draftPath())
  doAssert requestCount("config.apply") == appliesBeforePending + 1
  doAssert parseFile(paths.configPath()) == firstApply["config"]
  doAssert firstApply["config"].mixerSlot(2)["title"].getStr() == SubmittedTitle,
    "The daemon must apply the configuration submitted before the late edits."
  doAssert firstApply["config"].mixerSlot(3)["action"]{"command"}.getStr() != LateCommand
  doAssert not pendingDraft.isNil, "Edits made while applying were not kept on disk."
  doAssert pendingDraft["baseRevision"] == firstApply["baseRevision"]
  doAssert pendingDraft["config"].mixerSlot(2)["title"].getStr() == LateTitle
  doAssert pendingDraft["config"].mixerSlot(3)["action"] ==
    %*{"kind": "command", "command": LateCommand}
  var recovered = newEditorModel()
  recovered.loadLive(firstApply)
  recovered.recoverDraft(pendingDraft)
  doAssert recovered.conflict == NoConflict and recovered.canApply()

  runPhase(binary, "reload", directory, fixture)
  let reapplied = parseFile(paths.configPath())
  doAssert failedReloads.load() == 1, "The reload after apply was not made to fail."
  doAssert reapplied.mixerSlot(2)["title"].getStr() == LateTitle
  doAssert reapplied.mixerSlot(3)["action"]["command"].getStr() == LateCommand
  doAssert buttonRuntimeStatus()["revision"].getStr() == configRevision(reapplied)
  doAssert not fileExists(draftPath()), "A successful apply must remove the draft."

  if getEnv("KNOBBY_OBS_ART_SMOKE") == "1":
    prepareObsArt(directory)
  var obsConfig = requireConfigResult(requestConfig("config.get"))["envelope"]
  let obsImage = fixtureImport(fixture)
  for menu in obsConfig["config"]["menus"]:
    if menu["id"].getStr() == RootMenuId:
      menu.putEntry("deck", %*{"key": ObsKey, "title": "Rec",
        "action": {"kind": "obs", "operation": "recordToggle"},
        "visual": {"image": obsImage, "states": {"recording": obsImage, "paused": obsImage}}})
  discard runConfigOperation("config.apply", %*{"envelope": obsConfig})
  discard readDeckPage(0)
  deckPageReady()
  if buttonRuntimeStatus()["deckMenu"].getStr() != RootMenuId:
    routeDeckButton(0, true)
    routeDeckButton(0, false)
  discard takeButtonActions()
  let
    obsStatus = buttonRuntimeStatus()
    obsLiveConfig = readFile(paths.configPath())
    appliesBeforeObs = requestCount("config.apply")
  doAssert obsStatus["deckMenu"].getStr() == RootMenuId
  runPhase(binary, "obs", directory, fixture)
  doAssert buttonRuntimeStatus()["revision"] == obsStatus["revision"] and
    readFile(paths.configPath()) == obsLiveConfig, "Choosing a preview state changed the live configuration."
  doAssert requestCount("config.apply") == appliesBeforeObs
  doAssert takeButtonActions().len == 0, "The viewer dispatched a button action."
  let
    obsDirectory = directory / "obs"
    obsDraft = readDraft(draftPath())
    obsArt = loadObsArt()
    stateFrame = proc (state: string, kind = "normal"): string =
      if not obsArt.isNil:
        if kind == "pressed": obsArt[state]["pressed"].getStr()
        else: obsArt[state]["normal"][0]["path"].getStr()
      else:
        var number = 0
        for (name, frame) in StateFrames:
          if name == state: number = frame
        DeckAssets / ($number & "-" & kind & ".jpg")
  doAssert not obsDraft.isNil, "OBS edits were not autosaved."
  let
    draftObsKey = obsDraft["config"].deckEntry(RootMenuId, ObsKey)
    draftPauseKey = obsDraft["config"].deckEntry(RootMenuId, ObsKey + 1)
  doAssert draftObsKey["action"] == %*{"kind": "obs", "operation": "recordToggle"}
  doAssert draftObsKey["visual"]["image"].getStr() == obsImage
  doAssert draftObsKey["visual"]["states"]["paused"].getStr() == obsImage
  doAssert isManagedAssetPath(draftObsKey["visual"]["states"]["unavailable"].getStr())
  doAssert draftPauseKey["action"] == %*{"kind": "obs", "operation": "pauseToggle"}
  validateButtonConfig(obsDraft["config"])
  checkPreview(obsDirectory, "obs-live-recording", "liveArt:6", [stateFrame("recording")])
  checkPreview(obsDirectory, "obs-live-recording", "liveDetail:Normal", [stateFrame("recording")])
  checkPreview(obsDirectory, "obs-live-recording", "liveDetail:Pressed", [stateFrame("recording", "pressed")])
  checkPreview(obsDirectory, "obs-live-paused", "liveArt:6", [stateFrame("paused")])
  checkPreview(obsDirectory, "obs-draft-paused", "preview:6", [stateFrame("paused")])
  checkPreview(obsDirectory, "obs-draft-paused", "detailPreview:Normal", [stateFrame("paused")])
  checkPreview(obsDirectory, "obs-draft-paused", "detailPreview:Pressed", [stateFrame("paused", "pressed")])
  checkPreview(obsDirectory, "obs-draft-unavailable", "preview:6", [stateFrame("unavailable")])
  checkPreview(obsDirectory, "obs-live-after", "liveArt:6", [stateFrame("paused")])
  checkPreview(obsDirectory, "obs-live-after", "liveDetail:Pressed", [stateFrame("paused", "pressed")])
  if not obsArt.isNil:
    checkPreview(obsDirectory, "obs-editor", "preview:6", [stateFrame("default")])
  removeFile(smokeControlPath(ObsPausedName))

  var drawerConfig = requireConfigResult(requestConfig("config.get"))["envelope"]
  var navigation = %*{"id": DrawerMenu, "title": "Menu", "mixer": [], "deck": [
    {"key": 1, "title": "Menu", "action": {"kind": "deckMenu", "menu": DrawerMenu},
      "visual": {"builtinNumber": DrawerNumbers[0], "showTitle": false}}]}
  for key in 2..DrawerKeyCount:
    navigation["deck"].add(%*{"key": key, "title": "Go " & $key,
      "action": {"kind": "menu", "menu": RootMenuId, "target": "deck"},
      "visual": {"builtinNumber": DrawerNumbers[key - 1], "showTitle": false}})
  drawerConfig["config"]["menus"].add(navigation)
  for menu in drawerConfig["config"]["menus"]:
    if menu["id"].getStr() == RootMenuId:
      menu.putEntry("deck", %*{"key": 1, "title": "Menu",
        "action": {"kind": "deckMenu", "menu": DrawerMenu},
        "visual": {"builtinNumber": 1, "showTitle": false}})
  discard runConfigOperation("config.apply", %*{"envelope": drawerConfig})
  discard readDeckPage(0)
  deckPageReady()
  let toggled = processDeckNavigationRequest(%*{"version": ProtocolVersion,
    "type": DeckNavigationRequest, "operation": "toggle"})
  doAssert toggled["ok"].getBool() and toggled["deckDrawer"].getStr() == DrawerMenu
  doAssert takeButtonActions().len == 0, "Opening the drawer queued an action."
  let
    drawerDraft = readDraft(draftPath())
    lowerEntry = drawerConfig["config"].deckEntry(RootMenuId, DrawerLowerKey)
    appliesBeforeDrawer = requestCount("config.apply")
  runPhase(binary, "drawer", directory, fixture)
  doAssert requestCount("config.apply") == appliesBeforeDrawer
  doAssert buttonRuntimeStatus()["deckDrawer"].getStr() == DrawerMenu,
    "The viewer changed the Deck drawer."
  doAssert readDraft(draftPath())["config"] == drawerDraft["config"], "Viewing the drawer lost the draft."
  let drawerDirectory = directory / "drawer"
  for key in 1..DrawerKeyCount:
    checkPreview(drawerDirectory, "drawer-open", "liveArt:" & $key,
      [DeckAssets / ($DrawerNumbers[key - 1] & "-normal.jpg")])
  checkPreview(drawerDirectory, "drawer-open", "liveDetail:Pressed",
    [DeckAssets / ($DrawerNumbers[0] & "-pressed.jpg")])
  if not lowerEntry{"visual"}{"builtinNumber"}.isNil:
    checkPreview(drawerDirectory, "drawer-open", "liveArt:" & $DrawerLowerKey,
      [DeckAssets / ($lowerEntry["visual"]["builtinNumber"].getInt() & "-normal.jpg")])
  doAssert processDeckNavigationRequest(%*{"version": ProtocolVersion,
    "type": DeckNavigationRequest, "operation": "cancel"})["ok"].getBool()
  withLock requestLock:
    for kind in requestKinds:
      doAssert kind in AllowedRequests, "Editor sent an unexpected request: " & kind
    doAssert "config.apply" in requestKinds and "config.importAsset" in requestKinds
  echo "Button editor checks passed."

when isMainModule:
  main()

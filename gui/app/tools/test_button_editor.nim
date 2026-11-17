import
  std/[atomics, json, locks, os, osproc, strutils],
  pixie,
  knobby/[button_client, button_config, button_runtime, ipc, status],
  ../src/button_editor_model

const
  DeckAssets = currentSourcePath().parentDir().parentDir().parentDir().parentDir() /
    "assets" / "stream_deck"
  FramePaths = [DeckAssets / "3-normal.jpg", DeckAssets / "4-normal.jpg"]
  PressedPath = DeckAssets / "4-pressed.jpg"
  FrameMs = 150
  FailingTitle = "FAIL"
  BroadcastMs = 50
  PhaseTimeoutMs = 180_000
  PixelTolerance = 2
  AllowedRequests = ["subscribe", "config.get", "config.apply", "config.preview", "config.importAsset"]
  UnicodeTitle = "Música 日本 ✓ 🎵"

var
  serverThread: Thread[void]
  serverStopping: Atomic[bool]
  requestLock: Lock
  requestKinds: seq[string]

initLock(requestLock)

proc fixturePrepare(config: JsonNode): JsonNode {.gcsafe.} =
  ## Describe fixture media for a candidate: built-in numbers, animated images, and a forced failure.
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

proc stateMessage(): JsonNode =
  ## Build a complete status frame carrying the real button runtime status.
  var state = parseJson(encodeSnapshot(emptyMixer(), "editor-fixture", nowMs()))
  state["buttonConfig"] = buttonRuntimeStatus()
  %*{"version": ProtocolVersion, "type": "state", "state": state}

proc serveLoop() {.thread.} =
  ## Serve config requests and status like the daemon, recording every request type.
  {.cast(gcsafe).}:
    let server = newLocalServer(daemonSocketPath())
    defer: server.close()
    var lastBroadcast = 0'i64
    while not serverStopping.load():
      for request in server.pollRequests():
        let kind = request.message{"type"}.getStr()
        withLock requestLock: requestKinds.add(kind)
        if kind == "subscribe":
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
  withLock requestLock:
    for kind in requestKinds:
      doAssert kind in AllowedRequests, "Editor sent an unexpected request: " & kind
    doAssert "config.apply" in requestKinds and "config.importAsset" in requestKinds
  echo "Button editor checks passed."

when isMainModule:
  main()

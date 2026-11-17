import
  std/[json, os, unittest],
  knobby/[button_config, button_runtime, daemon_workers, status, stream_deck,
    stream_deck_page]

type
  FakeDeck = ref object
    writeLimit: int
    script: seq[string]
    disconnectMenu: string
    reports: seq[string]
    closes: int

const
  NoWriteLimit = -1
  PermissionDenied = "Permission denied"
  UploadDisconnect = "No such device\nAdditional info: /dev/hidraw3"
  IdleDisconnect = "No such device\nAdditional info: Stream Deck disconnected."
  MaxDiscoveries = 50

proc builtinPrepare(config: JsonNode): JsonNode {.gcsafe.} =
  ## Prepare every menu as embedded images, numbered differently per menu.
  result = %*{"version": 1, "menus": {}}
  for menu in config["menus"]:
    var keys = newJObject()
    for key in 1..DeckKeyCount:
      let number = if menu["id"].getStr() == RootMenuId: key else: DeckKeyCount + 1 - key
      keys[$key] = %*{"builtinNumber": number}
    result["menus"][menu["id"].getStr()] = keys

proc unusedImport(source: string): string {.gcsafe.} =
  ## Reject asset imports, which these tests never request.
  raise newException(IOError, "Unexpected import of " & source)

proc deckConfig(): JsonNode =
  ## Describe a Deck-only submenu and a command key that is held during a disconnect.
  %*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Main", "mixer": [],
      "deck": [
        {"key": 5, "title": "Deck B", "action": {"kind": "menu", "menu": "b", "target": "deck"}}]},
    {"id": "b", "title": "B", "mixer": [],
      "deck": [
        {"key": 6, "title": "Home", "action": {"kind": "home"}},
        {"key": 7, "title": "Echo", "action": {"kind": "command", "command": "echo held"}}]}]}

proc keyReport(pressed: openArray[int]): string =
  ## Construct a complete MK.2 key-state report with the given zero-based keys held.
  result = newString(4 + StreamDeckKeyCount)
  result[0] = '\x01'
  result[2] = chr(StreamDeckKeyCount)
  for key in pressed:
    result[4 + key] = '\x01'

proc newFakeDeck(writeLimit = NoWriteLimit, script: seq[string] = @[],
    disconnectMenu = ""): FakeDeck =
  ## Create a fake device that fails during upload or after its script on a menu.
  FakeDeck(writeLimit: writeLimit, script: script, disconnectMenu: disconnectMenu)

proc transport(fake: FakeDeck): StreamDeckIo =
  ## Supply hardware-free report I/O whose input follows the runtime's readiness.
  StreamDeckIo(
    readReport: proc (timeoutMs: int): string =
      ## Deliver scripted key states once the current page is ready, then disconnect.
      {.cast(gcsafe).}:
        let status = buttonRuntimeStatus()
        if status["deckReady"].getBool():
          if fake.script.len > 0:
            result = fake.script[0]
            fake.script.delete(0)
          elif status["deckMenu"].getStr() == fake.disconnectMenu:
            raise newException(OSError, IdleDisconnect),
    writeReport: proc (report: string): int =
      ## Accept image reports until the configured disconnect point.
      if fake.writeLimit != NoWriteLimit and fake.reports.len >= fake.writeLimit:
        raise newException(OSError, UploadDisconnect)
      fake.reports.add(report)
      result = report.len,
    sendFeature: proc (report: string): int =
      ## Accept brightness and logo feature reports.
      result = report.len,
    close: proc () =
      ## Count session closes.
      inc fake.closes)

proc firstReport(fake: FakeDeck, keyIndex: int): string =
  ## Return the first image report written for a key.
  for report in fake.reports:
    if ord(report[2]) == keyIndex:
      return report

proc uploadedKeys(fake: FakeDeck): int =
  ## Count the keys that received at least one image report.
  for key in 0..<StreamDeckKeyCount:
    if fake.firstReport(key).len > 0:
      inc result

suite "Stream Deck supervisor recovery":
  test "rediscovers, retries, restores the current page, and logs each failure":
    let root = getTempDir() / ("knobby-deck-recovery-" & $getCurrentProcessId())
    removeDir(root)
    let paths = newButtonPaths(root / "config", root / "state")
    createDir(paths.configDir)
    createDir(paths.stateDir)
    defer: removeDir(root)
    writeFileAtomic(paths.configPath(), encodeConfigFile(deckConfig()))
    initializeButtons(paths, ButtonServices(prepare: builtinPrepare, importAsset: unusedImport))
    initializeState("deck-recovery-test")
    let
      uploadFailure = newFakeDeck(writeLimit = 2)
      navigated = newFakeDeck(script = @[keyReport([4]), keyReport([])], disconnectMenu = "b")
      restored = newFakeDeck(script = @[keyReport([6])], disconnectMenu = "b")
    var
      discoveries = @["", "/dev/hidraw3", "/dev/hidraw3", "", "/dev/hidraw7", "/dev/hidraw7"]
      discoverCalls = 0
      opens: seq[string]
      logs: seq[string]
      decks = @[uploadFailure, navigated, restored]
    let driver = DeckDriver(
      discover: proc (): string =
        ## Replay node changes, absence, and reappearance.
        inc discoverCalls
        if discoveries.len > 0:
          result = discoveries[0]
          discoveries.delete(0),
      open: proc (path: string): StreamDeck =
        ## Fail the first open like a udev permission race, then hand out fakes.
        opens.add(path)
        if opens.len == 1:
          raise newException(OSError, PermissionDenied)
        result = newStreamDeck(decks[0].transport())
        decks.delete(0),
      log: proc (message: string) =
        ## Capture service log lines.
        logs.add(message),
      retryMs: 0)
    superviseDeck(driver, proc (): bool =
      ## Stop once the last fake session has closed, or if recovery loops.
      restored.closes > 0 or discoverCalls > MaxDiscoveries)
    check opens == @["/dev/hidraw3", "/dev/hidraw3", "/dev/hidraw7", "/dev/hidraw7"]
    check logs == @[
      "Stream Deck unavailable: " & PermissionDenied,
      "Stream Deck unavailable: " & UploadDisconnect,
      "Stream Deck connected at /dev/hidraw7.",
      "Stream Deck unavailable: " & IdleDisconnect,
      "Stream Deck connected at /dev/hidraw7.",
      "Stream Deck unavailable: " & IdleDisconnect]
    check uploadFailure.reports.len == 2
    check uploadFailure.closes == 1
    check navigated.closes == 1
    check navigated.firstReport(0) == encodeKeyImageReports(0, builtinNormalImage(1))[0]
    check restored.uploadedKeys() == StreamDeckKeyCount
    check restored.firstReport(0) ==
      encodeKeyImageReports(0, builtinNormalImage(StreamDeckKeyCount))[0]
    let state = readKnobbyState()
    check not state.deckConnected
    check state.deckError == IdleDisconnect
    check state.deckHeld == default(StreamDeckKeys)
    check not buttonRuntimeStatus()["deckReady"].getBool()
    check buttonRuntimeStatus()["deckMenu"].getStr() == "b"

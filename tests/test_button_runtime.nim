import
  std/[atomics, json, os, strutils, unittest],
  knobby/[bindings, button_config, button_runtime, ipc, obs_state]

const
  FailTitle = "FAIL"
  BlockTitle = "BLOCK"
  WaitLimitMs = 10000

var
  gateOpen: Atomic[bool]
  prepareCalls: Atomic[int]
  maintenanceCalls: Atomic[int]
  deckSeen: int64
  directoryCounter: int

proc fakePrepare(config: JsonNode): JsonNode {.gcsafe.} =
  ## Return a fake manifest per key, failing or blocking when a menu title asks for it.
  prepareCalls.atomicInc()
  result = %*{"version": 1, "menus": {}}
  for menu in config["menus"]:
    let title = menu["title"].getStr()
    if title == FailTitle:
      raise newException(IOError, "ffmpeg exploded")
    if title == BlockTitle:
      while not gateOpen.load():
        sleep(2)
    var keys = newJObject()
    for key in 1..DeckKeyCount:
      let path = "/prepared/" & menu["id"].getStr() & "-" & $key
      keys[$key] = %*{"normal": [{"path": path & ".jpg", "durationMs": 100}],
        "pressed": path & "-pressed.jpg"}
    result["menus"][menu["id"].getStr()] = keys

proc fakeImport(source: string): string {.gcsafe.} =
  ## Pretend to copy an asset, failing on request.
  if source.endsWith("broken.gif"):
    raise newException(IOError, "ffprobe rejected the file")
  if source.endsWith("escape.png"):
    return "../escape.png"
  "assets/" & sha256Hex(source)[0..15] & ".png"

proc fakeServices(): ButtonServices =
  ## Inject hardware-free media services.
  ButtonServices(prepare: fakePrepare, importAsset: fakeImport)

proc failingMaintenance() {.gcsafe.} =
  ## Simulate a cache cleanup failure after a completed configuration transaction.
  maintenanceCalls.atomicInc()
  raise newException(IOError, "Fixture cleanup failure.")

proc navConfig(): JsonNode =
  ## Describe three menus exercising linked, mixer-only, and Deck-only transitions.
  %*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Main",
      "mixer": [
        {"key": 2, "title": "Both A", "action": {"kind": "menu", "menu": "a", "target": "both"}},
        {"key": 3, "title": "Mixer A", "action": {"kind": "menu", "menu": "a", "target": "mixer"}},
        {"key": 5, "title": "Echo", "action": {"kind": "command", "command": "echo root"}},
        {"key": 12, "title": "Grok", "action": {"kind": "grok"}}],
      "deck": [
        {"key": 2, "title": "Both A", "action": {"kind": "menu", "menu": "a", "target": "both"}},
        {"key": 5, "title": "Deck B", "action": {"kind": "menu", "menu": "b", "target": "deck"}},
        {"key": 7, "title": "Discord", "action": {"kind": "discord"}}]},
    {"id": "a", "title": "A",
      "mixer": [
        {"key": 2, "title": "Both B", "action": {"kind": "menu", "menu": "b", "target": "both"}},
        {"key": 4, "title": "Mixer B", "action": {"kind": "menu", "menu": "b", "target": "mixer"}},
        {"key": 5, "title": "Both A", "action": {"kind": "menu", "menu": "a", "target": "both"}}],
      "deck": [
        {"key": 3, "title": "Deck B", "action": {"kind": "menu", "menu": "b", "target": "deck"}}]},
    {"id": "b", "title": "B",
      "mixer": [
        {"key": 4, "title": "Mixer A", "action": {"kind": "menu", "menu": "a", "target": "mixer"}},
        {"key": 6, "title": "Home", "action": {"kind": "home"}}],
      "deck": [
        {"key": 6, "title": "Home", "action": {"kind": "home"}}]}]}

proc cycleConfig(): JsonNode =
  ## Describe a three-menu mixer cycle whose forward transitions legitimately grow history.
  result = %*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Main", "mixer": [
      {"key": 9, "title": "Next", "action": {"kind": "menu", "menu": "a", "target": "mixer"}}],
      "deck": []}]}
  for (id, next, previous) in [("a", "b", "c"), ("b", "c", "a"), ("c", "a", "b")]:
    result["menus"].add(%*{"id": id, "title": id, "deck": [], "mixer": [
      {"key": 6, "title": "Home", "action": {"kind": "home"}},
      {"key": 9, "title": "Next", "action": {"kind": "menu", "menu": next, "target": "mixer"}},
      {"key": 10, "title": "Previous", "action": {"kind": "menu", "menu": previous, "target": "mixer"}}]})

proc reciprocalConfig(): JsonNode =
  ## Describe two menus linking to each other through Deck-only, mixer-only, and linked keys.
  result = %*{"version": 1, "root": "root", "menus": []}
  for (id, other) in [("root", "x"), ("x", "y"), ("y", "x")]:
    result["menus"].add(%*{"id": id, "title": id,
      "mixer": [
        {"key": 2, "title": "Both", "action": {"kind": "menu", "menu": other, "target": "both"}},
        {"key": 3, "title": "Mixer", "action": {"kind": "menu", "menu": other, "target": "mixer"}},
        {"key": 6, "title": "Home", "action": {"kind": "home"}}],
      "deck": [
        {"key": 4, "title": "Deck", "action": {"kind": "menu", "menu": other, "target": "deck"}}]})

proc newPaths(): ButtonPaths =
  ## Create empty private config and state directories for one test.
  inc directoryCounter
  let root = getTempDir() / ("knobby-runtime-" & $getCurrentProcessId() & "-" & $directoryCounter)
  removeDir(root)
  result = newButtonPaths(root / "config", root / "state")
  createDir(result.configDir)
  createDir(result.stateDir)

proc start(paths: ButtonPaths, services = fakeServices()) =
  ## Initialize the runtime against private directories and start its worker.
  gateOpen.store(true)
  deckSeen = 0
  initializeButtons(paths, services)
  startButtonWorker()

proc finish(paths: ButtonPaths) =
  ## Stop the worker and delete the private directories.
  gateOpen.store(true)
  stopButtonWorker()
  for path in [paths.configDir, paths.stateDir]:
    if dirExists(path):
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
  removeDir(paths.configDir.parentDir())

proc status(): JsonNode =
  ## Read the runtime status.
  buttonRuntimeStatus()

proc revision(): string =
  ## Return the active revision.
  status()["revision"].getStr()

proc request(kind: string, fields: JsonNode = newJObject()): JsonNode =
  ## Send a versioned request directly to the runtime.
  var message = %*{"version": ProtocolVersion, "type": kind}
  for key, value in fields:
    message[key] = value
  processConfigRequest(message)

proc awaitOperation(reply: JsonNode): JsonNode =
  ## Wait for an accepted operation to reach a terminal state.
  check reply["ok"].getBool()
  let id = reply["operationId"].getStr()
  for _ in 0..<WaitLimitMs div 5:
    result = buttonOperation(id)
    if not result.isNil and result["status"].getStr() in ["succeeded", "failed"]:
      return
    sleep(5)
  raise newException(IOError, "Operation did not finish: " & id)

proc apply(config: JsonNode, base = revision()): JsonNode =
  ## Submit an apply request based on a revision.
  request("config.apply", %*{"envelope": {"baseRevision": base, "config": config}})

proc press(device: ButtonDevice, key: int) =
  ## Press and release one key.
  if device == MixerDevice:
    routeMixerButton(key, true)
    routeMixerButton(key, false)
  else:
    routeDeckButton(key - 1, true)
    routeDeckButton(key - 1, false)

proc syncDeck() =
  ## Act as the Deck player: read any new page and report it uploaded.
  let page = readDeckPage(deckSeen)
  if not page.isNil:
    deckSeen = page["generation"].getBiggestInt()
  deckPageReady()

proc menus(): (string, string) =
  ## Return the current mixer and Deck menus.
  let current = status()
  (current["mixerMenu"].getStr(), current["deckMenu"].getStr())

proc kinds(actions: seq[JsonNode]): seq[string] =
  ## Extract action kinds in queue order.
  for action in actions:
    result.add(action["action"]["kind"].getStr())

suite "Button runtime":
  test "first start uses defaults, writes nothing canonical, and captures ordered actions":
    let paths = newPaths()
    start(paths)
    defer: finish(paths)
    check status()["source"].getStr() == "defaults"
    check status()["startupError"].getStr() == ""
    check revision() == configRevision(defaultButtonConfig())
    check not fileExists(paths.configPath())
    check activeMixerCatalog() == bindingCatalog()
    for note in [12, 9, 10, 11, 8, 1, 2]:
      press(MixerDevice, note)
    let actions = takeButtonActions()
    check kinds(actions) == @["grok", "claude", "ffxiv", "microphones", "discord"]
    for index, action in actions:
      check action["device"].getStr() == "mixer"
      check action["menu"].getStr() == RootMenuId
      check action["revision"].getStr() == revision()
      if index > 0:
        check action["sequence"].getBiggestInt() > actions[index - 1]["sequence"].getBiggestInt()
    check actions[0]["key"].getInt() == 12
    check actions[0]["title"].getStr() == "Grok"
    check takeButtonActions().len == 0
    routeMixerButton(0, true)
    routeMixerButton(13, true)
    routeDeckButton(15, true)
    check takeButtonActions().len == 0

  test "linked Back restores both devices and drops dependent Deck transitions":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    check status()["source"].getStr() == "canonical"
    syncDeck()
    press(MixerDevice, 2)
    check menus() == ("a", "a")
    check not status()["deckReady"].getBool()
    routeDeckButton(2, true)
    check menus() == ("a", "a")
    syncDeck()
    routeDeckButton(2, true)
    check menus() == ("a", "a")
    routeDeckButton(2, false)
    press(DeckDevice, 3)
    check menus() == ("a", "b")
    check status()["historyDepth"].getInt() == 2
    syncDeck()
    press(MixerDevice, 1)
    check menus() == ("root", "root")
    check status()["historyDepth"].getInt() == 0
    check takeButtonActions().len == 0

  test "independent Back leaves the other device in its menu":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    syncDeck()
    press(MixerDevice, 3)
    check menus() == ("a", "root")
    press(DeckDevice, 5)
    check menus() == ("a", "b")
    syncDeck()
    press(MixerDevice, 1)
    check menus() == ("root", "b")
    press(DeckDevice, 1)
    check menus() == ("root", "root")
    press(DeckDevice, 1)
    check menus() == ("root", "root")

  test "Home returns both devices to root and clears independent histories":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    syncDeck()
    press(MixerDevice, 3)
    press(DeckDevice, 5)
    syncDeck()
    press(MixerDevice, 4)
    check menus() == ("b", "b")
    check status()["historyDepth"].getInt() == 3
    let generation = status()["deckGeneration"].getBiggestInt()
    press(MixerDevice, 6)
    check menus() == ("root", "root")
    check status()["historyDepth"].getInt() == 0
    check status()["deckGeneration"].getBiggestInt() > generation
    press(MixerDevice, 1)
    check menus() == ("root", "root")
    press(MixerDevice, 2)
    press(MixerDevice, 2)
    syncDeck()
    check menus() == ("b", "b")
    press(DeckDevice, 6)
    check menus() == ("root", "root")
    check status()["historyDepth"].getInt() == 0
    check takeButtonActions().len == 0

  test "a linked menu records both devices when only one changes":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    syncDeck()
    press(MixerDevice, 3)
    check menus() == ("a", "root")
    press(DeckDevice, 2)
    check menus() == ("a", "a")
    check status()["historyDepth"].getInt() == 2
    press(MixerDevice, 5)
    check menus() == ("a", "a")
    check status()["historyDepth"].getInt() == 2
    syncDeck()
    press(MixerDevice, 1)
    check menus() == ("a", "root")
    check status()["historyDepth"].getInt() == 1
    press(MixerDevice, 1)
    check menus() == ("root", "root")
    check status()["historyDepth"].getInt() == 0

  test "repeated pressed reports while a key is held act once":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    syncDeck()
    for _ in 1..3:
      routeMixerButton(5, true)
    for _ in 1..3:
      routeDeckButton(6, true)
    check takeButtonActions().len == 2
    routeMixerButton(5, false)
    routeDeckButton(6, false)
    routeMixerButton(5, true)
    routeMixerButton(5, true)
    routeDeckButton(6, true)
    let actions = takeButtonActions()
    check kinds(actions) == @["command", "discord"]
    check actions[0]["action"]["command"].getStr() == "echo root"

  test "navigation beyond the history limit is rejected without changing state":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(cycleConfig()))
    start(paths)
    defer: finish(paths)
    syncDeck()
    for _ in 1..MaxNavigationHistory:
      press(MixerDevice, 9)
    check status()["historyDepth"].getInt() == MaxNavigationHistory
    check menus() == ("b", "root")
    let generation = status()["deckGeneration"].getBiggestInt()
    for _ in 1..2:
      try:
        routeMixerButton(9, true)
        check false
      except IOError as error:
        check "limited to " & $MaxNavigationHistory in error.msg
      routeMixerButton(9, false)
    check menus() == ("b", "root")
    check status()["historyDepth"].getInt() == MaxNavigationHistory
    check status()["deckGeneration"].getBiggestInt() == generation
    press(MixerDevice, 10)
    check menus() == ("a", "root")
    check status()["historyDepth"].getInt() == MaxNavigationHistory - 1
    press(MixerDevice, 9)
    check menus() == ("b", "root")
    press(MixerDevice, 1)
    check menus() == ("a", "root")
    check status()["historyDepth"].getInt() == MaxNavigationHistory - 1
    press(MixerDevice, 6)
    check menus() == ("root", "root")
    check status()["historyDepth"].getInt() == 0

  test "reciprocal menu links undo their own transition so history stays bounded":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(reciprocalConfig()))
    start(paths)
    defer: finish(paths)
    syncDeck()
    press(DeckDevice, 4)
    syncDeck()
    check menus() == ("root", "x")
    for _ in 1..100:
      press(DeckDevice, 4)
      syncDeck()
    check menus() == ("root", "x")
    check status()["historyDepth"].getInt() == 1
    press(DeckDevice, 4)
    syncDeck()
    check menus() == ("root", "y")
    check status()["historyDepth"].getInt() == 2
    press(DeckDevice, 1)
    check menus() == ("root", "x")
    syncDeck()
    press(DeckDevice, 1)
    check menus() == ("root", "root")
    check status()["historyDepth"].getInt() == 0
    press(MixerDevice, 2)
    syncDeck()
    for _ in 1..101:
      press(MixerDevice, 2)
      syncDeck()
    check menus() == ("y", "y")
    check status()["historyDepth"].getInt() == 2
    press(DeckDevice, 1)
    check menus() == ("x", "x")
    syncDeck()
    press(MixerDevice, 1)
    check menus() == ("root", "root")
    check status()["historyDepth"].getInt() == 0
    check takeButtonActions().len == 0

  test "returns on other devices or after linked transitions are recorded, not undone":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(reciprocalConfig()))
    start(paths)
    defer: finish(paths)
    syncDeck()
    press(MixerDevice, 3)
    press(DeckDevice, 4)
    syncDeck()
    press(MixerDevice, 3)
    press(DeckDevice, 4)
    syncDeck()
    check menus() == ("y", "y")
    check status()["historyDepth"].getInt() == 4
    press(MixerDevice, 3)
    check menus() == ("x", "y")
    check status()["historyDepth"].getInt() == 5
    press(DeckDevice, 1)
    check menus() == ("x", "x")
    check status()["historyDepth"].getInt() == 4
    syncDeck()
    press(MixerDevice, 6)
    press(MixerDevice, 2)
    syncDeck()
    press(MixerDevice, 2)
    syncDeck()
    check menus() == ("y", "y")
    press(MixerDevice, 3)
    check menus() == ("x", "y")
    check status()["historyDepth"].getInt() == 3
    press(MixerDevice, 1)
    check menus() == ("y", "y")
    press(MixerDevice, 1)
    check menus() == ("x", "x")
    syncDeck()
    press(DeckDevice, 1)
    check menus() == ("root", "root")
    check status()["historyDepth"].getInt() == 0

  test "Deck input waits for the current page and stale readiness is ignored":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    let page = readDeckPage(0)
    check page["menu"].getStr() == RootMenuId
    check page["keys"]["5"]["pressed"].getStr() == "/prepared/root-5-pressed.jpg"
    check readDeckPage(page["generation"].getBiggestInt()).isNil
    press(DeckDevice, 7)
    check takeButtonActions().len == 0
    deckPageReady()
    press(MixerDevice, 2)
    deckPageReady()
    check not status()["deckReady"].getBool()
    press(DeckDevice, 3)
    check menus() == ("a", "a")
    let next = readDeckPage(page["generation"].getBiggestInt())
    check next["menu"].getStr() == "a"
    deckPageReady()
    press(DeckDevice, 3)
    check menus() == ("a", "b")

  test "held keys are quarantined across apply while earlier captures keep their command":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    let oldRevision = revision()
    routeMixerButton(5, true)
    var changed = navConfig()
    changed["menus"][0]["mixer"][2]["action"]["command"] = %"echo changed"
    check awaitOperation(apply(changed))["status"].getStr() == "succeeded"
    routeMixerButton(5, true)
    routeMixerButton(5, false)
    routeMixerButton(5, true)
    let actions = takeButtonActions()
    check actions.len == 2
    check actions[0]["action"]["command"].getStr() == "echo root"
    check actions[0]["revision"].getStr() == oldRevision
    check actions[1]["action"]["command"].getStr() == "echo changed"
    check actions[1]["revision"].getStr() == revision()
    resetMixerInput()
    routeMixerButton(5, true)
    check takeButtonActions().len == 1

  test "navigation bypasses a full action queue":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    for _ in 1..MaxButtonActions:
      press(MixerDevice, 12)
    expect IOError:
      routeMixerButton(12, true)
    routeMixerButton(12, false)
    press(MixerDevice, 2)
    check menus() == ("a", "a")
    check status()["pendingActions"].getInt() == MaxButtonActions
    check takeButtonActions().len == MaxButtonActions

  test "successful apply persists both records, publishes a manifest, and resets navigation":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    syncDeck()
    press(MixerDevice, 2)
    let generation = status()["deckGeneration"].getBiggestInt()
    var changed = navConfig()
    changed["menus"][1]["title"] = %"Ä Menu"
    let record = awaitOperation(apply(changed))
    check record["status"].getStr() == "succeeded"
    check record["kind"].getStr() == "apply"
    check record["revision"].getStr() == configRevision(changed)
    check revision() == configRevision(changed)
    check menus() == ("root", "root")
    check status()["historyDepth"].getInt() == 0
    check status()["deckGeneration"].getBiggestInt() > generation
    check parseJson(readFile(paths.configPath())) == canonicalButtonConfig(changed)
    check decodeLastApplied(readFile(paths.lastAppliedPath())) == canonicalButtonConfig(changed)
    check status()["manifestPath"].getStr() == record["manifestPath"].getStr()
    check parseJson(readFile(record["manifestPath"].getStr()))["menus"].hasKey("a")
    let exported = request("config.get")
    check exported["envelope"] == configEnvelope(changed)
    check status()["recent"][0]["id"] == record["id"]

  test "stale and busy requests are rejected immediately without queueing":
    let paths = newPaths()
    start(paths)
    defer: finish(paths)
    let stale = apply(navConfig(), "0000")
    check not stale["ok"].getBool()
    check stale["code"].getStr() == "stale"
    check stale["revision"].getStr() == revision()
    check status()["lastOperationSequence"].getInt() == 0
    gateOpen.store(false)
    var blocked = navConfig()
    blocked["menus"][2]["title"] = %BlockTitle
    let accepted = apply(blocked)
    check accepted["ok"].getBool()
    check status()["busy"].getBool()
    let busy = request("config.preview", %*{"config": navConfig()})
    check busy["code"].getStr() == "busy"
    check apply(navConfig())["code"].getStr() == "busy"
    gateOpen.store(true)
    check awaitOperation(accepted)["status"].getStr() == "succeeded"
    check not status()["busy"].getBool()
    let late = apply(navConfig(), configRevision(defaultButtonConfig()))
    check late["code"].getStr() == "stale"

  test "prepare failure keeps the active configuration and writes nothing":
    let paths = newPaths()
    start(paths)
    defer: finish(paths)
    let before = revision()
    var failing = navConfig()
    failing["menus"][1]["title"] = %FailTitle
    let record = awaitOperation(apply(failing))
    check record["status"].getStr() == "failed"
    check record["code"].getStr() == "prepare"
    check "ffmpeg exploded" in record["error"].getStr()
    check revision() == before
    check not fileExists(paths.configPath())
    check not fileExists(paths.lastAppliedPath())
    check status()["operation"]["id"] == record["id"]

  test "maintenance failures preserve successful applies and failed prepares skip cleanup":
    let paths = newPaths()
    var services = fakeServices()
    services.maintain = failingMaintenance
    maintenanceCalls.store(0)
    start(paths, services)
    defer: finish(paths)
    let config = navConfig()
    check awaitOperation(apply(config))["status"].getStr() == "succeeded"
    check revision() == configRevision(config)
    check decodeLastApplied(readFile(paths.lastAppliedPath())) == canonicalButtonConfig(config)
    check maintenanceCalls.load() == 1
    var broken = navConfig()
    broken["menus"][0]["title"] = %FailTitle
    check awaitOperation(apply(broken))["status"].getStr() == "failed"
    check maintenanceCalls.load() == 1

  test "canonical write failure keeps the active configuration":
    let paths = newPaths()
    start(paths)
    defer: finish(paths)
    let before = revision()
    setFilePermissions(paths.configDir, {fpUserRead, fpUserExec})
    let record = awaitOperation(apply(navConfig()))
    check record["status"].getStr() == "failed"
    check record["code"].getStr() == "persist"
    check revision() == before
    check not fileExists(paths.configPath())
    check not fileExists(paths.lastAppliedPath())

  test "last-applied write failure restores the previous buttons.json":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    let
      before = revision()
      original = readFile(paths.configPath())
    check decodeLastApplied(readFile(paths.lastAppliedPath())) == canonicalButtonConfig(navConfig())
    setFilePermissions(paths.stateDir, {fpUserRead, fpUserExec})
    var changed = navConfig()
    changed["menus"][1]["title"] = %"Changed"
    let record = awaitOperation(apply(changed))
    check record["status"].getStr() == "failed"
    check record["code"].getStr() == "persist"
    check "last-applied" in record["error"].getStr()
    check revision() == before
    check readFile(paths.configPath()) == original

  test "external edits to buttons.json are reported instead of overwritten":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    let external = encodeConfigFile(defaultButtonConfig())
    writeFile(paths.configPath(), external)
    let record = awaitOperation(apply(navConfig()))
    check record["status"].getStr() == "failed"
    check record["code"].getStr() == "diskChanged"
    check readFile(paths.configPath()) == external
    check revision() == configRevision(navConfig())

  test "a file created externally after a defaults start is not overwritten":
    let paths = newPaths()
    start(paths)
    defer: finish(paths)
    writeFile(paths.configPath(), "{}")
    let record = awaitOperation(apply(navConfig()))
    check record["code"].getStr() == "diskChanged"
    check readFile(paths.configPath()) == "{}"

  test "startup falls back to last-applied and backs up the broken file on the next apply":
    let paths = newPaths()
    writeFileAtomic(paths.lastAppliedPath(), encodeLastApplied(navConfig()))
    writeFile(paths.configPath(), "{ broken")
    start(paths)
    defer: finish(paths)
    check status()["source"].getStr() == "lastApplied"
    check "buttons.json" in status()["startupError"].getStr()
    check revision() == configRevision(navConfig())
    check awaitOperation(apply(defaultButtonConfig()))["status"].getStr() == "succeeded"
    check readFile(paths.invalidBackupPath()) == "{ broken"
    check parseJson(readFile(paths.configPath())) == defaultButtonConfig()
    check status()["startupError"].getStr() == ""

  test "startup falls back when the canonical configuration cannot be prepared":
    let paths = newPaths()
    var failing = navConfig()
    failing["menus"][1]["title"] = %FailTitle
    writeFileAtomic(paths.configPath(), encodeConfigFile(failing))
    writeFileAtomic(paths.lastAppliedPath(), encodeLastApplied(navConfig()))
    start(paths)
    defer: finish(paths)
    check status()["source"].getStr() == "lastApplied"
    check "ffmpeg exploded" in status()["startupError"].getStr()
    check revision() == configRevision(navConfig())
    check decodeLastApplied(readFile(paths.lastAppliedPath())) == canonicalButtonConfig(navConfig())

  test "startup uses defaults when every recorded configuration is unusable":
    let paths = newPaths()
    var invalid = navConfig()
    invalid["menus"][1]["mixer"][0]["key"] = %99
    writeFile(paths.configPath(), $invalid)
    writeFile(paths.lastAppliedPath(), "not json")
    start(paths)
    defer: finish(paths)
    let error = status()["startupError"].getStr()
    check status()["source"].getStr() == "defaults"
    check "menus[1].mixer[0].key" in error
    check "last-applied.json" in error
    check revision() == configRevision(defaultButtonConfig())

  test "a missing buttons.json recovers the last applied configuration":
    let paths = newPaths()
    writeFileAtomic(paths.lastAppliedPath(), encodeLastApplied(navConfig()))
    start(paths)
    defer: finish(paths)
    check status()["source"].getStr() == "lastApplied"
    check "missing" in status()["startupError"].getStr()

  test "preview prepares a manifest without changing the active page":
    let paths = newPaths()
    start(paths)
    defer: finish(paths)
    let before = revision()
    let record = awaitOperation(request("config.preview", %*{"config": navConfig()}))
    check record["status"].getStr() == "succeeded"
    check record["revision"].getStr() == configRevision(navConfig())
    let manifest = parseJson(readFile(record["manifestPath"].getStr()))
    check manifest["menus"]["b"]["1"]["normal"][0]["path"].getStr() == "/prepared/b-1.jpg"
    check revision() == before
    check not fileExists(paths.configPath())
    check fileExists(status()["manifestPath"].getStr())

  test "asset import runs as an operation with managed paths only":
    let paths = newPaths()
    start(paths)
    defer: finish(paths)
    let imported = awaitOperation(request("config.importAsset", %*{"source": "/home/me/cat.png"}))
    check imported["status"].getStr() == "succeeded"
    check isManagedAssetPath(imported["path"].getStr())
    let broken = awaitOperation(request("config.importAsset", %*{"source": "/tmp/broken.gif"}))
    check broken["code"].getStr() == "import"
    check "ffprobe" in broken["error"].getStr()
    let escaped = awaitOperation(request("config.importAsset", %*{"source": "/tmp/escape.png"}))
    check escaped["code"].getStr() == "import"
    let relative = request("config.importAsset", %*{"source": "cat.png"})
    check relative["code"].getStr() == "invalid"
    check relative["field"].getStr() == "source"

  test "operation results are bounded and newest first":
    let paths = newPaths()
    start(paths)
    defer: finish(paths)
    var ids: seq[string]
    for _ in 1..MaxRecentOperations + 2:
      let reply = request("config.preview", %*{"config": navConfig()})
      ids.add(reply["operationId"].getStr())
      discard awaitOperation(reply)
    let recent = status()["recent"]
    check recent.len == MaxRecentOperations
    check recent[0]["id"].getStr() == ids[^1]
    check recent[^1]["id"].getStr() == ids[2]
    check buttonOperation(ids[0]).isNil
    check status()["lastOperationSequence"].getInt() == ids.len
    var manifests = 0
    for _ in walkFiles(paths.manifestDirectory() / "*.json"): inc manifests
    check manifests <= MaxRetainedManifests + 1

  test "requests validate versions, types, envelopes, and worker availability":
    let paths = newPaths()
    start(paths)
    defer: finish(paths)
    check processConfigRequest(%*{"version": 999, "type": "config.get"})["code"].getStr() == "version"
    check request("config.reboot")["code"].getStr() == "unsupported"
    var invalid = navConfig()
    invalid["menus"][1]["deck"].add(%*{"key": 1, "action": {"kind": "grok"}})
    let rejected = request("config.validate", %*{"config": invalid})
    check rejected["code"].getStr() == "invalid"
    check rejected["field"].getStr() == "menus[1].deck[1].action"
    let valid = request("config.validate", %*{"config": parseJson(pretty(navConfig()))})
    check valid["revision"].getStr() == configRevision(navConfig())
    check valid["config"] == canonicalButtonConfig(navConfig())
    check request("config.apply", %*{"envelope": {"config": navConfig()}})["field"].getStr() == "baseRevision"
    check request("config.preview")["field"].getStr() == "config"
    let invalidApply = apply(invalid)
    check invalidApply["field"].getStr() == "menus[1].deck[1].action"
    check status()["lastOperationSequence"].getInt() == 0
    stopButtonWorker()
    check apply(navConfig())["code"].getStr() == "unavailable"
    startButtonWorker()

  test "the active mixer catalog keeps twelve slots and describes navigation":
    let paths = newPaths()
    writeFileAtomic(paths.configPath(), encodeConfigFile(navConfig()))
    start(paths)
    defer: finish(paths)
    press(MixerDevice, 2)
    let catalog = activeMixerCatalog()
    check catalog["buttons"].len == MixerKeyCount
    check catalog["faders"] == bindingCatalog()["faders"]
    check catalog["buttons"][0] == %*{"note": 1, "label": "Back",
      "description": "Return to the previous menu."}
    check catalog["buttons"][1]["description"].getStr() == "Open B on both devices."
    check catalog["buttons"][11]["label"].getStr() == "Unassigned"

  test "default services prepare built-in pages and refuse real media":
    let paths = newPaths()
    start(paths, defaultButtonServices())
    defer: finish(paths)
    check status()["startupError"].getStr() == ""
    check readDeckPage(0)["keys"]["4"] == %*{"builtinNumber": 4}
    var imaged = defaultButtonConfig()
    imaged["menus"][0]["deck"][3]["visual"] = %*{"image": "assets/cat.png"}
    let record = awaitOperation(apply(imaged))
    check record["code"].getStr() == "prepare"
    check "Media preparation is unavailable" in record["error"].getStr()
    check awaitOperation(request("config.importAsset", %*{"source": "/tmp/cat.png"}))["code"].getStr() == "import"
    check revision() == configRevision(defaultButtonConfig())

  test "OBS presses are captured at press time with their operation and description":
    let paths = newPaths()
    var config = navConfig()
    config["menus"][0]["deck"].add(%*{"key": 9, "title": "OBS",
      "action": {"kind": "menu", "menu": "obs", "target": "deck"}})
    config["menus"][0]["mixer"].add(%*{"key": 7, "title": "Mic",
      "action": {"kind": "obs", "operation": "micToggle"}})
    config["menus"].add(%*{"id": "obs", "title": "OBS", "mixer": [
        {"key": 3, "title": "Mic", "action": {"kind": "obs", "operation": "micToggle"}}],
      "deck": [
        {"key": 2, "title": "Rec", "action": {"kind": "obs", "operation": "recordToggle"}},
        {"key": 5, "title": "Open", "action": {"kind": "obs", "operation": "open"}}]})
    writeFileAtomic(paths.configPath(), encodeConfigFile(config))
    start(paths)
    defer: finish(paths)
    check activeMixerCatalog()["buttons"][6]["description"].getStr() ==
      obsOperationDescription("micToggle")
    syncDeck()
    press(DeckDevice, 9)
    check menus() == ("root", "obs")
    check takeButtonActions().len == 0
    syncDeck()
    routeDeckButton(1, true)
    var changed = config
    changed["menus"][3]["deck"][0]["action"]["operation"] = %"pauseToggle"
    check awaitOperation(apply(changed))["status"].getStr() == "succeeded"
    routeDeckButton(1, false)
    syncDeck()
    press(DeckDevice, 9)
    syncDeck()
    press(DeckDevice, 2)
    press(DeckDevice, 5)
    let actions = takeButtonActions()
    check kinds(actions) == @["obs", "obs", "obs"]
    check actions[0]["action"] == %*{"kind": "obs", "operation": "recordToggle"}
    check actions[0]["menu"].getStr() == "obs"
    check actions[1]["action"]["operation"].getStr() == "pauseToggle"
    check actions[2]["action"]["operation"].getStr() == "open"
    check menus() == ("root", "obs")
    press(MixerDevice, 2)
    check menus() == ("a", "a")

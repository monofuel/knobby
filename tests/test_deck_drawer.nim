import
  std/[json, os, sequtils, strutils, unittest],
  knobby/[button_config, button_runtime, ipc]

const
  NavigationId = "deck-navigation"
  WaitLimitMs = 10000

var
  deckSeen: int64
  directoryCounter: int

proc fakePrepare(config: JsonNode): JsonNode {.gcsafe.} =
  ## Return a fake manifest whose paths name each menu and key.
  result = %*{"version": 1, "menus": {}}
  for menu in config["menus"]:
    var keys = newJObject()
    for key in 1..DeckKeyCount:
      let path = "/prepared/" & menu["id"].getStr() & "-" & $key
      keys[$key] = %*{"normal": [{"path": path & ".jpg", "durationMs": 100}],
        "pressed": path & "-pressed.jpg"}
    result["menus"][menu["id"].getStr()] = keys

proc fakeImport(source: string): string {.gcsafe.} =
  ## Refuse imports, which these tests never request.
  raise newException(IOError, "Imports are not used here.")

proc deckLink(key: int, menu: string): JsonNode =
  ## Build a Deck-only menu link.
  %*{"key": key, "title": menu, "action": {"kind": "menu", "menu": menu, "target": "deck"}}

proc command(key: int, title: string): JsonNode =
  ## Build a command key whose capture proves an underlying action ran.
  %*{"key": key, "title": title, "action": {"kind": "command", "command": "echo " & title}}

proc drawerKey(): JsonNode =
  ## Build the shared Menu key that opens the navigation drawer.
  %*{"key": 1, "title": "Menu", "action": {"kind": "deckMenu", "menu": NavigationId}}

proc drawerConfig(): JsonNode =
  ## Describe Home, OBS, Discord, and Softmax pages sharing a Menu key, with commands on every
  ## top-row key so a press reaching an obscured action would be captured.
  result = %*{"version": 1, "root": "root", "menus": [
    {"id": NavigationId, "title": "Menu", "mixer": [], "deck": [drawerKey(),
      deckLink(2, "root"), deckLink(3, "obs"), deckLink(4, "discord"), deckLink(5, "work")]}]}
  for id in ["root", "obs", "discord", "work"]:
    var deck = %*[drawerKey()]
    for key in 2..5:
      deck.add(command(key, id & "-top-" & $key))
    deck.add(command(7, id & "-low-7"))
    deck.add(deckLink(9, "discord"))
    result["menus"].add(%*{"id": id, "title": id, "deck": deck,
      "mixer": [{"key": 2, "title": "Both obs", "action": {"kind": "menu", "menu": "obs", "target": "both"}},
        {"key": 3, "title": "Mixer obs", "action": {"kind": "menu", "menu": "obs", "target": "mixer"}}]})

proc legacyConfig(): JsonNode =
  ## Describe the earlier shared prefix whose key 1 is a Deck-only Home link.
  %*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Main", "deck": [deckLink(1, "root"), deckLink(2, "obs")]},
    {"id": "obs", "title": "OBS", "deck": [deckLink(1, "root"), deckLink(2, "obs"), command(3, "rec")]}]}

proc newPaths(): ButtonPaths =
  ## Create empty private config and state directories for one test.
  inc directoryCounter
  let root = getTempDir() / ("knobby-drawer-" & $getCurrentProcessId() & "-" & $directoryCounter)
  removeDir(root)
  result = newButtonPaths(root / "config", root / "state")
  createDir(result.configDir)
  createDir(result.stateDir)

proc start(config: JsonNode): ButtonPaths =
  ## Initialize the runtime with a configuration, start its worker, and upload the first page.
  result = newPaths()
  writeFileAtomic(result.configPath(), encodeConfigFile(config))
  deckSeen = 0
  initializeButtons(result, ButtonServices(prepare: fakePrepare, importAsset: fakeImport))
  startButtonWorker()

proc finish(paths: ButtonPaths) =
  ## Stop the worker and delete the private directories.
  stopButtonWorker()
  removeDir(paths.configDir.parentDir())

proc status(): JsonNode =
  ## Read the runtime status.
  buttonRuntimeStatus()

proc syncDeck(): JsonNode =
  ## Act as the Deck player: read any new page and report it uploaded.
  result = readDeckPage(deckSeen)
  if not result.isNil:
    deckSeen = result["generation"].getBiggestInt()
  deckPageReady()

proc down(key: int) =
  ## Report a Deck key pressed.
  routeDeckButton(key - 1, true)

proc up(key: int) =
  ## Report a Deck key released.
  routeDeckButton(key - 1, false)

proc press(key: int) =
  ## Press and release one Deck key on an uploaded page.
  down(key)
  up(key)
  discard syncDeck()

proc titles(): seq[string] =
  ## Drain captured actions and return their titles.
  for action in takeButtonActions():
    result.add(action["title"].getStr())

proc navigate(operation: string, key = 0): JsonNode =
  ## Send a versioned Deck navigation request to the runtime.
  var message = %*{"version": ProtocolVersion, "type": DeckNavigationRequest, "operation": operation}
  if key != 0: message["key"] = %key
  processDeckNavigationRequest(message)

proc keyPath(page: JsonNode, key: int): string =
  ## Return a page key's first frame path.
  page["keys"][$key]["normal"][0]["path"].getStr()

proc expectInvalid(config: JsonNode, fragment: string) =
  ## Require validation to fail with a message containing fragment.
  try:
    validateButtonConfig(config)
    checkpoint("accepted an invalid configuration")
    fail()
  except ButtonConfigError as error:
    checkpoint(error.msg)
    check fragment in error.msg

suite "Deck menu drawer schema":
  test "deckMenu is canonical and stays on Deck key 1 of any page":
    let canonical = canonicalButtonConfig(drawerConfig())
    var found = false
    for menu in canonical["menus"]:
      if menu["id"].getStr() == "obs":
        check menu["deck"][0]["action"] == %*{"kind": "deckMenu", "menu": NavigationId}
        found = true
    check found
    let parsed = parseButtonSet(drawerConfig())
    check parsed.menus[1].deck[0].action.kind == DeckMenuAction
    check parsed.menus[1].deck[0].action.menu == NavigationId

  test "invalid drawer placements and destinations are rejected":
    var config = drawerConfig()
    config["menus"][1]["deck"][0]["action"]["menu"] = %"missing"
    expectInvalid(config, "Unknown menu: missing")
    config = drawerConfig()
    config["menus"][1]["deck"][0]["action"]["target"] = %"deck"
    expectInvalid(config, "Field is not used")
    config = drawerConfig()
    config["menus"][1]["deck"].add(%*{"key": 6, "title": "Menu",
      "action": {"kind": "deckMenu", "menu": NavigationId}})
    expectInvalid(config, "Only Stream Deck key 1")
    config = drawerConfig()
    config["menus"][1]["mixer"].add(%*{"key": 4, "title": "Menu",
      "action": {"kind": "deckMenu", "menu": NavigationId}})
    expectInvalid(config, "Only Stream Deck key 1")
    config = drawerConfig()
    config["menus"][0]["deck"].elems[2] = command(3, "rec")
    expectInvalid(config, "must be unassigned or a Deck-only menu link")
    config = drawerConfig()
    config["menus"][0]["deck"][3]["action"]["target"] = %"both"
    expectInvalid(config, "must be unassigned or a Deck-only menu link")
    config = drawerConfig()
    config["menus"][0]["deck"].elems[0] = deckLink(1, "root")
    expectInvalid(config, "must open drawer " & NavigationId)

  test "drawer keys may be unassigned and lower drawer keys are not constrained":
    var config = drawerConfig()
    config["menus"][0]["deck"].elems.delete(4)
    config["menus"][0]["deck"].add(command(8, "ignored"))
    validateButtonConfig(config)

suite "Deck menu drawer runtime":
  test "Menu opens a top-row drawer and cancel restores the exact underlying page":
    let paths = start(drawerConfig())
    defer: finish(paths)
    let base = syncDeck()
    check base["menu"].getStr() == "root"
    check status()["deckDrawerMenu"].getStr() == NavigationId
    down(9)
    up(9)
    let underlying = syncDeck()
    check underlying["menu"].getStr() == "discord"
    let depth = status()["historyDepth"].getInt()
    down(1)
    up(1)
    let opened = status()
    check opened["deckDrawer"].getStr() == NavigationId
    check opened["deckMenu"].getStr() == "discord"
    check opened["historyDepth"].getInt() == depth
    let drawer = syncDeck()
    check drawer["drawer"].getStr() == NavigationId
    check drawer["menu"].getStr() == "discord"
    for key in 1..DrawerKeyCount:
      check drawer.keyPath(key) == "/prepared/" & NavigationId & "-" & $key & ".jpg"
    for key in DrawerKeyCount + 1..DeckKeyCount:
      check drawer["keys"][$key] == underlying["keys"][$key]
    var menus: seq[string]
    for menu in opened["deckKeyMenus"]: menus.add(menu.getStr())
    check menus[0..4] == @[NavigationId, NavigationId, NavigationId, NavigationId, NavigationId]
    check menus[5..14].allIt(it == "discord")
    down(1)
    up(1)
    check status()["deckDrawer"].getStr() == ""
    check status()["deckMenu"].getStr() == "discord"
    check status()["historyDepth"].getInt() == depth
    let restored = syncDeck()
    check restored["keys"] == underlying["keys"]
    check restored["drawer"].getStr() == ""
    check titles().len == 0

  test "destinations navigate from several pages and Home clears only Deck history":
    let paths = start(drawerConfig())
    defer: finish(paths)
    discard syncDeck()
    routeMixerButton(3, true)
    routeMixerButton(3, false)
    check status()["mixerMenu"].getStr() == "obs"
    for (key, expected) in [(3, "obs"), (5, "work"), (4, "discord"), (3, "obs")]:
      press(1)
      press(key)
      check status()["deckMenu"].getStr() == expected
      check status()["deckDrawer"].getStr() == ""
    check status()["historyDepth"].getInt() > 1
    press(1)
    press(3)
    check status()["deckMenu"].getStr() == "obs"
    check status()["deckDrawer"].getStr() == ""
    press(1)
    press(2)
    check status()["deckMenu"].getStr() == "root"
    check status()["mixerMenu"].getStr() == "obs"
    check status()["historyDepth"].getInt() == 1
    check titles().len == 0

  test "covered top actions never fire, lower controls keep working, and Menu queues nothing":
    var config = drawerConfig()
    config["menus"][0]["deck"].elems.delete(4)
    let paths = start(config)
    defer: finish(paths)
    discard syncDeck()
    press(1)
    press(5)
    check status()["deckDrawer"].getStr() == NavigationId
    check status()["deckMenu"].getStr() == "root"
    press(7)
    check titles() == @["root-low-7"]
    check status()["deckDrawer"].getStr() == NavigationId
    press(9)
    check status()["deckMenu"].getStr() == "discord"
    check status()["deckDrawer"].getStr() == NavigationId
    press(1)
    check status()["deckDrawer"].getStr() == ""
    press(5)
    check titles() == @["discord-top-5"]

  test "lower keys stay live during a drawer-only upload while top keys wait":
    let paths = start(drawerConfig())
    defer: finish(paths)
    discard syncDeck()
    down(1)
    up(1)
    check not status()["deckReady"].getBool()
    down(7)
    up(7)
    check titles() == @["root-low-7"]
    down(3)
    up(3)
    check status()["deckMenu"].getStr() == "root"
    check status()["deckDrawer"].getStr() == NavigationId
    check titles().len == 0
    discard syncDeck()
    press(3)
    check status()["deckMenu"].getStr() == "obs"
    down(1)
    up(1)
    down(9)
    up(9)
    check status()["deckMenu"].getStr() == "discord"
    check status()["deckDrawer"].getStr() == NavigationId
    down(7)
    up(7)
    check titles().len == 0
    discard syncDeck()
    press(7)
    check titles() == @["discord-low-7"]

  test "held keys and repeated reports act once across drawer transitions":
    let paths = start(drawerConfig())
    defer: finish(paths)
    discard syncDeck()
    down(3)
    check titles() == @["root-top-3"]
    down(1)
    discard syncDeck()
    check status()["deckDrawer"].getStr() == NavigationId
    down(1)
    down(3)
    discard syncDeck()
    check status()["deckDrawer"].getStr() == NavigationId
    check status()["deckMenu"].getStr() == "root"
    up(3)
    up(1)
    down(4)
    check status()["deckMenu"].getStr() == "discord"
    discard syncDeck()
    down(4)
    up(4)
    discard syncDeck()
    check status()["deckMenu"].getStr() == "discord"
    check titles().len == 0
    press(4)
    check titles() == @["discord-top-4"]

  test "each drawer change publishes a generation that needs a real upload acknowledgement":
    let paths = start(drawerConfig())
    defer: finish(paths)
    discard syncDeck()
    let before = status()["deckGeneration"].getBiggestInt()
    down(1)
    up(1)
    let opened = status()
    check opened["deckGeneration"].getBiggestInt() == before + 1
    check not opened["deckReady"].getBool()
    deckPageReady()
    check not status()["deckReady"].getBool()
    discard buttonRuntimeStatus()
    let page = readDeckPage(deckSeen)
    check page["generation"].getBiggestInt() == before + 1
    deckSeen = page["generation"].getBiggestInt()
    check status()["deckReadGeneration"].getBiggestInt() == before + 1
    check not status()["deckReady"].getBool()
    deckPageReady()
    check status()["deckReady"].getBool()
    check readDeckPage(deckSeen).isNil

  test "replug and config swaps close the drawer onto a deterministic base":
    let paths = start(drawerConfig())
    defer: finish(paths)
    discard syncDeck()
    press(9)
    press(1)
    check status()["deckDrawer"].getStr() == NavigationId
    resetDeckInput()
    check status()["deckDrawer"].getStr() == ""
    check status()["deckMenu"].getStr() == "discord"
    deckSeen = 0
    discard syncDeck()
    press(1)
    discard readDeckPage(0)
    check status()["deckDrawer"].getStr() == ""
    deckSeen = 0
    discard syncDeck()
    press(1)
    var changed = drawerConfig()
    changed["menus"][1]["title"] = %"Main"
    let reply = processConfigRequest(%*{"version": ProtocolVersion, "type": "config.apply",
      "envelope": {"baseRevision": status()["revision"].getStr(), "config": changed}})
    check reply["ok"].getBool()
    var record: JsonNode
    for _ in 0..<WaitLimitMs div 5:
      record = buttonOperation(reply["operationId"].getStr())
      if not record.isNil and record["status"].getStr() in ["succeeded", "failed"]: break
      sleep(5)
    check record["status"].getStr() == "succeeded"
    check status()["deckDrawer"].getStr() == ""
    check status()["deckMenu"].getStr() == "root"
    discard syncDeck()
    press(1)
    check status()["deckDrawer"].getStr() == NavigationId

  test "legacy pages without a Menu key keep their Home behavior":
    let paths = start(legacyConfig())
    defer: finish(paths)
    discard syncDeck()
    check status()["deckDrawerMenu"].getStr() == ""
    press(2)
    check status()["deckMenu"].getStr() == "obs"
    press(1)
    check status()["deckMenu"].getStr() == "root"
    check status()["historyDepth"].getInt() == 0
    check status()["deckDrawer"].getStr() == ""
    let reply = navigate("toggle")
    check not reply["ok"].getBool()
    check reply["code"].getStr() == "refused"

suite "Deck navigation requests":
  test "toggle, select, and cancel reuse the physical drawer without app actions":
    let paths = start(drawerConfig())
    defer: finish(paths)
    discard syncDeck()
    var reply = navigate("toggle")
    check reply["ok"].getBool()
    check reply["changed"].getBool()
    check reply["deckDrawer"].getStr() == NavigationId
    check reply["deckGeneration"].getBiggestInt() == status()["deckGeneration"].getBiggestInt()
    reply = navigate("select", 3)
    check reply["ok"].getBool()
    check reply["deckMenu"].getStr() == "obs"
    check reply["deckDrawer"].getStr() == ""
    reply = navigate("toggle")
    check reply["deckDrawer"].getStr() == NavigationId
    reply = navigate("cancel")
    check reply["changed"].getBool()
    check reply["deckDrawer"].getStr() == ""
    check reply["deckMenu"].getStr() == "obs"
    reply = navigate("cancel")
    check reply["ok"].getBool()
    check not reply["changed"].getBool()
    discard navigate("toggle")
    reply = navigate("select", 2)
    check reply["deckMenu"].getStr() == "root"
    check status()["historyDepth"].getInt() == 0
    check takeButtonActions().len == 0

  test "refused requests change nothing":
    let paths = start(drawerConfig())
    defer: finish(paths)
    discard syncDeck()
    let generation = status()["deckGeneration"].getBiggestInt()
    for (operation, key, code) in [("select", 3, "refused"), ("select", 6, "invalid"),
        ("select", 1, "invalid"), ("select", 0, "invalid"), ("press", 0, "invalid"),
        ("toggle", 3, "invalid")]:
      let reply = navigate(operation, key)
      checkpoint(operation & " " & $key)
      check not reply["ok"].getBool()
      check reply["code"].getStr() == code
    check not processDeckNavigationRequest(%*{"version": ProtocolVersion - 1,
      "type": DeckNavigationRequest, "operation": "toggle"})["ok"].getBool()
    discard navigate("toggle")
    let open = status()["deckGeneration"].getBiggestInt()
    check open == generation + 1
    discard navigate("cancel")
    check status()["deckGeneration"].getBiggestInt() == generation + 2
    check status()["deckMenu"].getStr() == "root"
    check takeButtonActions().len == 0

  test "an unassigned drawer key is refused without closing the drawer":
    var config = drawerConfig()
    config["menus"][0]["deck"].elems.delete(4)
    let paths = start(config)
    defer: finish(paths)
    discard syncDeck()
    discard navigate("toggle")
    let generation = status()["deckGeneration"].getBiggestInt()
    let reply = navigate("select", 5)
    check not reply["ok"].getBool()
    check reply["code"].getStr() == "refused"
    check status()["deckDrawer"].getStr() == NavigationId
    check status()["deckGeneration"].getBiggestInt() == generation
    check takeButtonActions().len == 0

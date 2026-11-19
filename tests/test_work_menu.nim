import
  std/[json, os, sets, strutils, tables, tempfiles, unittest],
  knobby/[button_config, button_runtime, discord_menu, work_menu]

const
  TargetsFile = currentSourcePath().parentDir().parentDir() / "docs/work-menu-targets.json"
  AssetsDirectory = currentSourcePath().parentDir().parentDir() / "assets"
  WowDirectory = "/home/monofuel/src/wow-coworld/wow-shadow-army"
  StagingUrl = "https://fast-xp-k8s-staging.tail0f4a29.ts.net/"

proc targets(): JsonNode =
  ## Load the checked-in Work targets used by the setup tool.
  parseFile(TargetsFile)

proc artwork(): Table[string, string] =
  ## Use harmless managed paths without importing artwork or contacting the daemon.
  for name in workArtworkNames(targets()): result[name] = "assets/" & name.extractFilename() & ".png"

proc liveLikeConfig(): JsonNode =
  ## Build a root with OBS on Deck key 2, Discord on Deck key 3, and the default mixer bindings.
  var discordArt = initTable[string, string]()
  for name in DiscordArtworkNames: discordArt[name] = "assets/" & name & ".png"
  result = installDiscordMenu(defaultButtonConfig(), discordArt)
  result["menus"].add(%*{"id": "obs", "title": "OBS", "mixer": [], "deck": [
    {"key": 2, "title": "Record", "action": {"kind": "obs", "operation": "recordToggle"}}]})
  for button in result["menus"][0]["deck"]:
    if button["key"].getInt() == 2:
      button["title"] = %"OBS"
      button["action"] = %*{"kind": "menu", "menu": "obs", "target": "deck"}

proc command(config: JsonNode, key: int): string =
  ## Return the shell command bound to a Work key.
  buttonAt(config, WorkMenuId, "deck", key)["action"]["command"].getStr()

proc prepareFixture(config: JsonNode): JsonNode {.gcsafe.} =
  ## Prepare fake pages so navigation tests never invoke media tools or hardware.
  result = %*{"version": 1, "menus": {}}
  for menu in config["menus"]:
    var keys = newJObject()
    for key in 1..DeckKeyCount:
      keys[$key] = %*{"normal": [{"path": "/fixture.jpg", "durationMs": 100}],
        "pressed": "/fixture-pressed.jpg"}
    result["menus"][menu["id"].getStr()] = keys

proc unusedImport(source: string): string {.gcsafe.} =
  ## Reject unexpected imports instead of touching user assets.
  raise newException(ValueError, "Navigation fixture does not import media: " & source)

suite "Work submenu installation":
  test "adds a Deck-only Work menu at root key 4 and preserves every other control":
    let
      source = liveLikeConfig()
      original = $source
      updated = installWorkMenu(source, targets(), artwork())
    validateButtonConfig(updated)
    check $source == original
    for id in ["obs", "discord"]:
      check menuAt(updated, id) == menuAt(source, id)
    check updated["menus"][0]["mixer"] == source["menus"][0]["mixer"]
    for key in 1..DeckKeyCount:
      if key != WorkRootKey:
        check buttonAt(updated, "root", "deck", key) == buttonAt(source, "root", "deck", key)
    let entry = buttonAt(updated, "root", "deck", WorkRootKey)
    check entry["action"] == %*{"kind": "menu", "menu": "work", "target": "deck"}
    check entry["visual"]["image"].getStr() == "assets/menu-work.png"
    let menu = menuAt(updated, WorkMenuId)
    check menu["mixer"].len == 0
    check menu["deck"].len == 11
    check menu["title"].getStr() == "Softmax"
    check entry["title"].getStr() == "Softmax"
    check buttonAt(updated, WorkMenuId, "deck", 1)["action"]["kind"].getStr() == "back"

  test "binds the launchers and private realm controls with distinct titles and artwork":
    let updated = installWorkMenu(liveLikeConfig(), targets(), artwork())
    var titles, images: HashSet[string]
    for key in [2, 3, 4, 5, 6, 7, 8, 9, 10, 12]:
      let button = buttonAt(updated, WorkMenuId, "deck", key)
      titles.incl(button["title"].getStr())
      images.incl(button["visual"]["image"].getStr())
      check button["visual"]["showTitle"].getBool() == false
    check titles.len == 10
    check images.len == 10
    check command(updated, 2) == "\"$HOME/.local/bin/knobby-obs\" prism"
    check command(updated, 3) == "make -C " & WowDirectory & " play-classic"
    check command(updated, 4) == "cd " & WowDirectory & " && nix develop --command make play"
    check buttonAt(updated, WorkMenuId, "deck", 5)["action"] == %*{"kind": "openDiscord"}
    check buttonAt(updated, WorkMenuId, "deck", 5)["visual"] ==
      %*{"image": "assets/discord.png", "showTitle": false}
    check buttonAt(updated, WorkMenuId, "deck", 3)["title"].getStr() == "WoW Vanilla"
    check buttonAt(updated, WorkMenuId, "deck", 4)["title"].getStr() == "WoW Nim"
    check command(updated, 6) == "slack -s"
    check command(updated, 7) == "xdg-open http://127.0.0.1:8103/"
    check command(updated, 8) == "xdg-open https://fast-xp-k8s-prod.tail0f4a29.ts.net/"
    check command(updated, 9) == "xdg-open " & StagingUrl
    check command(updated, 10) == "xdg-open " & StagingUrl & "next/"
    check "/next/play/" notin command(updated, 10)
    check command(updated, 12) == "xdg-open http://127.0.0.1:7777/"
    check command(updated, 12) != command(updated, 7)

  test "every referenced artwork file exists in the repository":
    check workArtworkNames(targets()).len == 12
    for name in workArtworkNames(targets()):
      check fileExists(AssetsDirectory / (name & ".png"))

  test "reinstalling is a no-op and conflicting installs are refused unchanged":
    let installed = installWorkMenu(liveLikeConfig(), targets(), artwork())
    check installWorkMenu(installed, targets(), artwork()) == installed
    var renamed = initTable[string, string]()
    for name, path in artwork(): renamed[name] = "assets/other-" & path.extractFilename()
    check installWorkMenu(installed, targets(), renamed) == installed
    let expanded = parseJson($installed)
    expanded["menus"][expanded["menus"].len - 1]["deck"].add(%*{
      "key": 13, "title": "Discord menu", "action": {"kind": "menu", "menu": "discord", "target": "deck"}})
    expanded["menus"][expanded["menus"].len - 1]["deck"].add(%*{
      "key": 11, "title": "Private realm", "action": {"kind": "command", "command": "echo private-status"}})
    validateButtonConfig(expanded)
    check installWorkMenu(expanded, targets(), renamed) == expanded
    let edited = parseJson($installed)
    for button in edited["menus"][edited["menus"].len - 1]["deck"]:
      if button["key"].getInt() == 6: button["action"]["command"] = %"my-slack"
    let editedText = $edited
    expect ValueError: discard installWorkMenu(edited, targets(), artwork())
    check $edited == editedText
    let occupied = liveLikeConfig()
    for button in occupied["menus"][0]["deck"]:
      if button["key"].getInt() == WorkRootKey: button["action"] = %*{"kind": "claude"}
    let occupiedText = $occupied
    expect ValueError: discard installWorkMenu(occupied, targets(), artwork())
    check $occupied == occupiedText
    let backTarget = targets()
    backTarget[0]["key"] = %1
    expect ValueError: discard installWorkMenu(liveLikeConfig(), backTarget, artwork())

  test "refreshing root art changes only the Softmax key image and refuses foreign bindings":
    let source = installWorkMenu(liveLikeConfig(), targets(), artwork())
    source["menus"][source["menus"].len - 1]["deck"].add(%*{"key": 11, "title": "Future",
      "action": {"kind": "command", "command": "true"}, "visual": {"image": "assets/future.png"}})
    let
      original = $source
      refreshed = refreshWorkMenuArtwork(source, "assets/graph.png")
    validateButtonConfig(refreshed)
    check $source == original
    let expected = parseJson(original)
    for button in expected["menus"][0]["deck"]:
      if button["key"].getInt() == WorkRootKey: button["visual"]["image"] = %"assets/graph.png"
    check refreshed == expected
    check buttonAt(refreshed, "root", "deck", WorkRootKey)["visual"]["showTitle"].getBool() == false
    let foreign = liveLikeConfig()
    for button in foreign["menus"][0]["deck"]:
      if button["key"].getInt() == WorkRootKey: button["action"] = %*{"kind": "claude"}
    let foreignText = $foreign
    expect ValueError: discard refreshWorkMenuArtwork(foreign, "assets/graph.png")
    check $foreign == foreignText
    expect ValueError: discard refreshWorkMenuArtwork(liveLikeConfig(), "assets/graph.png")

  test "refreshing launchers retitles WoW, gives Discord a static face, and keeps everything else":
    let earlier = targets()
    earlier[1]["title"] = %"WoW Classic"
    earlier[3]["art"] = %"discord/open-idle"
    earlier[3]["states"] = %*{"running": "discord/open-running", "ready": "discord/open-running",
      "unavailable": "discord/open-idle"}
    var earlierArt = artwork()
    for name in ["discord/open-idle", "discord/open-running"]:
      earlierArt[name] = "assets/" & name.extractFilename() & ".png"
    let source = installWorkMenu(liveLikeConfig(), earlier, earlierArt)
    source["menus"][source["menus"].len - 1]["deck"].add(%*{"key": 11, "title": "Start Server",
      "action": {"kind": "command", "command": "true"}, "visual": {"image": "assets/server.png"}})
    for button in source["menus"][0]["deck"]:
      if button["key"].getInt() == WorkRootKey: button["visual"]["image"] = %"assets/graph.png"
    let
      original = $source
      refreshed = refreshWorkLaunchers(source, targets(), artwork())
    validateButtonConfig(refreshed)
    check $source == original
    let expected = parseJson(original)
    for button in expected["menus"][expected["menus"].len - 1]["deck"]:
      case button["key"].getInt()
      of 3: button["title"] = %"WoW Vanilla"
      of 5:
        button["visual"]["image"] = %"assets/discord.png"
        button["visual"].delete("states")
      else: discard
    check refreshed == expected
    check refreshWorkLaunchers(refreshed, targets(), artwork()) == refreshed
    check workLauncherArtworkNames(targets()) == @["work/wow-classic", "work/wow-nim", "work/discord"]
    let foreign = parseJson(original)
    for button in foreign["menus"][foreign["menus"].len - 1]["deck"]:
      if button["key"].getInt() == 4: button["action"]["command"] = %"make play-other"
    let foreignText = $foreign
    expect ValueError: discard refreshWorkLaunchers(foreign, targets(), artwork())
    check $foreign == foreignText
    expect ValueError: discard refreshWorkLaunchers(liveLikeConfig(), targets(), artwork())

  test "actual runtime enters Work on the Deck only, queues a launcher, and returns Back":
    let
      directory = createTempDir("knobby-work-navigation-", "")
      paths = newButtonPaths(directory / "config", directory / "state")
      config = installWorkMenu(liveLikeConfig(), targets(), artwork())
    defer: removeDir(directory)
    createDir(paths.configDir)
    createDir(paths.stateDir)
    writeFile(paths.configPath(), encodeConfigFile(config))
    initializeButtons(paths, ButtonServices(prepare: prepareFixture, importAsset: unusedImport))
    check buttonRuntimeStatus()["startupError"].getStr() == ""
    discard readDeckPage(0)
    deckPageReady()
    routeDeckButton(WorkRootKey - 1, true)
    routeDeckButton(WorkRootKey - 1, false)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "work"
    check buttonRuntimeStatus()["mixerMenu"].getStr() == "root"
    discard readDeckPage(0)
    deckPageReady()
    routeDeckButton(9, true)
    routeDeckButton(9, false)
    let actions = takeButtonActions()
    check actions.len == 1
    check actions[0]["action"]["command"].getStr().endsWith("/next/")
    routeDeckButton(0, true)
    routeDeckButton(0, false)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "root"
    check buttonRuntimeStatus()["mixerMenu"].getStr() == "root"

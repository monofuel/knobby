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
    check menu["deck"].len == 10
    check buttonAt(updated, WorkMenuId, "deck", 1)["action"]["kind"].getStr() == "back"

  test "binds the nine verified launchers with distinct titles and artwork":
    let updated = installWorkMenu(liveLikeConfig(), targets(), artwork())
    var titles, images: HashSet[string]
    for key in 2..10:
      let button = buttonAt(updated, WorkMenuId, "deck", key)
      titles.incl(button["title"].getStr())
      images.incl(button["visual"]["image"].getStr())
      check button["visual"]["showTitle"].getBool() == false
    check titles.len == 9
    check images.len == 9
    check "--unit=knobby-prism.service" in command(updated, 2)
    check "--property=KillMode=process" in command(updated, 2)
    check command(updated, 2).endsWith("-- \"$HOME/bin/prism\"")
    check command(updated, 3) == "make -C " & WowDirectory & " play-classic"
    check command(updated, 4) == "make -C " & WowDirectory & " play"
    check buttonAt(updated, WorkMenuId, "deck", 5)["action"] == %*{"kind": "openDiscord"}
    check buttonAt(updated, WorkMenuId, "deck", 5)["visual"]["states"]["ready"].getStr() ==
      "assets/open-running.png"
    check command(updated, 6) == "slack -s"
    check command(updated, 7) == "firefox --new-window http://127.0.0.1:8103/"
    check command(updated, 8) == "firefox --new-window https://fast-xp-k8s-prod.tail0f4a29.ts.net/"
    check command(updated, 9) == "firefox --new-window " & StagingUrl
    check command(updated, 10) == "firefox --new-window " & StagingUrl & "next/"
    check "/next/play/" notin command(updated, 10)

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

import
  std/[algorithm, json, os, tables, tempfiles, unittest],
  knobby/[button_config, button_runtime, discord_menu, navigation_menu, task_menu_links, work_menu]

const
  TargetsFile = currentSourcePath().parentDir().parentDir() / "docs/work-menu-targets.json"
  AssetsDirectory = currentSourcePath().parentDir().parentDir() / "assets"
  StartCommand = "nix develop /home/monofuel/src/wow-coworld/wow-shadow-army --command " &
    "/home/monofuel/src/wow-coworld/tools/private_realm.sh start"
  KnownMenus = ["root", "obs", "discord", "work"]
  ObsTitles = ["Record", "Pause", "Commentary", "Open OBS", "Minecraft 1080p"]
  DiscordTitles = ["System Mic", "Discord Mic", "Deafen", "Open Discord", "Answer voice", "Answer video"]
  SoftmaxTitles = ["Prism", "WoW Vanilla", "WoW Nim", "Discord", "Slack", "Autoresearch",
    "Fast-XP Prod", "Fast-XP Staging", "Next Games", "WoW Dashboard", "Start WoW Server"]

proc targets(): JsonNode =
  ## Load the checked-in Softmax seed targets.
  parseFile(TargetsFile)

proc legacyTargets(): JsonNode =
  ## Return the seed without the Start key, matching menus installed before it existed.
  result = newJArray()
  for target in targets():
    if target["title"].getStr() != StartServerTitle: result.add(target)

proc art(names: openArray[string], prefix = "assets/"): Table[string, string] =
  ## Map artwork names to harmless managed paths without importing anything.
  for name in names: result[name] = prefix & name.extractFilename() & ".png"

proc navigationArt(prefix = "assets/nav-"): Table[string, string] =
  ## Map the navigation artwork to paths distinct from the legacy faces.
  for name in navigationArtworkNames(): result[name] = prefix & name.extractFilename() & ".png"

proc storedMenu(config: JsonNode, id: string): JsonNode =
  ## Return the menu object stored in a configuration so tests can edit it in place.
  for menu in config["menus"]:
    if menu["id"].getStr() == id: result = menu

proc entry(config: JsonNode, menu: string, key: int): JsonNode =
  ## Return an explicit stored Deck entry, or nil when the key is unassigned.
  for button in storedMenu(config, menu)["deck"]:
    if button["key"].getInt() == key: result = button

proc obsMenu(): JsonNode =
  ## Build the OBS submenu shape the setup tool installs, including state artwork.
  result = %*{"id": "obs", "title": "OBS", "mixer": [], "deck": [
    {"key": 1, "title": "Back", "action": {"kind": "back"}, "visual": {"image": "assets/back.png", "showTitle": false}}]}
  for index, (title, operation) in [("Record", "recordToggle"), ("Pause", "pauseToggle"),
      ("Commentary", "micToggle"), ("Open OBS", "open"), ("Minecraft 1080p", "minecraft1080")]:
    result["deck"].add(%*{"key": index + 2, "title": title, "action": {"kind": "obs", "operation": operation},
      "visual": {"image": "assets/" & operation & ".png", "showTitle": false,
        "states": {"unavailable": "assets/" & operation & "-off.png"}}})

proc liveLikeConfig(seed = legacyTargets()): JsonNode =
  ## Build the current human layout: root 2/3/4 links, OBS, Discord with calls, Softmax, and task links.
  result = installDiscordMenu(defaultButtonConfig(), art(DiscordArtworkNames))
  result = upgradeDiscordMenu(result, art(DiscordArtworkNames))
  result["menus"].add(obsMenu())
  entry(result, "root", 2)["title"] = %"OBS"
  entry(result, "root", 2)["action"] = %*{"kind": "menu", "menu": "obs", "target": "deck"}
  entry(result, "root", 2)["visual"] = %*{"image": "assets/menu-obs.png", "showTitle": false}
  result = installWorkMenu(result, seed, art(workArtworkNames(seed)))
  var linkArt = initTable[string, string]()
  for link in TaskMenuLinks: linkArt[link.art] = "assets/" & link.art.extractFilename() & ".png"
  result = installTaskMenuLinks(result, linkArt)
  result["menus"].add(%*{"id": "games", "title": "Games", "mixer": [
    {"key": 2, "title": "Mixer OBS", "action": {"kind": "menu", "menu": "obs", "target": "mixer"}}], "deck": [
    {"key": 2, "title": "Softmax", "action": {"kind": "menu", "menu": "work", "target": "deck"}}]})
  validateButtonConfig(result)

proc isNavigationEntry(button: JsonNode): bool =
  ## Recognize the exact links and Back keys the shared prefix replaces.
  let action = button["action"]
  result = action == %*{"kind": "back"}
  for menu in KnownMenus:
    if action == %*{"kind": "menu", "menu": menu, "target": "deck"}: result = true

proc preservedActions(config: JsonNode, id: string): seq[string] =
  ## Return every non-navigation action entry of a menu without its key, in canonical order.
  for button in storedMenu(config, id)["deck"]:
    if button.isNavigationEntry() or button["action"]["kind"].getStr() == "none": continue
    let copy = parseJson($button)
    copy.delete("key")
    result.add($copy)
  result.sort()

proc titlesFrom(config: JsonNode, id: string, first, last: int): seq[string] =
  ## Return the titles stored on a contiguous range of Deck keys.
  for key in first..last: result.add(entry(config, id, key)["title"].getStr())

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

proc pressDeck(key: int) =
  ## Press and release one Deck key, then act as the player uploading any new page.
  routeDeckButton(key - 1, true)
  routeDeckButton(key - 1, false)
  discard readDeckPage(0)
  deckPageReady()

proc migrate(config: JsonNode): JsonNode =
  ## Migrate with the checked-in Start seed and distinct navigation artwork paths.
  migrateNavigation(config, navigationArt(), startServerTarget(targets()))

suite "Shared navigation prefix":
  test "the live layout gains Back, OBS, Discord, Softmax on keys 1 to 4 of every known menu":
    let
      source = liveLikeConfig()
      original = $source
      updated = migrate(source)
    validateButtonConfig(updated)
    check $source == original
    for id in KnownMenus:
      let first = entry(updated, id, 1)
      if id == "root":
        check first == %*{"key": 1, "title": "Home", "action": {"kind": "menu", "menu": "root", "target": "deck"},
          "visual": {"image": "assets/nav-home.png", "showTitle": false}}
      else:
        check first == %*{"key": 1, "title": "Back", "action": {"kind": "back"},
          "visual": {"image": "assets/nav-back.png", "showTitle": false}}
      for (key, title, menu, image) in [(2, "OBS", "obs", "menu-obs"), (3, "Discord", "discord", "menu-discord"),
          (4, "Softmax", "work", "menu-work")]:
        check entry(updated, id, key) == %*{"key": key, "title": title,
          "action": {"kind": "menu", "menu": menu, "target": "deck"},
          "visual": {"image": "assets/nav-" & image & ".png", "showTitle": false}}
      check storedMenu(updated, id)["mixer"] == storedMenu(source, id)["mixer"]
    check titlesFrom(updated, "obs", 5, 9) == @ObsTitles
    check titlesFrom(updated, "discord", 5, 10) == @DiscordTitles
    check titlesFrom(updated, "work", 5, 15) == @SoftmaxTitles
    check storedMenu(updated, "obs")["deck"].len == 9
    check storedMenu(updated, "discord")["deck"].len == 10
    check storedMenu(updated, "work")["deck"].len == 15
    for key in 5..DeckKeyCount:
      check entry(updated, "root", key) == entry(source, "root", key)
    check storedMenu(updated, "games") == storedMenu(source, "games")
    check entry(updated, "work", 10)["action"]["command"].getStr() == "xdg-open http://127.0.0.1:8103/"
    check entry(updated, "work", 14)["action"]["command"].getStr() == "xdg-open http://127.0.0.1:7777/"
    check entry(updated, "work", 13)["action"]["command"].getStr() ==
      "xdg-open https://fast-xp-k8s-staging.tail0f4a29.ts.net/next/"
    check entry(updated, "work", 15) == %*{"key": 15, "title": "Start WoW Server",
      "action": {"kind": "command", "command": StartCommand},
      "visual": {"image": "assets/nav-wow-server.png", "showTitle": false}}

  test "every non-navigation action keeps its whole object and only its key changes":
    let
      source = liveLikeConfig()
      updated = migrate(source)
    for id in ["root", "obs", "discord"]:
      check preservedActions(updated, id) == preservedActions(source, id)
    var withoutStart: seq[string]
    for text in preservedActions(updated, "work"):
      if parseJson(text)["action"] != startServerAction(): withoutStart.add(text)
    check withoutStart == preservedActions(source, "work")
    check preservedActions(updated, "work").len == preservedActions(source, "work").len + 1
    for button in storedMenu(updated, "obs")["deck"]:
      if button["key"].getInt() >= FirstActionKey: check button["visual"].hasKey("states")

  test "reapplying is idempotent and never moves organized or extra actions":
    let organized = migrate(liveLikeConfig())
    check migrate(organized) == organized
    entry(organized, "root", 9)["title"] = %"Custom"
    entry(organized, "root", 9)["action"] = %*{"kind": "command", "command": "echo root"}
    entry(organized, "root", 9)["visual"] = %*{"image": "assets/root.png"}
    storedMenu(organized, "discord")["deck"].add(%*{"key": 13, "title": "Games",
      "action": {"kind": "menu", "menu": "games", "target": "both"}})
    storedMenu(organized, "obs")["deck"].add(%*{"key": 12, "title": "Scene",
      "action": {"kind": "command", "command": "echo scene"}})
    validateButtonConfig(organized)
    check migrate(organized) == organized
    let refreshed = migrateNavigation(organized, navigationArt("assets/new-"), startServerTarget(targets()))
    check entry(refreshed, "work", 4)["visual"]["image"].getStr() == "assets/new-menu-work.png"
    check entry(refreshed, "work", 15) == entry(organized, "work", 15)
    check entry(refreshed, "obs", 12) == entry(organized, "obs", 12)

  test "a legacy Start key 11 moves to key 15 once and an organized menu gets Start only when key 15 is free":
    let
      seeded = liveLikeConfig(targets())
      updated = migrate(seeded)
    validateButtonConfig(updated)
    check entry(seeded, "work", 11)["action"] == startServerAction()
    check titlesFrom(updated, "work", 5, 15) == @SoftmaxTitles
    var starts = 0
    for button in storedMenu(updated, "work")["deck"]:
      if button["action"] == startServerAction(): inc starts
    check starts == 1
    let moved = parseJson($entry(seeded, "work", 11))
    moved["key"] = %15
    check entry(updated, "work", 15) == moved
    let missing = migrate(liveLikeConfig())
    var kept = newJArray()
    for button in storedMenu(missing, "work")["deck"]:
      if button["key"].getInt() != 15: kept.add(button)
    storedMenu(missing, "work")["deck"] = kept
    check migrate(missing) == migrate(liveLikeConfig())

  test "a custom root action on key 1 is kept after the prefix instead of being lost":
    let source = liveLikeConfig()
    entry(source, "root", 1)["title"] = %"Mine"
    entry(source, "root", 1)["action"] = %*{"kind": "command", "command": "echo mine"}
    entry(source, "root", 1)["visual"] = %*{"image": "assets/mine.png", "showTitle": true}
    let updated = migrate(source)
    validateButtonConfig(updated)
    check entry(updated, "root", 5) == %*{"key": 5, "title": "Mine",
      "action": {"kind": "command", "command": "echo mine"}, "visual": {"image": "assets/mine.png", "showTitle": true}}
    check entry(updated, "root", 1)["title"].getStr() == "Home"
    check migrate(updated) == updated

  test "links to other menus or devices stay as actions":
    let source = liveLikeConfig()
    storedMenu(source, "discord")["deck"].add(%*{"key": 12, "title": "OBS both",
      "action": {"kind": "menu", "menu": "obs", "target": "both"}})
    storedMenu(source, "obs")["deck"].add(%*{"key": 14, "title": "Games",
      "action": {"kind": "menu", "menu": "games", "target": "deck"}})
    let updated = migrate(source)
    validateButtonConfig(updated)
    check entry(updated, "discord", 11)["title"].getStr() == "OBS both"
    check entry(updated, "obs", 10)["title"].getStr() == "Games"
    check entry(updated, "work", 15)["action"] == startServerAction()

  test "overflow, missing menus, ambiguous Start, foreign key 15, and unverified seeds are refused unchanged":
    var cases: seq[JsonNode]
    let overflow = liveLikeConfig()
    for key in 7..DeckKeyCount:
      storedMenu(overflow, "obs")["deck"].add(%*{"key": key, "title": "Extra " & $key,
        "action": {"kind": "command", "command": "echo " & $key}})
    cases.add(overflow)
    let workOverflow = liveLikeConfig()
    storedMenu(workOverflow, "work")["deck"].add(%*{"key": 14, "title": "Extra",
      "action": {"kind": "command", "command": "echo extra"}})
    storedMenu(workOverflow, "work")["deck"].add(%*{"key": 15, "title": "More",
      "action": {"kind": "command", "command": "echo more"}})
    cases.add(workOverflow)
    let missing = liveLikeConfig()
    var menus = newJArray()
    for menu in missing["menus"]:
      if menu["id"].getStr() != "obs": menus.add(menu)
    missing["menus"] = menus
    cases.add(missing)
    let duplicated = liveLikeConfig(targets())
    storedMenu(duplicated, "work")["deck"].add(%*{"key": 14, "title": "Start again",
      "action": {"kind": "command", "command": StartCommand}})
    cases.add(duplicated)
    let foreign = migrate(liveLikeConfig())
    entry(foreign, "work", 15)["title"] = %"Mine"
    entry(foreign, "work", 15)["action"] = %*{"kind": "command", "command": "echo mine"}
    cases.add(foreign)
    for source in cases:
      let text = $source
      expect ValueError: discard migrate(source)
      check $source == text
    let unverified = startServerTarget(targets())
    unverified["action"]["command"] = %"make -C /home/monofuel/src/wow-coworld/wow-shadow-army start-server"
    expect ValueError: discard migrateNavigation(liveLikeConfig(), navigationArt(), unverified)
    let wrongSeed = targets()
    for target in wrongSeed:
      if target["title"].getStr() == StartServerTitle: target["action"]["command"] = %"true"
    expect ValueError: discard startServerTarget(wrongSeed)

  test "every navigation artwork file exists in the repository":
    for name in navigationArtworkNames():
      check fileExists(AssetsDirectory / (name & ".png"))

  test "moved standard controls keep working with the Softmax, Discord, and link helpers":
    let organized = migrate(liveLikeConfig())
    let workArt = art(workArtworkNames(targets()), "assets/again-")
    check installWorkMenu(organized, targets(), workArt) == organized
    let launchers = refreshWorkLaunchers(organized, targets(), workArt)
    validateButtonConfig(launchers)
    check entry(launchers, "work", 6)["visual"]["image"].getStr() == "assets/again-wow-classic.png"
    check entry(launchers, "work", 8)["visual"]["image"].getStr() == "assets/again-discord.png"
    check entry(launchers, "work", 6)["title"].getStr() == "WoW Vanilla"
    let rootArt = refreshWorkMenuArtwork(organized, "assets/graph.png")
    check entry(rootArt, "root", 4)["visual"]["image"].getStr() == "assets/graph.png"
    check entry(rootArt, "work", 4) == entry(organized, "work", 4)
    let discordArt = art(DiscordArtworkNames, "assets/fresh-")
    let refreshed = refreshDiscordArtwork(organized, discordArt)
    validateButtonConfig(refreshed)
    check entry(refreshed, "discord", 5)["visual"]["image"].getStr() == "assets/fresh-system-live.png"
    check entry(refreshed, "discord", 9)["visual"]["image"].getStr() == "assets/fresh-voice-wait.png"
    check entry(refreshed, "discord", 2) == entry(organized, "discord", 2)
    let upgraded = upgradeDiscordMenu(organized, discordArt)
    check upgraded == refreshed
    check entry(upgraded, "discord", 6)["title"].getStr() == "Discord Mic"
    check activeTaskMenuLinks(organized)[0].key == PrefixSoftmaxDiscordKey
    check activeTaskMenuLinks(organized)[1].key == PrefixDiscordSoftmaxKey
    var linkArt = initTable[string, string]()
    for link in TaskMenuLinks: linkArt[link.art] = "assets/link-" & link.art.extractFilename() & ".png"
    let linked = installTaskMenuLinks(organized, linkArt)
    validateButtonConfig(linked)
    check entry(linked, "work", 3)["visual"]["image"].getStr() == "assets/link-menu-discord.png"
    check entry(linked, "discord", 4)["visual"]["image"].getStr() == "assets/link-menu-work.png"
    check entry(linked, "work", 13) == entry(organized, "work", 13)
    check entry(linked, "discord", 8) == entry(organized, "discord", 8)

  test "actual runtime navigates the shared prefix with bounded history and no launches":
    let
      directory = createTempDir("knobby-navigation-", "")
      paths = newButtonPaths(directory / "config", directory / "state")
      config = migrate(liveLikeConfig())
    defer: removeDir(directory)
    createDir(paths.configDir)
    createDir(paths.stateDir)
    writeFile(paths.configPath(), encodeConfigFile(config))
    initializeButtons(paths, ButtonServices(prepare: prepareFixture, importAsset: unusedImport))
    check buttonRuntimeStatus()["startupError"].getStr() == ""
    discard readDeckPage(0)
    deckPageReady()
    pressDeck(1)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "root"
    check buttonRuntimeStatus()["historyDepth"].getInt() == 0
    pressDeck(4)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "work"
    pressDeck(4)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "work"
    check buttonRuntimeStatus()["historyDepth"].getInt() == 1
    for swap in 1..50:
      pressDeck(3)
      check buttonRuntimeStatus()["deckMenu"].getStr() == "discord"
      check buttonRuntimeStatus()["historyDepth"].getInt() == 2
      pressDeck(4)
      check buttonRuntimeStatus()["deckMenu"].getStr() == "work"
      check buttonRuntimeStatus()["historyDepth"].getInt() == 1
    pressDeck(2)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "obs"
    pressDeck(3)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "discord"
    check buttonRuntimeStatus()["historyDepth"].getInt() == 3
    pressDeck(1)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "obs"
    pressDeck(1)
    pressDeck(1)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "root"
    check buttonRuntimeStatus()["historyDepth"].getInt() == 0
    check buttonRuntimeStatus()["mixerMenu"].getStr() == "root"
    check takeButtonActions().len == 0

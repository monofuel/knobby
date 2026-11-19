import
  std/[json, os, tables, tempfiles, unittest],
  knobby/[button_config, button_runtime, discord_menu, task_menu_links, work_menu]

const
  AssetsDirectory = currentSourcePath().parentDir().parentDir() / "assets"
  SwapCount = 100

proc artwork(prefix = "assets/"): Table[string, string] =
  ## Use harmless managed paths without importing artwork or contacting the daemon.
  for link in TaskMenuLinks: result[link.art] = prefix & link.art.extractFilename() & ".png"

proc liveLikeConfig(): JsonNode =
  ## Build a root with Discord on Deck key 3 and Softmax on Deck key 4 plus existing menu controls.
  var discordArt = initTable[string, string]()
  for name in DiscordArtworkNames: discordArt[name] = "assets/" & name & ".png"
  let
    targets = %*[
      {"key": 5, "title": "Discord", "action": {"kind": "openDiscord"}, "art": "work/discord"},
      {"key": 11, "title": "Start Server", "action": {"kind": "command", "command": "true"},
        "art": "work/server"}]
    workArt = {"work/menu-work": "assets/menu-work.png", "obs/back": "assets/back.png",
      "work/discord": "assets/discord.png", "work/server": "assets/server.png"}.toTable()
  result = installWorkMenu(installDiscordMenu(defaultButtonConfig(), discordArt), targets, workArt)

proc storedMenu(config: JsonNode, id: string): JsonNode =
  ## Return the menu object stored in a configuration so tests can edit it in place.
  for menu in config["menus"]:
    if menu["id"].getStr() == id: result = menu

proc entry(config: JsonNode, menu: string, key: int): JsonNode =
  ## Return an explicit stored Deck entry, or nil when the key is unassigned.
  for button in storedMenu(config, menu)["deck"]:
    if button["key"].getInt() == key: result = button

proc withoutLinks(config: JsonNode): JsonNode =
  ## Return a copy with both link keys removed, for comparing everything else.
  result = parseJson($config)
  for link in TaskMenuLinks:
    let deck = storedMenu(result, link.menu)["deck"]
    var kept = newJArray()
    for button in deck:
      if button["key"].getInt() != link.key: kept.add(button)
    storedMenu(result, link.menu)["deck"] = kept

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

suite "Task menu links":
  test "adds reciprocal Deck-only links and preserves every other control":
    let
      source = liveLikeConfig()
      original = $source
      updated = installTaskMenuLinks(source, artwork())
    validateButtonConfig(updated)
    check $source == original
    check withoutLinks(updated) == source
    check entry(updated, WorkMenuId, SoftmaxDiscordKey) == %*{"key": SoftmaxDiscordKey,
      "title": "Discord menu", "action": {"kind": "menu", "menu": "discord", "target": "deck"},
      "visual": {"image": "assets/menu-discord.png", "showTitle": false}}
    check entry(updated, DiscordMenuId, DiscordSoftmaxKey) == %*{"key": DiscordSoftmaxKey,
      "title": "Softmax", "action": {"kind": "menu", "menu": "work", "target": "deck"},
      "visual": {"image": "assets/menu-work.png", "showTitle": false}}
    for (menu, key) in [(WorkMenuId, 1), (WorkMenuId, 5), (WorkMenuId, 11), (DiscordMenuId, 1)]:
      check entry(updated, menu, key) == entry(source, menu, key)
    check entry(updated, WorkMenuId, 5)["action"]["kind"].getStr() == "openDiscord"
    check menuAt(updated, "root") == menuAt(source, "root")
    for id in [WorkMenuId, DiscordMenuId]:
      check menuAt(updated, id)["mixer"] == menuAt(source, id)["mixer"]

  test "the setup artwork exists in the repository":
    for link in TaskMenuLinks:
      check fileExists(AssetsDirectory / (link.art & ".png"))

  test "reinstalling is idempotent, keeps custom titles, and refreshes only the image":
    let installed = installTaskMenuLinks(liveLikeConfig(), artwork())
    check installTaskMenuLinks(installed, artwork()) == installed
    let customized = parseJson($installed)
    entry(customized, WorkMenuId, SoftmaxDiscordKey)["title"] = %"Chat"
    entry(customized, DiscordMenuId, DiscordSoftmaxKey)["visual"]["showTitle"] = %true
    let
      customizedText = $customized
      refreshed = installTaskMenuLinks(customized, artwork("assets/new-"))
    check $customized == customizedText
    validateButtonConfig(refreshed)
    let expected = parseJson(customizedText)
    entry(expected, WorkMenuId, SoftmaxDiscordKey)["visual"]["image"] = %"assets/new-menu-discord.png"
    entry(expected, DiscordMenuId, DiscordSoftmaxKey)["visual"]["image"] = %"assets/new-menu-work.png"
    check refreshed == expected
    check entry(refreshed, WorkMenuId, SoftmaxDiscordKey)["title"].getStr() == "Chat"
    check entry(refreshed, DiscordMenuId, DiscordSoftmaxKey)["visual"]["showTitle"].getBool()

  test "unassigned placeholders are replaced and foreign actions are refused unchanged":
    let placeholder = liveLikeConfig()
    storedMenu(placeholder, WorkMenuId)["deck"].add(%*{"key": SoftmaxDiscordKey, "title": "Free",
      "action": {"kind": "none"}})
    let filled = installTaskMenuLinks(placeholder, artwork())
    check entry(filled, WorkMenuId, SoftmaxDiscordKey)["title"].getStr() == "Discord menu"
    check storedMenu(filled, WorkMenuId)["deck"].len == storedMenu(placeholder, WorkMenuId)["deck"].len
    for (menu, key) in [(WorkMenuId, SoftmaxDiscordKey), (DiscordMenuId, DiscordSoftmaxKey)]:
      let occupied = installTaskMenuLinks(liveLikeConfig(), artwork())
      entry(occupied, menu, key)["action"] = %*{"kind": "claude"}
      let occupiedText = $occupied
      expect ValueError: discard installTaskMenuLinks(occupied, artwork())
      check $occupied == occupiedText
    let wrongTarget = installTaskMenuLinks(liveLikeConfig(), artwork())
    entry(wrongTarget, DiscordMenuId, DiscordSoftmaxKey)["action"]["target"] = %"both"
    expect ValueError: discard installTaskMenuLinks(wrongTarget, artwork())

  test "both menus must already exist":
    var discordArt = initTable[string, string]()
    for name in DiscordArtworkNames: discordArt[name] = "assets/" & name & ".png"
    expect ValueError: discard installTaskMenuLinks(defaultButtonConfig(), artwork())
    expect ValueError:
      discard installTaskMenuLinks(installDiscordMenu(defaultButtonConfig(), discordArt), artwork())

  test "actual runtime swaps tasks repeatedly with bounded history and no launches":
    let
      directory = createTempDir("knobby-task-links-", "")
      paths = newButtonPaths(directory / "config", directory / "state")
      config = installTaskMenuLinks(liveLikeConfig(), artwork())
    defer: removeDir(directory)
    createDir(paths.configDir)
    createDir(paths.stateDir)
    writeFile(paths.configPath(), encodeConfigFile(config))
    initializeButtons(paths, ButtonServices(prepare: prepareFixture, importAsset: unusedImport))
    check buttonRuntimeStatus()["startupError"].getStr() == ""
    discard readDeckPage(0)
    deckPageReady()
    pressDeck(WorkRootKey)
    check buttonRuntimeStatus()["deckMenu"].getStr() == WorkMenuId
    for swap in 1..SwapCount:
      pressDeck(SoftmaxDiscordKey)
      check buttonRuntimeStatus()["deckMenu"].getStr() == DiscordMenuId
      check buttonRuntimeStatus()["historyDepth"].getInt() == 2
      pressDeck(DiscordSoftmaxKey)
      check buttonRuntimeStatus()["deckMenu"].getStr() == WorkMenuId
      check buttonRuntimeStatus()["historyDepth"].getInt() == 1
    check buttonRuntimeStatus()["mixerMenu"].getStr() == "root"
    check takeButtonActions().len == 0
    pressDeck(1)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "root"
    check buttonRuntimeStatus()["historyDepth"].getInt() == 0
    pressDeck(3)
    pressDeck(DiscordSoftmaxKey)
    pressDeck(SoftmaxDiscordKey)
    check buttonRuntimeStatus()["deckMenu"].getStr() == DiscordMenuId
    check buttonRuntimeStatus()["historyDepth"].getInt() == 1
    pressDeck(1)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "root"
    check buttonRuntimeStatus()["mixerMenu"].getStr() == "root"
    check takeButtonActions().len == 0

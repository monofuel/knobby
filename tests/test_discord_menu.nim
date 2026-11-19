import
  std/[json, os, tables, tempfiles, unittest],
  knobby/[button_config, button_runtime, discord_menu]

proc artwork(): Table[string, string] =
  ## Use harmless managed paths without accessing artwork files or the daemon.
  for name in DiscordArtworkNames: result[name] = "assets/" & name & ".png"

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

suite "Discord submenu installation":
  test "adds deck-only Discord navigation and physical Help, preserving other controls":
    let source = defaultButtonConfig()
    source["menus"].add(%*{"id": "obs", "title": "OBS", "mixer": [], "deck": [
      {"key": 2, "title": "Record", "action": {"kind": "obs", "operation": "recordToggle"}}]})
    let
      original = $source
      updated = installDiscordMenu(source, artwork())
    validateButtonConfig(updated)
    check $source == original
    check menuAt(updated, "obs") == menuAt(source, "obs")
    for note in [8, 9, 10, 11, 12]:
      check buttonAt(updated, "root", "mixer", note) == buttonAt(source, "root", "mixer", note)
    check buttonAt(updated, "root", "deck", 2) == buttonAt(source, "root", "deck", 2)
    check buttonAt(updated, "root", "deck", 3)["action"]["target"].getStr() == "deck"
    check buttonAt(updated, "root", "mixer", 3)["action"]["kind"].getStr() == "mixerOverlay"
    for (key, kind) in [(1, "back"), (2, "microphones"), (3, "discord"), (4, "discordDeafen"),
        (5, "openDiscord"), (6, "discordAcceptVoice"), (7, "discordAcceptVideo")]:
      check buttonAt(updated, "discord", "deck", key)["action"]["kind"].getStr() == kind
    check updated["menus"][updated["menus"].len - 1]["mixer"].len == 0

  test "actual runtime enters Discord, dispatches duplicate actions, and returns Back":
    let
      directory = createTempDir("knobby-discord-navigation-", "")
      paths = newButtonPaths(directory / "config", directory / "state")
      config = installDiscordMenu(defaultButtonConfig(), artwork())
    defer: removeDir(directory)
    createDir(paths.configDir)
    createDir(paths.stateDir)
    writeFile(paths.configPath(), encodeConfigFile(config))
    initializeButtons(paths, ButtonServices(prepare: prepareFixture, importAsset: unusedImport))
    check buttonRuntimeStatus()["startupError"].getStr() == ""
    discard readDeckPage(0)
    deckPageReady()
    routeDeckButton(2, true)
    routeDeckButton(2, false)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "discord"
    check buttonRuntimeStatus()["mixerMenu"].getStr() == "root"
    discard readDeckPage(0)
    deckPageReady()
    routeDeckButton(1, true)
    routeDeckButton(1, false)
    routeMixerButton(11, true)
    routeMixerButton(11, false)
    let actions = takeButtonActions()
    check actions.len == 2
    for action in actions: check action["action"]["kind"].getStr() == "microphones"
    routeDeckButton(0, true)
    routeDeckButton(0, false)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "root"
    check buttonRuntimeStatus()["mixerMenu"].getStr() == "root"

  test "refuses existing menus and occupied keys without changing the input":
    let source = defaultButtonConfig()
    let installed = installDiscordMenu(source, artwork())
    expect ValueError: discard installDiscordMenu(installed, artwork())
    for device in ["mixer", "deck"]:
      let config = defaultButtonConfig()
      config["menus"][0][device].add(%*{"key": 3, "title": "Keep me", "action": {"kind": "claude"}})
      let original = $config
      expect ValueError: discard installDiscordMenu(config, artwork())
      check $config == original

  test "artwork refresh preserves custom titles and bindings":
    let source = installDiscordMenu(defaultButtonConfig(), artwork())
    source["menus"][1]["deck"][1]["title"] = %"All microphones"
    source["menus"][1]["deck"][4]["action"] = %*{"kind": "command", "command": "my-discord"}
    let original = $source
    var changed = artwork()
    for name in DiscordArtworkNames: changed[name] = "assets/updated-" & name & ".png"
    let updated = refreshDiscordArtwork(source, changed)
    validateButtonConfig(updated)
    check $source == original
    check updated["menus"][0]["mixer"] == source["menus"][0]["mixer"]
    check updated["menus"][1]["deck"][1]["title"].getStr() == "All microphones"
    check updated["menus"][1]["deck"][1]["visual"]["image"].getStr() == changed["system-live"]
    check updated["menus"][1]["deck"][4] == source["menus"][1]["deck"][4]
    expect ValueError: discard refreshDiscordArtwork(defaultButtonConfig(), changed)

  test "call upgrade is idempotent and preserves existing menus, mixer, and custom titles":
    let source = installDiscordMenu(defaultButtonConfig(), artwork())
    source["menus"][1]["deck"].elems.setLen(5)
    source["menus"][1]["deck"][1]["title"] = %"My microphones"
    let original = $source
    let updated = upgradeDiscordMenu(source, artwork())
    validateButtonConfig(updated)
    check $source == original
    check updated["menus"][0] == source["menus"][0]
    check updated["menus"][1]["mixer"] == source["menus"][1]["mixer"]
    check updated["menus"][1]["deck"][1]["title"].getStr() == "My microphones"
    check buttonAt(updated, "discord", "deck", 6)["action"]["kind"].getStr() == "discordAcceptVoice"
    check buttonAt(updated, "discord", "deck", 7)["action"]["kind"].getStr() == "discordAcceptVideo"
    check upgradeDiscordMenu(updated, artwork()) == updated

  test "call upgrade refuses occupied slots without modifying the source":
    for number in [6, 7]:
      let source = installDiscordMenu(defaultButtonConfig(), artwork())
      for button in source["menus"][1]["deck"]:
        if button["key"].getInt() == number:
          button["action"] = %*{"kind": "command", "command": "keep-my-button"}
      let original = $source
      expect ValueError: discard upgradeDiscordMenu(source, artwork())
      check $source == original

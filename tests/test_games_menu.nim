import
  std/[json, os, strutils, tables, tempfiles, unittest],
  knobby/[actions, button_config, button_runtime, games_menu]

proc fixture(): JsonNode =
  ## Describe the current navigation with existing controls that must survive installation.
  let
    home = %*{"key": 1, "title": "Home", "action": {"kind": "menu", "menu": "root", "target": "deck"}}
    toggle = %*{"key": 5, "title": "Menu", "action": {"kind": "deckMenu", "menu": "deck-navigation"}}
  %*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Home", "mixer": [{"key": 10, "title": "FFXIV", "action": {"kind": "ffxiv"}}],
      "deck": [{"key": 1, "action": {"kind": "none"}},
        {"key": 6, "title": "Music", "action": {"kind": "command", "command": "preserved-music"}}]},
    {"id": "obs", "title": "OBS", "mixer": [], "deck": [home, toggle,
      {"key": 3, "title": "Record", "action": {"kind": "obs", "operation": "recordToggle"}}]},
    {"id": "deck-navigation", "title": "Menu", "mixer": [], "deck": [home, toggle,
      {"key": 2, "title": "OBS", "action": {"kind": "menu", "menu": "obs", "target": "deck"}}]}]}

proc artwork(): Table[string, string] =
  ## Supply distinct managed paths without importing media or reading hardware.
  for name in GamesArtwork: result[name] = "assets/" & name.replace("/", "-") & ".png"

proc fakePrepare(config: JsonNode): JsonNode {.gcsafe.} =
  ## Return inert prepared frames for each page without starting a renderer or device.
  result = %*{"version": 1, "menus": {}}
  for menu in config["menus"]:
    result["menus"][menu["id"].getStr()] = newJObject()
    for key in 1..DeckKeyCount:
      result["menus"][menu["id"].getStr()][$key] = %*{
        "normal": [{"path": "/fixture/key.jpg", "durationMs": 0}], "pressed": "/fixture/held.jpg"}

proc fakeImport(source: string): string {.gcsafe.} =
  ## Reject unexpected imports from the private runtime fixture.
  raise newException(IOError, "No imports expected.")

proc writeHelper(path, text: string) =
  ## Write a harmless executable whose only effects are private fixture captures.
  writeFile(path, "#!/bin/sh\nset -eu\n" & text)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

suite "Games menu":
  test "art refresh changes only the unique launcher's image and preserves edits":
    let before = installGamesMenu(fixture(), artwork())
    before["menus"][^1]["deck"][3]["key"] = %8
    before["menus"][^1]["deck"][3]["title"] = %"My adventure"
    before["menus"][^1]["deck"][3]["visual"]["showTitle"] = %true
    let expected = parseJson($before)
    expected["menus"][^1]["deck"][3]["visual"]["image"] = %"assets/new.png"
    check refreshDecompboundArtwork(before, "assets/new.png") == expected
    check buttonAt(before, GamesMenuId, "deck", 8)["visual"]["image"].getStr() != "assets/new.png"
    let duplicate = parseJson($before)
    let copy = parseJson($before["menus"][^1]["deck"][3])
    copy["key"] = %9
    duplicate["menus"][^1]["deck"].add(copy)
    expect ValueError: discard refreshDecompboundArtwork(duplicate, "assets/new.png")
    before["menus"][^1]["deck"][3]["action"]["command"] = %"custom-command"
    expect ValueError: discard refreshDecompboundArtwork(before, "assets/new.png")

  test "adds only Home7 and three editable launch actions with normal navigation":
    let before = fixture()
    let after = installGamesMenu(before, artwork())
    let expected = parseJson($before)
    expected["menus"][0]["deck"].add(buttonAt(after, "root", "deck", 7))
    expected["menus"].add(after["menus"][^1])
    check after == expected
    check installGamesMenu(after, artwork()) == after
    check buttonAt(after, GamesMenuId, "deck", 2)["action"] == %*{"kind": "ffxiv"}
    check buttonAt(after, GamesMenuId, "deck", 3)["action"]["command"].getStr() == decompboundCommand()
    check buttonAt(after, GamesMenuId, "deck", 4)["action"]["command"].getStr() == monoRetroCommand()
    check buttonAt(after, GamesMenuId, "deck", 15)["action"] == %*{"kind": "back"}
    let edited = parseJson($after)
    edited["menus"][^1]["deck"][2]["title"] = %"My game title"
    check installGamesMenu(edited, artwork()) == edited
    var occupied = fixture()
    occupied["menus"][0]["deck"].add(%*{"key": 7, "action": {"kind": "command", "command": "keep-me"}})
    expect ValueError: discard installGamesMenu(occupied, artwork())

  test "navigation captures the intended actions and Back preserves the independent MIDI page":
    let directory = createTempDir("knobby-games-menu-", "")
    defer: removeDir(directory)
    let paths = newButtonPaths(directory / "config", directory / "state")
    writeFileAtomic(paths.configPath(), encodeConfigFile(installGamesMenu(fixture(), artwork())))
    initializeButtons(paths, ButtonServices(prepare: fakePrepare, importAsset: fakeImport))
    startButtonWorker()
    defer: stopButtonWorker()
    var seen: int64
    proc press(key: int) =
      ## Route only the private fixture's input and acknowledge its inert display page.
      let page = readDeckPage(seen)
      if not page.isNil: seen = page["generation"].getBiggestInt()
      deckPageReady()
      routeDeckButton(key-1, true)
      routeDeckButton(key-1, false)
    press(7)
    check buttonRuntimeStatus()["deckMenu"].getStr() == GamesMenuId
    for key in 2..4: press(key)
    let captured = takeButtonActions()
    check captured.len == 3
    check captured[0]["action"]["kind"].getStr() == "ffxiv"
    check captured[1]["action"]["command"].getStr() == decompboundCommand()
    check captured[2]["action"]["command"].getStr() == monoRetroCommand()
    press(5)
    press(5)
    check takeButtonActions().len == 0
    check buttonRuntimeStatus()["deckMenu"].getStr() == GamesMenuId
    press(5)
    press(2)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "obs"
    check takeButtonActions().len == 0
    press(1)
    press(7)
    press(15)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "root"
    check buttonRuntimeStatus()["mixerMenu"].getStr() == "root"
    press(7)
    press(1)
    check buttonRuntimeStatus()["deckMenu"].getStr() == "root"

  test "detached dispatch uses the exact cwd, argv and inherited environment without starting applications":
    let
      directory = createTempDir("knobby-games-launch-", "")
      project = directory / "project ' with spaces"
      nativeMenu = directory / "native ' menu"
      oldPath = getEnv("PATH")
      oldCapture = getEnv("KNOBBY_GAMES_CAPTURE")
      oldSentinel = getEnv("KNOBBY_GAMES_SENTINEL")
    defer:
      putEnv("PATH", oldPath)
      putEnv("KNOBBY_GAMES_CAPTURE", oldCapture)
      putEnv("KNOBBY_GAMES_SENTINEL", oldSentinel)
      removeDir(directory)
    createDir(project)
    writeHelper(directory / "systemd-run", "while [ \"$1\" != -- ]; do shift; done\nshift\nexec \"$@\"\n")
    let capture = "printf '%s\\n' \"$PWD\" \"$KNOBBY_GAMES_SENTINEL\" \"$@\" > \"$KNOBBY_GAMES_CAPTURE\"\n"
    writeHelper(directory / "nix", capture)
    writeHelper(nativeMenu, capture)
    putEnv("PATH", directory)
    putEnv("KNOBBY_GAMES_CAPTURE", directory / "captured")
    putEnv("KNOBBY_GAMES_SENTINEL", "preserved")
    let command = decompboundCommand(project)
    doAssert command == "cd " & quoteShell(project) & " && exec nix develop --command make libretro-viewport-play"
    executeButtonAction(%*{"kind": "command", "command": command})
    check readFile(directory / "captured").strip().splitLines() == @[
      project, "preserved", "develop", "--command", "make", "libretro-viewport-play"]
    let nativeCommand = monoRetroCommand(nativeMenu)
    doAssert nativeCommand == "exec " & quoteShell(nativeMenu)
    executeButtonAction(%*{"kind": "command", "command": nativeCommand})
    check readFile(directory / "captured").strip().splitLines() == @[getCurrentDir(), "preserved"]

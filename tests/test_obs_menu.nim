import
  std/[json, tables, unittest],
  knobby/[button_config, obs_menu]

proc fixture(): JsonNode =
  ## Build a navigation-ready menu with existing recordings and custom bindings.
  result = %*{"version": 1, "root": "main", "menus": []}
  for id in ["main", "obs", "discord", "work"]:
    let menu = %*{"id": id, "title": id, "mixer": [], "deck": []}
    for index, target in ["main", "obs", "discord", "work"]:
      menu["deck"].add(%*{"key": index + 1, "title": target,
        "action": {"kind": "menu", "menu": target, "target": "deck"},
        "visual": {"image": "assets/" & target & ".png", "showTitle": false}})
    if id == "obs":
      menu["deck"].add(%*{"key": 5, "title": "Record",
        "action": {"kind": "obs", "operation": "recordToggle"}})
      menu["mixer"].add(%*{"key": 8, "title": "Custom", "action": {"kind": "command", "command": "echo fixture"}})
    result["menus"].add(menu)

proc artwork(prefix = "assets/"): Table[string, string] =
  ## Resolve the new faces to harmless managed paths.
  for name in ObsSetupsArtworkNames: result[name] = prefix & name & ".png"

suite "OBS setups submenu":
  test "adding the nested menu preserves existing menus, controls, and Home conventions":
    let
      source = fixture()
      original = $source
      installed = installObsSetupsMenu(source, artwork())
    validateButtonConfig(installed)
    check $source == original
    check installed["menus"].len == source["menus"].len + 1
    for index in 0..<source["menus"].len:
      let before = source["menus"][index]
      let after = installed["menus"][index]
      check after["mixer"] == before["mixer"]
      if before["id"].getStr() != "obs": check after == before
      else:
        check after["deck"].len == before["deck"].len + 1
        for slot in 0..<before["deck"].len: check after["deck"][slot] == before["deck"][slot]
    check buttonAt(installed, "obs", "deck", 10)["action"] ==
      %*{"kind": "menu", "menu": ObsSetupsMenuId, "target": "deck"}
    check buttonAt(installed, ObsSetupsMenuId, "deck", 1)["action"] ==
      %*{"kind": "menu", "menu": "main", "target": "deck"}
    for (key, operation) in [(5, "selectMinecraft"), (6, "selectFirefox"), (7, "selectWow"),
        (10, "minecraft1080"), (11, "firefox1080"), (12, "wow1080")]:
      check buttonAt(installed, ObsSetupsMenuId, "deck", key)["action"] ==
        %*{"kind": "obs", "operation": operation}
    check installObsSetupsMenu(installed, artwork("assets/reimported-")) == installed

  test "upgrade moves the old Firefox action and preserves custom art, navigation and MIDI":
    let installed = installObsSetupsMenu(fixture(), artwork())
    let legacy = installed["menus"][4]
    legacy["mixer"].add(%*{"key": 1, "title": "Back", "action": {"kind": "back"}})
    legacy["mixer"].add(%*{"key": 8, "title": "Keep", "action": {"kind": "none"}})
    let oldDeck = newJArray()
    for index in 0..<6: oldDeck.add(legacy["deck"][index])
    oldDeck.add(%*{"key": 7, "title": "My Firefox 1080p", "action": {"kind": "obs", "operation": "firefox1080"},
      "visual": {"image": "assets/custom-firefox.gif"}})
    legacy["deck"] = oldDeck
    legacy["deck"][4]["visual"]["image"] = %"assets/my-minecraft.gif"
    let
      before = $installed
      upgraded = installObsSetupsMenu(installed, artwork())
    check $installed == before
    check upgraded["menus"][4]["mixer"] == legacy["mixer"]
    for index in 0..<6: check upgraded["menus"][4]["deck"][index] == legacy["deck"][index]
    check buttonAt(upgraded, ObsSetupsMenuId, "deck", 7)["action"]["operation"].getStr() == "selectWow"
    check buttonAt(upgraded, ObsSetupsMenuId, "deck", 11)["visual"]["image"].getStr() == "assets/custom-firefox.gif"
    check buttonAt(upgraded, ObsSetupsMenuId, "deck", 11)["title"].getStr() == "My Firefox 1080p"
    check installObsSetupsMenu(upgraded, artwork()) == upgraded

  test "custom slots and custom artwork survive repeat setup":
    let source = fixture()
    source["menus"][1]["deck"].add(%*{"key": 10, "title": "My image",
      "action": {"kind": "none"}, "visual": {"image": "assets/mine.png"}})
    let installed = installObsSetupsMenu(source, artwork())
    check buttonAt(installed, "obs", "deck", 10)["title"].getStr() == "My image"
    check buttonAt(installed, "obs", "deck", 11)["action"]["menu"].getStr() == ObsSetupsMenuId
    installed["menus"][4]["deck"][4]["visual"]["image"] = %"assets/my-project.gif"
    check installObsSetupsMenu(installed, artwork()) == installed

  test "overflow or edited setups fail without changing the original":
    let source = fixture()
    for key in 10..15:
      source["menus"][1]["deck"].add(%*{"key": key, "title": "Custom",
        "action": {"kind": "command", "command": "echo fixture"}})
    let original = $source
    expect ValueError: discard installObsSetupsMenu(source, artwork())
    check $source == original
    let installed = installObsSetupsMenu(fixture(), artwork())
    installed["menus"][4]["deck"][4]["action"] = %*{"kind": "command", "command": "echo custom"}
    let before = $installed
    expect ValueError: discard installObsSetupsMenu(installed, artwork())
    check $installed == before

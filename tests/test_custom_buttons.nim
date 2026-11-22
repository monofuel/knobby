import
  std/[json, unittest],
  knobby/[button_config, custom_buttons, spotify_menu]

suite "Custom button metadata":
  test "canonical metadata survives round trips without changing runtime actions":
    let config = defaultButtonConfig()
    config["menus"][0]["deck"][1]["action"] = %*{"kind": "command", "command": "integration"}
    config["menus"][0]["deck"][1]["customLogic"] = %true
    let canonical = canonicalButtonConfig(config)
    check buttonAt(canonical, "root", "deck", 2)["customLogic"].getBool()
    check parseButtonSet(canonical).menus[0].deck[1].action.command == "integration"
    check canonicalButtonConfig(canonical) == canonical
    config["menus"][0]["deck"][1]["customLogic"] = %"true"
    expect ButtonConfigError: validateButtonConfig(config)
    config["menus"][0]["deck"][1]["customLogic"] = %true
    config["menus"][0]["deck"][1]["action"] = %*{"kind": "none"}
    expect ButtonConfigError: validateButtonConfig(config)

  test "flags only managed integrations and removes only unused numbered placeholders":
    let config = defaultButtonConfig()
    let deck = config["menus"][0]["deck"]
    deck[1]["action"] = %*{"kind": "command", "command": spotifyCommand("here")}
    deck[2]["action"] = %*{"kind": "command", "command": "xdg-open https://polyworld.gg/"}
    deck[6]["action"] = %*{"kind": "command", "command": "keep-assigned-seven"}
    deck[7]["visual"] = %*{"image": "assets/custom-eight.png", "showTitle": false}
    let original = $config
    let updated = markCustomButtons(config, newJArray())
    check $config == original
    check buttonAt(updated, "root", "deck", 2)["customLogic"].getBool()
    check not buttonAt(updated, "root", "deck", 3).hasKey("customLogic")
    check buttonAt(updated, "root", "deck", 7) == buttonAt(config, "root", "deck", 7)
    check buttonAt(updated, "root", "deck", 8) == buttonAt(config, "root", "deck", 8)
    for key in 9..15:
      check buttonAt(updated, "root", "deck", key)["action"]["kind"].getStr() == "none"
      check buttonAt(updated, "root", "deck", key){"visual"}{"builtinNumber"}.isNil
    check markCustomButtons(updated, newJArray()) == updated

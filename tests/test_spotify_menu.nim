import
  std/[json, strutils, tables, unittest],
  ../src/knobby/[button_config, spotify_menu]

proc fixture(): JsonNode =
  ## Build the current navigation with unrelated customized controls to preserve.
  let
    home = %*{"key": 1, "title": "Home", "action": {"kind": "menu", "menu": "root", "target": "deck"},
      "visual": {"image": "assets/home.png"}}
    toggle = %*{"key": 5, "title": "Menu", "action": {"kind": "deckMenu", "menu": "deck-navigation"},
      "visual": {"image": "assets/menu.png"}}
  result = %*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Home", "mixer": [{"key": 3, "title": "Help", "action": {"kind": "mixerOverlay"}}],
      "deck": [{"key": 1, "title": "Home", "action": {"kind": "none"}},
        {"key": 5, "title": "", "action": {"kind": "none"}},
        {"key": 6, "title": "6", "action": {"kind": "none"}},
        {"key": 10, "title": "Custom", "action": {"kind": "command", "command": "custom"}}]},
    {"id": "obs", "title": "OBS", "mixer": [], "deck": [home, toggle,
      {"key": 3, "title": "Record", "action": {"kind": "obs", "operation": "recordToggle"}}]},
    {"id": "deck-navigation", "title": "Menus", "mixer": [], "deck": [home, toggle]},
    {"id": "work", "title": "Softmax", "mixer": [], "deck": [
      {"key": 10, "title": "Next Games", "action": {"kind": "command", "command": "xdg-open https://polyworld.gg/"}}]}]}

proc artwork(): Table[string, string] =
  ## Return distinct managed paths without importing or rendering media.
  for name in SpotifyArtwork: result[name] = "assets/" & name.replace("/", "-") & ".png"

suite "Spotify menu installation":
  test "adds only Home6 and Spotify with the four requested commands":
    let
      before = fixture()
      original = $before
      after = installSpotifyMenu(before, artwork())
    check $before == original
    validateButtonConfig(after)
    check after["menus"].len == before["menus"].len + 1
    check after["menus"][0]["mixer"] == before["menus"][0]["mixer"]
    for index in 1..<before["menus"].len: check after["menus"][index] == before["menus"][index]
    for key in 1..15:
      if key != 6: check buttonAt(before, "root", "deck", key) == buttonAt(after, "root", "deck", key)
    check buttonAt(after, "root", "deck", 6)["action"] == %*{"kind": "menu", "menu": "spotify", "target": "deck"}
    check buttonAt(after, "spotify", "deck", 1)["action"] == %*{"kind": "menu", "menu": "root", "target": "deck"}
    check buttonAt(after, "spotify", "deck", 5) == buttonAt(after, "obs", "deck", 5)
    for (key, title, operation, art) in SpotifyCommands:
      let entry = buttonAt(after, "spotify", "deck", key)
      check entry["title"].getStr() == title
      check entry["action"]["command"].getStr() == "systemd-cat --identifier=knobby-spotify \"$HOME/.local/bin/knobby-spotify\" " & operation
      check entry["visual"]["image"].getStr() == artwork()[art]

  test "is idempotent and preserves subsequent human artwork and layout edits":
    let after = installSpotifyMenu(fixture(), artwork())
    after["menus"][^1]["deck"][2]["title"] = %"My playback"
    check installSpotifyMenu(after, artwork()) == after

  test "refuses an occupied Home slot and an unrelated existing Spotify menu":
    let occupied = fixture()
    occupied["menus"][0]["deck"][2]["action"] = %*{"kind": "command", "command": "human-command"}
    expect ValueError: discard installSpotifyMenu(occupied, artwork())
    let conflict = fixture()
    conflict["menus"].add(%*{"id": "spotify", "title": "Human", "mixer": [], "deck": []})
    expect ValueError: discard installSpotifyMenu(conflict, artwork())

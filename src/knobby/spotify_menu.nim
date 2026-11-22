import
  std/[json, tables],
  ./button_config

const
  SpotifyMenuId* = "spotify"
  SpotifyRootKey* = 6
  SpotifyArtwork* = ["spotify/menu", "spotify/here", "spotify/zero", "spotify/low-roar", "spotify/ambient"]
  SpotifyCommands* = [
    (2, "Play Here", "here", "spotify/here"),
    (3, "0 - Low Roar", "zero", "spotify/zero"),
    (4, "Low Roar - Low Roar", "low-roar", "spotify/low-roar"),
    (6, "Ambient", "ambient", "spotify/ambient")]

proc spotifyFace(key: int, title: string, action: JsonNode, image: string): JsonNode =
  ## Build a normal editable button with its label baked into whole-pixel artwork.
  %*{"key": key, "title": title, "action": action,
    "visual": {"image": image, "showTitle": false}}

proc spotifyCommand*(operation: string): string =
  ## Build the installed helper command with journal feedback for one explicit music action.
  "systemd-cat --identifier=knobby-spotify \"$HOME/.local/bin/knobby-spotify\" " & operation

proc installSpotifyMenu*(source: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Add only Spotify's Home entry and submenu, refusing to replace unrelated controls or menus.
  result = parseJson($source)
  var root, drawer, existing: JsonNode
  for menu in result["menus"]:
    if menu["id"].getStr() == result["root"].getStr(): root = menu
    if menu["id"].getStr() == "deck-navigation": drawer = menu
    if menu["id"].getStr() == SpotifyMenuId: existing = menu
  if root.isNil or drawer.isNil:
    raise newException(ValueError, "Spotify setup requires the current Home1/Menu5 workflow layout.")
  let action = %*{"kind": "menu", "menu": SpotifyMenuId, "target": "deck"}
  var slot = -1
  for index, button in root["deck"].elems:
    if button["key"].getInt() == SpotifyRootKey:
      slot = index
      if button["action"] != action and button["action"]{"kind"}.getStr() != "none":
        raise newException(ValueError, "Home key 6 contains a custom action; refusing to replace it.")
  if not existing.isNil:
    if slot < 0 or root["deck"][slot]["action"] != action:
      raise newException(ValueError, "An unrelated Spotify menu already exists; refusing to replace it.")
  else:
    let home = buttonAt(source, "deck-navigation", "deck", 1)
    let toggle = buttonAt(source, "obs", "deck", 5)
    if home["action"] != %*{"kind": "menu", "menu": result["root"], "target": "deck"} or
        toggle["action"]{"kind"}.getStr() != "deckMenu":
      raise newException(ValueError, "Spotify setup requires the current Home1/Menu5 navigation.")
    var deck = newJArray()
    deck.add(home)
    deck.add(toggle)
    for (key, title, operation, art) in SpotifyCommands:
      let button = spotifyFace(key, title,
        %*{"kind": "command", "command": spotifyCommand(operation)}, artwork[art])
      button["customLogic"] = %true
      deck.add(button)
    result["menus"].add(%*{"id": SpotifyMenuId, "title": "Spotify", "mixer": [], "deck": deck})
  if slot < 0:
    root["deck"].add(spotifyFace(SpotifyRootKey, "Spotify", action, artwork[SpotifyArtwork[0]]))
  elif root["deck"][slot]["action"] != action:
    root["deck"].elems[slot] = spotifyFace(SpotifyRootKey, "Spotify", action, artwork[SpotifyArtwork[0]])
  validateButtonConfig(result)

proc refreshSpotifyAlbumArtwork*(source: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Refresh only the two album images, finding moved buttons by their exact action and retaining user edits.
  result = parseJson($source)
  for operation in ["zero", "low-roar"]:
    let action = %*{"kind": "command", "command": spotifyCommand(operation)}
    var matches = 0
    for menu in result["menus"]:
      if menu["id"].getStr() == SpotifyMenuId:
        for button in menu["deck"]:
          if button["action"] == action:
            inc matches
            if not button.hasKey("visual"):
              button["visual"] = %*{"showTitle": false}
            button["visual"]["image"] = %artwork["spotify/" & operation]
    if matches != 1:
      raise newException(ValueError, "Spotify album " & operation & " needs exactly one standard action; refusing to replace custom controls.")
  validateButtonConfig(result)

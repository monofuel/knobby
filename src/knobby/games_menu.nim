import
  std/[json, os, tables],
  ./button_config

const
  GamesMenuId* = "games"
  GamesRootKey* = 7
  GamesArtwork* = ["games/menu", "games/ffxiv", "games/decompbound", "games/mono-retro", "games/back"]
  DecompboundDirectory* = "/home/monofuel/Documents/Projects/Sygnosphere/decompbound"
  MonoRetroLauncher* = "/home/monofuel/bin/mono-retro"

proc decompboundCommand*(directory = DecompboundDirectory): string =
  ## Run the requested viewport target in its own supported development environment.
  "cd " & quoteShell(directory) & " && exec nix develop --command make libretro-viewport-play"

proc monoRetroCommand*(launcher = MonoRetroLauncher): string =
  ## Reuse the installed native desktop wrapper and its configured library and player.
  "exec " & quoteShell(launcher)

proc gamesFace(key: int, title: string, action: JsonNode, image: string): JsonNode =
  ## Build an ordinary editable key with a labeled native-pixel image.
  %*{"key": key, "title": title, "action": action,
    "visual": {"image": image, "showTitle": false}}

proc refreshDecompboundArtwork*(source: JsonNode, imagePath: string): JsonNode =
  ## Replace only the image of the unique standard Decompbound action, preserving editor changes.
  result = parseJson($source)
  let action = %*{"kind": "command", "command": decompboundCommand()}
  var matches = 0
  for menu in result["menus"]:
    if menu["id"].getStr() == GamesMenuId:
      for button in menu["deck"]:
        if button["action"] == action:
          inc matches
          if not button.hasKey("visual"): button["visual"] = newJObject()
          button["visual"]["image"] = %imagePath
  if matches != 1:
    raise newException(ValueError, "Decompbound needs exactly one standard action; refusing to replace custom controls.")
  validateButtonConfig(result)

proc installGamesMenu*(source: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Add Games without replacing other pages, MIDI bindings or an occupied Home entry.
  result = parseJson($source)
  var root, existing: JsonNode
  for menu in result["menus"]:
    if menu["id"].getStr() == result["root"].getStr(): root = menu
    if menu["id"].getStr() == GamesMenuId: existing = menu
  if root.isNil: raise newException(ValueError, "Home menu is missing.")
  let action = %*{"kind": "menu", "menu": GamesMenuId, "target": "deck"}
  var slot = -1
  for index, button in root["deck"].elems:
    if button["key"].getInt() == GamesRootKey:
      slot = index
      if button["action"] != action and button["action"]{"kind"}.getStr() != "none":
        raise newException(ValueError, "Home key 7 is occupied; refusing to replace it.")
  if not existing.isNil:
    if slot < 0 or root["deck"][slot]["action"] != action:
      raise newException(ValueError, "An unrelated Games menu already exists.")
  else:
    let home = parseJson($buttonAt(result, "deck-navigation", "deck", 1))
    let toggle = parseJson($buttonAt(result, "obs", "deck", 5))
    if home["action"] != %*{"kind": "menu", "menu": result["root"], "target": "deck"} or
        toggle["action"]{"kind"}.getStr() != "deckMenu":
      raise newException(ValueError, "Games requires the existing Home1/Menu5 navigation.")
    result["menus"].add(%*{"id": GamesMenuId, "title": "Games", "mixer": [], "deck": [
      home, toggle,
      gamesFace(2, "FFXIV", %*{"kind": "ffxiv"}, artwork["games/ffxiv"]),
      gamesFace(3, "Decompbound", %*{"kind": "command", "command": decompboundCommand()}, artwork["games/decompbound"]),
      gamesFace(4, "Mono Retro", %*{"kind": "command", "command": monoRetroCommand()}, artwork["games/mono-retro"]),
      gamesFace(15, "Back", %*{"kind": "back"}, artwork["games/back"]) ]})
    let entry = gamesFace(GamesRootKey, "Games", action, artwork["games/menu"])
    if slot < 0: root["deck"].add(entry)
    else: root["deck"].elems[slot] = entry
  validateButtonConfig(result)

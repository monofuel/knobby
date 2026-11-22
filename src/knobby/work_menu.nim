import
  std/[json, tables]

const
  WorkMenuId* = "work"
  WorkMenuTitle* = "Softmax"
  WorkRootKey* = 4
  WorkMenuArt* = "work/menu-work"
  WorkBackArt* = "obs/back"
  WorkLauncherKeys* = [3, 4, 5]

proc workArtworkNames*(targets: JsonNode): seq[string] =
  ## Return every artwork name the Work menu needs, in first-use order, without duplicates.
  var names = @[WorkMenuArt, WorkBackArt]
  for target in targets:
    names.add(target["art"].getStr())
    if target.hasKey("states"):
      for state, art in target["states"].pairs: names.add(art.getStr())
  for name in names:
    if name notin result: result.add(name)

proc workButton(target: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Build a Deck key face from one target, resolving artwork names to managed paths.
  result = %*{"key": target["key"].getInt(), "title": target["title"].getStr(),
    "action": target["action"],
    "visual": {"image": artwork[target["art"].getStr()], "showTitle": false}}
  if target.hasKey("customLogic"): result["customLogic"] = target["customLogic"]
  if target.hasKey("states"):
    result["visual"]["states"] = newJObject()
    for state, art in target["states"].pairs:
      result["visual"]["states"][state] = %artwork[art.getStr()]

proc sameControl(current, wanted: JsonNode): bool =
  ## Compare one button by title and action, ignoring its key and artwork paths.
  result = true
  for field in ["title", "action"]:
    if current{field} != wanted[field]: result = false

proc containsControls(current, wanted: JsonNode): bool =
  ## Check standard controls by title and action at any key while retaining extra user buttons.
  result = true
  for expected in wanted:
    var found = false
    for installed in current:
      if sameControl(installed, expected): found = true
    if not found: result = false

proc installWorkMenu*(source, targets: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Return an owned configuration adding the Deck-only Softmax menu at root Deck key 4.
  ## An existing installation holding every standard control, at any key and alongside extra
  ## navigation or custom keys, is returned unchanged; any other occupant is refused.
  result = parseJson($source)
  var root, existing: JsonNode
  for menu in result["menus"]:
    if menu["id"].getStr() == WorkMenuId: existing = menu
    if menu["id"].getStr() == result["root"].getStr(): root = menu
  if root.isNil:
    raise newException(ValueError, "The root menu is missing.")
  let menu = %*{"id": WorkMenuId, "title": WorkMenuTitle, "mixer": [], "deck": [
    {"key": 1, "title": "Back", "action": {"kind": "back"},
      "visual": {"image": artwork[WorkBackArt], "showTitle": false}}]}
  for target in targets:
    if target["key"].getInt() == 1:
      raise newException(ValueError, "Softmax key 1 is reserved for Back.")
    menu["deck"].add(workButton(target, artwork))
  let entry = %*{"key": WorkRootKey, "title": WorkMenuTitle,
    "action": {"kind": "menu", "menu": WorkMenuId, "target": "deck"},
    "visual": {"image": artwork[WorkMenuArt], "showTitle": false}}
  var slot = -1
  for index in 0..<root["deck"].len:
    if root["deck"][index]["key"].getInt() == WorkRootKey: slot = index
  if not existing.isNil:
    var
      navigationMatches = false
      controls = newJArray()
    for button in existing["deck"]:
      if button["key"].getInt() == 1:
        navigationMatches = sameControl(button, menu["deck"][0]) or
          button["action"] == %*{"kind": "menu", "menu": result["root"], "target": "deck"}
    for button in menu["deck"]:
      if button["key"].getInt() != 1: controls.add(button)
    let unchanged = containsControls(root["deck"], %*[entry]) and
      existing["mixer"].len == 0 and navigationMatches and containsControls(existing["deck"], controls)
    if not unchanged:
      raise newException(ValueError, "A different Softmax menu already exists; use the editor to change it.")
  elif slot >= 0 and root["deck"][slot]["action"]["kind"].getStr() != "none":
    raise newException(ValueError, "Root deck key " & $WorkRootKey & " already has an action; refusing to replace it.")
  else:
    if slot >= 0: root["deck"].elems[slot] = entry
    else: root["deck"].add(entry)
    result["menus"].add(menu)

proc uniqueAction(deck, action: JsonNode, description: string): JsonNode =
  ## Return the single Deck entry running an action at any key, refusing none or several.
  var count = 0
  for button in deck:
    if button{"action"} == action:
      result = button
      inc count
  if count != 1:
    raise newException(ValueError, description & " must run its standard action on exactly one key; found " &
      $count & ". Refusing to change it.")

proc refreshWorkMenuArtwork*(source: JsonNode, imagePath: string): JsonNode =
  ## Return an owned configuration whose root Deck Softmax entry, at whichever key it occupies,
  ## shows a new image. Only that entry's visual image changes; a missing or ambiguous entry is refused.
  result = parseJson($source)
  var root: JsonNode
  for menu in result["menus"]:
    if menu["id"].getStr() == result["root"].getStr(): root = menu
  if root.isNil:
    raise newException(ValueError, "The root menu is missing.")
  let entry = uniqueAction(root["deck"], %*{"kind": "menu", "menu": WorkMenuId, "target": "deck"},
    "The root Softmax key")
  if not entry.hasKey("visual"): entry["visual"] = newJObject()
  entry["visual"]["image"] = %imagePath

proc launcherTarget(targets: JsonNode, key: int): JsonNode =
  ## Return the standard target whose seed key identifies one refreshed Softmax launcher.
  for target in targets:
    if target["key"].getInt() == key: result = target
  if result.isNil:
    raise newException(ValueError, "The targets file has no Softmax key " & $key & ".")

proc workLauncherArtworkNames*(targets: JsonNode): seq[string] =
  ## Return the artwork names shown by the refreshed launcher keys, in key order.
  for key in WorkLauncherKeys:
    let target = launcherTarget(targets, key)
    result.add(target["art"].getStr())
    if target.hasKey("states"):
      for state, art in target["states"].pairs: result.add(art.getStr())

proc refreshWorkLaunchers*(source, targets: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Return an owned configuration whose WoW and Discord Softmax launchers use the standard titles and faces.
  ## Each launcher is found by its exact standard action at whichever key it occupies, and keeps that key;
  ## a missing or duplicated launcher is refused. Only those keys' titles, images, and state images
  ## change, so states absent from a target are removed.
  result = parseJson($source)
  var menu: JsonNode
  for candidate in result["menus"]:
    if candidate["id"].getStr() == WorkMenuId: menu = candidate
  if menu.isNil:
    raise newException(ValueError, "The Softmax menu is not installed; use --apply first.")
  for key in WorkLauncherKeys:
    let target = launcherTarget(targets, key)
    let button = uniqueAction(menu["deck"], target["action"], "The Softmax " & target["title"].getStr() & " launcher")
    let face = workButton(target, artwork)
    button["title"] = face["title"]
    if not button.hasKey("visual"): button["visual"] = %*{"showTitle": false}
    button["visual"]["image"] = face["visual"]["image"]
    if face["visual"].hasKey("states"): button["visual"]["states"] = face["visual"]["states"]
    elif button["visual"].hasKey("states"): button["visual"].delete("states")

import
  std/[algorithm, json, tables],
  ./[discord_menu, work_menu]

const
  ObsMenuId* = "obs"
  NavigationMenuIds* = [ObsMenuId, DiscordMenuId, WorkMenuId]
  NavigationTitles = ["OBS", "Discord", WorkMenuTitle]
  NavigationArts = ["obs/menu-obs", "discord/menu-discord", WorkMenuArt]
  HomeTitle = "Home"
  BackTitle = "Back"
  HomeArt* = "navigation/home"
  BackArt* = "obs/back"
  FirstActionKey* = 5
  LastDeckKey = 15
  StartServerKey* = 15
  StartServerTitle* = "Start WoW Server"
  StartServerArt* = "work/wow-server"
  StartServerCommand* = "cd /home/monofuel/src/wow-coworld && " &
    "nix develop /home/monofuel/src/wow-coworld/wow-shadow-army --command " &
    "bash /home/monofuel/src/wow-coworld/tools/private_realm.sh start"

proc navigationArtworkNames*(): seq[string] =
  ## Return every artwork name the navigation prefix and the Start WoW Server key use.
  @[HomeArt, BackArt] & @NavigationArts & @[StartServerArt]

proc startServerAction*(): JsonNode =
  ## Return the exact command action of the verified private realm Start key.
  %*{"kind": "command", "command": StartServerCommand}

proc requireStartTarget(target: JsonNode) =
  ## Refuse a Start WoW Server seed whose title, command, or artwork differs from the verified one.
  if target.isNil or target{"title"}.getStr() != StartServerTitle or
      target{"action"} != startServerAction() or target{"art"}.getStr() != StartServerArt:
    raise newException(ValueError, "The targets file has no verified " & StartServerTitle & " entry.")

proc startServerTarget*(targets: JsonNode): JsonNode =
  ## Return the seed target for the Start WoW Server key, refusing any other command.
  for target in targets:
    if target["title"].getStr() == StartServerTitle: result = target
  requireStartTarget(result)

proc menuLink(menu: string): JsonNode =
  ## Return the Deck-only action that opens one menu.
  %*{"kind": "menu", "menu": menu, "target": "deck"}

proc navigationFace(key: int, title: string, action: JsonNode, image: string): JsonNode =
  ## Build one canonical navigation key with its purple face and no drawn title.
  %*{"key": key, "title": title, "action": action, "visual": {"image": image, "showTitle": false}}

proc navigationPrefix(rootId: string, isRoot: bool, artwork: Table[string, string]): seq[JsonNode] =
  ## Return keys 1 to 4: Home or Back, then OBS, Discord, and Softmax.
  if isRoot: result.add(navigationFace(1, HomeTitle, menuLink(rootId), artwork[HomeArt]))
  else: result.add(navigationFace(1, BackTitle, %*{"kind": "back"}, artwork[BackArt]))
  for index, menu in NavigationMenuIds:
    result.add(navigationFace(index + 2, NavigationTitles[index], menuLink(menu),
      artwork[NavigationArts[index]]))

proc isNavigation(action, rootId: JsonNode): bool =
  ## Recognize exactly the Back, Home, and Deck-only links the shared prefix replaces.
  result = action == %*{"kind": "back"} or action == menuLink(rootId.getStr())
  for menu in NavigationMenuIds:
    if action == menuLink(menu): result = true

proc isPlaceholder(entry: JsonNode): bool =
  ## Recognize an unassigned placeholder, keeping custom image-only buttons as controls.
  entry{"action"}{"kind"}.getStr() == "none" and
    entry{"visual"}{"image"}.isNil and entry{"visual"}{"states"}.isNil

proc findMenu(config: JsonNode, id: string): JsonNode =
  ## Return a configured menu by id, refusing to proceed when it is missing.
  for menu in config["menus"]:
    if menu["id"].getStr() == id: result = menu
  if result.isNil:
    raise newException(ValueError, "The " & id & " menu is missing; install it before organizing navigation.")

proc startEntry(target: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Build the Start WoW Server key from its verified seed target at its final slot.
  %*{"key": StartServerKey, "title": target["title"].getStr(), "action": target["action"],
    "visual": {"image": artwork[target["art"].getStr()], "showTitle": false}}

proc organizeDeck(menu: JsonNode, rootId: JsonNode, isRoot, isWork: bool,
    artwork: Table[string, string], startTarget: JsonNode) =
  ## Replace one known menu's Deck with the shared prefix followed by its preserved actions.
  ## Actions already clear of keys 1 to 4 keep their keys; otherwise every action is repacked
  ## in key order from key 5, with Softmax's Start key always last at key 15.
  let id = menu["id"].getStr()
  var actions, placeholders, starts: seq[JsonNode]
  for entry in menu["deck"]:
    if isWork and entry{"title"}.getStr() == StartServerTitle and
        entry["action"] != startServerAction():
      raise newException(ValueError, "The existing " & StartServerTitle &
        " key does not use the verified helper; refusing an ambiguous start binding.")
    if isNavigation(entry["action"], rootId): continue
    if entry.isPlaceholder(): placeholders.add(entry)
    elif isWork and entry["action"] == startServerAction(): starts.add(entry)
    else: actions.add(entry)
  if starts.len > 1:
    raise newException(ValueError, "The " & id & " menu has more than one " & StartServerTitle &
      " key; refusing an ambiguous layout.")
  actions.sort(proc (a, b: JsonNode): int = cmp(a["key"].getInt(), b["key"].getInt()))
  var organized = true
  for entry in actions & starts:
    if entry["key"].getInt() < FirstActionKey: organized = false
  if organized:
    if isWork:
      for entry in actions:
        if entry["key"].getInt() == StartServerKey:
          raise newException(ValueError, "The " & id & " menu Deck key " & $StartServerKey &
            " already has a different action; refusing to place " & StartServerTitle & ".")
      if starts.len == 0: starts.add(startEntry(startTarget, artwork))
      starts[0]["key"] = %StartServerKey
  else:
    let lastKey = if isWork: StartServerKey - 1 else: LastDeckKey
    if actions.len > lastKey - FirstActionKey + 1:
      raise newException(ValueError, "The " & id & " menu has " & $actions.len &
        " actions, more than fit after the navigation keys; refusing to drop any.")
    for index, entry in actions: entry["key"] = %(FirstActionKey + index)
    if isWork:
      if starts.len == 0: starts.add(startEntry(startTarget, artwork))
      starts[0]["key"] = %StartServerKey
  var deck = navigationPrefix(rootId.getStr(), isRoot, artwork) & actions & starts
  var used: seq[int]
  for entry in deck: used.add(entry["key"].getInt())
  for entry in placeholders:
    if entry["key"].getInt() notin used: deck.add(entry)
  deck.sort(proc (a, b: JsonNode): int = cmp(a["key"].getInt(), b["key"].getInt()))
  menu["deck"] = %deck

proc migrateNavigation*(source: JsonNode, artwork: Table[string, string], startTarget: JsonNode): JsonNode =
  ## Return an owned configuration whose root, OBS, Discord, and Softmax Decks share keys 1 to 4:
  ## Back (Home on root), OBS, Discord, and Softmax, all Deck-only purple faces.
  ## Every other action keeps its whole object; only its key may change. Mixer arrays, other
  ## menus, and links to other menus or devices are untouched. Overflow, a missing menu, an
  ## ambiguous Start key, or a foreign action on key 15 raises before anything is returned.
  ## Reapplying to an organized configuration only refreshes the prefix faces.
  result = parseJson($source)
  let rootId = result["root"]
  requireStartTarget(startTarget)
  discard findMenu(result, rootId.getStr())
  for id in NavigationMenuIds: discard findMenu(result, id)
  for menu in result["menus"]:
    let id = menu["id"].getStr()
    if id == rootId.getStr() or id in NavigationMenuIds:
      organizeDeck(menu, rootId, id == rootId.getStr(), id == WorkMenuId, artwork, startTarget)

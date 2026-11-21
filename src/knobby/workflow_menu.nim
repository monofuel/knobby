import
  std/[algorithm, json, tables],
  ./[button_config, discord_menu, navigation_menu, obs_menu, work_menu]

const
  DeckNavigationMenuId* = "deck-navigation"
  DeckNavigationTitle = "Menu"
  MenuTitle = "Menu"
  HomeTitle = "Home"
  MenuArt* = "workflow/menu"
  MenuOpenArt* = "workflow/menu-open"
  MenuHomeArt = "workflow/menu-home"
  LinkTargets = [ObsMenuId, DiscordMenuId, WorkMenuId]
  LinkTitles = ["OBS Controls", "Discord Controls", "Softmax"]
  LinkArts = ["workflow/menu-obs", "workflow/menu-discord", "workflow/menu-work"]
  RootLinkKeys = [2, 3, 4]
  FirstFreeRootKey = 6
  NavigationLinkKeys = RootLinkKeys
  HomeKey = 1
  MenuKey = MenuToggleKey
  SpareKeys = 6..DeckKeyCount
  OpenObsTitle = "Open OBS"
  OpenObsArt = "workflow/open-obs"
  OpenObsKey = 2
  PreservedObsOperations = ["recordToggle", "pauseToggle", "micToggle"]
  PreservedObsKeys = [3, 4, 9]
  SetupOperations = ["selectMinecraft", "selectWow", "selectFirefox"]
  SetupTitles = ["Minecraft Setup", "WoW Setup", "Firefox Setup"]
  SetupArts = ["workflow/setup-minecraft", "workflow/setup-wow", "workflow/setup-firefox"]
  SetupKeys = [6, 7, 8]
  ResizeOperations = ["minecraft1080", "wow1080", "firefox1080"]
  ResizeTitles = ["Minecraft 1080p", "WoW 1080p", "Firefox 1080p"]
  ResizeArts = ["obs/setup-minecraft-1080", "obs/setup-wow-1080", "obs/setup-firefox-1080"]
  ResizeKeys = [11, 12, 13]
  GeneratedObsOperations = @["open"] & @SetupOperations & @ResizeOperations
  ObsExtraKeys = [10, 14, 15]
  DiscordControlKinds = ["microphones", "discord", "discordDeafen", "openDiscord",
    "discordAcceptVoice", "discordAcceptVideo"]
  DiscordControlKeys = [2, 3, 4, 8, 6, 7]
  DiscordLinks = [(14, WorkMenuId), (15, ObsMenuId)]
  DiscordExtraKeys = [9, 10, 11, 12, 13]
  WorkActionKeys = [2, 3, 4, 6, 7, 8, 9, 10, 11, 12]
  WorkOpenDiscordKey = 13
  WorkLinks = [(14, DiscordMenuId), (15, ObsMenuId)]
  OpenDiscordDefaultTitle = "Discord"
  OpenDiscordTitle = "Open Discord"

proc deckMenuAction*(): JsonNode =
  ## Return the Deck-only action that opens and closes the shared navigation drawer.
  %*{"kind": "deckMenu", "menu": DeckNavigationMenuId}

proc deckLink(menu: string): JsonNode =
  ## Return the Deck-only action that opens one menu.
  %*{"kind": "menu", "menu": menu, "target": "deck"}

proc obsAction(operation: string): JsonNode =
  ## Return the action that runs one OBS operation.
  %*{"kind": "obs", "operation": operation}

proc workflowArtworkNames*(): seq[string] =
  ## Return every artwork name the workflow layout can place, in first-use order.
  result = @[MenuArt, MenuOpenArt, MenuHomeArt] & @LinkArts &
    @[OpenObsArt, OpenObsArt & "-running", OpenObsArt & "-unavailable"]
  for art in SetupArts: result.add([art, art & "-active", art & "-unavailable"])
  for art in ResizeArts: result.add([art, art & "-needed", art & "-unavailable"])

proc face(key: int, title: string, action: JsonNode, image: string,
    artwork: Table[string, string], states: openArray[(string, string)] = []): JsonNode =
  ## Build one generated Deck key whose artwork carries its label.
  result = %*{"key": key, "title": title, "action": action,
    "visual": {"image": artwork[image], "showTitle": false}}
  if states.len > 0:
    result["visual"]["states"] = newJObject()
    for (state, name) in states: result["visual"]["states"][state] = %artwork[name]

proc menuFace(artwork: Table[string, string]): JsonNode =
  ## Build the closed Menu key every normal Deck page shows on key 5.
  face(MenuKey, MenuTitle, deckMenuAction(), MenuArt, artwork)

proc homeLinkFace(rootId: string, artwork: Table[string, string]): JsonNode =
  ## Build the Deck-only Home link every normal Deck page and the drawer show on key 1.
  face(HomeKey, HomeTitle, deckLink(rootId), MenuHomeArt, artwork)

proc contextFaces(rootId: string, artwork: Table[string, string]): seq[JsonNode] =
  ## Build a normal page's Home key 1 and closed Menu key 5.
  @[homeLinkFace(rootId, artwork), menuFace(artwork)]

proc homeFace(artwork: Table[string, string]): JsonNode =
  ## Mark the already-open Home page without another navigation layer or an action.
  face(1, HomeTitle, %*{"kind": "none"}, MenuHomeArt, artwork)

proc linkFace(key: int, menu: string, artwork: Table[string, string]): JsonNode =
  ## Build a labeled Deck-only link to the OBS, Discord, or Softmax menu.
  let index = LinkTargets.find(menu)
  face(key, LinkTitles[index], deckLink(menu), LinkArts[index], artwork)

proc obsFaces(artwork: Table[string, string]): seq[JsonNode] =
  ## Build the generated OBS keys: Open OBS, the three setups, and the three 1080p resizes.
  result.add(face(OpenObsKey, OpenObsTitle, obsAction("open"), OpenObsArt, artwork,
    [("running", OpenObsArt & "-running"), ("unavailable", OpenObsArt & "-unavailable")]))
  for index, operation in SetupOperations:
    let art = SetupArts[index]
    result.add(face(SetupKeys[index], SetupTitles[index], obsAction(operation), art, artwork,
      [("active", art & "-active"), ("blocked", art & "-unavailable"),
        ("unavailable", art & "-unavailable")]))
  for index, operation in ResizeOperations:
    let art = ResizeArts[index]
    result.add(face(ResizeKeys[index], ResizeTitles[index], obsAction(operation), art & "-needed",
      artwork, [("unavailable", art & "-unavailable"), ("running", art & "-needed"), ("ready", art)]))

proc linkFaces(links: openArray[(int, string)], artwork: Table[string, string]): seq[JsonNode] =
  ## Build the context links one menu shows at fixed keys.
  for (key, menu) in links: result.add(linkFace(key, menu, artwork))

proc rootLinkFaces(artwork: Table[string, string]): seq[JsonNode] =
  ## Build the root page's OBS, Discord, and Softmax links.
  for index, key in RootLinkKeys: result.add(linkFace(key, LinkTargets[index], artwork))

proc navigationFaces(rootId: string, artwork: Table[string, string]): seq[JsonNode] =
  ## Build Home on key 1, the same three workflow positions as Home, and the open Menu on key 5.
  result.add(homeLinkFace(rootId, artwork))
  for index, key in NavigationLinkKeys: result.add(linkFace(key, LinkTargets[index], artwork))
  result.add(face(MenuKey, MenuTitle, deckMenuAction(), MenuOpenArt, artwork))

proc isNavigation(action: JsonNode, rootId: string): bool =
  ## Recognize Back, Home, drawer, and Deck-only workflow links that layouts regenerate.
  result = action{"kind"}.getStr() in ["back", "home", "deckMenu"]
  for menu in [rootId, ObsMenuId, DiscordMenuId, WorkMenuId, ObsSetupsMenuId]:
    if action == deckLink(menu): result = true

proc isPlaceholder(entry: JsonNode): bool =
  ## Recognize an unassigned placeholder, keeping custom image-only buttons as controls.
  entry{"action"}{"kind"}.getStr() == "none" and
    entry{"visual"}{"image"}.isNil and entry{"visual"}{"states"}.isNil

proc findMenu(config: JsonNode, id: string): JsonNode =
  ## Return a configured menu by id, or nil when it is absent.
  for menu in config["menus"]:
    if menu["id"].getStr() == id: result = menu

proc requireMenu(config: JsonNode, id: string): JsonNode =
  ## Return a configured menu by id, refusing to invent a missing one.
  result = findMenu(config, id)
  if result.isNil:
    raise newException(ValueError, "The " & id &
      " menu is missing; install it before applying the workflow layout.")

proc deckEntry(menu: JsonNode, key: int): JsonNode =
  ## Return an explicit Deck entry, or nil when the key is unassigned.
  for entry in menu["deck"]:
    if entry["key"].getInt() == key: result = entry

proc byKey(a, b: JsonNode): int =
  ## Order entries by key.
  cmp(a["key"].getInt(), b["key"].getInt())

proc sortedDeck(menu: JsonNode): seq[JsonNode] =
  ## Return a menu's Deck entries in key order.
  result = menu["deck"].elems
  result.sort(byKey)

proc copyEntry(entry: JsonNode, key: int): JsonNode =
  ## Return an owned copy of a whole entry moved to another key.
  result = parseJson($entry)
  result["key"] = %key

proc setEntry(menu: JsonNode, entry: JsonNode) =
  ## Store one Deck entry on its key, replacing any occupant, and keep the Deck in key order.
  var deck: seq[JsonNode]
  for current in menu["deck"]:
    if current["key"] != entry["key"]: deck.add(current)
  deck.add(entry)
  deck.sort(byKey)
  menu["deck"] = %deck

proc placeEntries(entries: openArray[JsonNode], keys: openArray[int], menuId: string): seq[JsonNode] =
  ## Copy custom entries onto free keys in order, refusing to drop any that do not fit.
  if entries.len > keys.len:
    raise newException(ValueError, "The " & menuId & " menu has " & $entries.len &
      " custom buttons but only " & $keys.len & " free keys; refusing to drop any.")
  for index, entry in entries: result.add(entry.copyEntry(keys[index]))

proc finishDeck(menu: JsonNode, entries: seq[JsonNode]) =
  ## Store a rebuilt Deck in key order, keeping the menu's placeholders on keys left unused.
  var
    deck = entries
    used: seq[int]
  for entry in deck: used.add(entry["key"].getInt())
  for entry in menu["deck"]:
    if entry.isPlaceholder() and entry["key"].getInt() notin used: deck.add(entry)
  deck.sort(byKey)
  menu["deck"] = %deck

proc hasMenuAt(menu: JsonNode, key: int): bool =
  ## Report whether a Deck key holds the shared drawer's Menu action.
  let entry = menu.deckEntry(key)
  not entry.isNil and entry["action"] == deckMenuAction()

proc isCompleted(menu: JsonNode): bool =
  ## Report whether a menu already has a Menu key on 1 (legacy) or 5, so its edited layout is kept.
  menu.hasMenuAt(LegacyMenuKey) or menu.hasMenuAt(MenuKey)

proc isFree(menu: JsonNode, key: int): bool =
  ## Report whether a Deck key is unassigned or only a placeholder.
  let entry = menu.deckEntry(key)
  entry.isNil or entry.isPlaceholder()

proc removeKey(menu: JsonNode, key: int) =
  ## Remove whatever entry a Deck key holds.
  var kept: seq[JsonNode]
  for entry in menu["deck"]:
    if entry["key"].getInt() != key: kept.add(entry)
  menu["deck"] = %kept

proc vacateMenuKey(menu: JsonNode, preferred: int) =
  ## Move a whole custom key 5 entry to its preferred key, or else the first free spare key 6 to 15,
  ## so key 5 can hold Menu. A placeholder on key 5 is dropped; a missing free key refuses rather
  ## than losing an action.
  let current = menu.deckEntry(MenuKey)
  if current.isNil or current.isPlaceholder():
    menu.removeKey(MenuKey)
    return
  var destination = 0
  if preferred > 0:
    if not menu.isFree(preferred):
      raise newException(ValueError, "Deck key " & $preferred & " in " & menu["id"].getStr() &
        " holds a custom control, so key 5 cannot move there; refusing to replace it.")
    destination = preferred
  else:
    for key in SpareKeys:
      if destination == 0 and menu.isFree(key): destination = key
    if destination == 0:
      raise newException(ValueError, "The " & menu["id"].getStr() & " menu has no free key from " &
        $SpareKeys.a & " to " & $SpareKeys.b & " for its key 5 control; refusing to drop it.")
  menu.removeKey(MenuKey)
  menu.setEntry(current.copyEntry(destination))

proc moveMenuRight(menu: JsonNode, rootId: string, artwork: Table[string, string], preferred = 0) =
  ## Upgrade a normal page to Home on key 1 and Menu on key 5. A legacy key 1 Menu entry moves whole
  ## to key 5, keeping its edited face; key 5's own control moves first. Pages already upgraded keep
  ## their edited keys.
  if menu.hasMenuAt(MenuKey): return
  let legacy = if menu.hasMenuAt(LegacyMenuKey): menu.deckEntry(LegacyMenuKey) else: nil
  let first = menu.deckEntry(LegacyMenuKey)
  if legacy.isNil and not first.isNil and not isNavigation(first["action"], rootId):
    raise newException(ValueError, "Deck key 1 of the " & menu["id"].getStr() &
      " menu holds a custom action; refusing to replace it with Home.")
  menu.vacateMenuKey(preferred)
  menu.setEntry(homeLinkFace(rootId, artwork))
  menu.setEntry(if legacy.isNil: menuFace(artwork) else: legacy.copyEntry(MenuKey))

proc isHomePage(menu: JsonNode): bool =
  ## Recognize the non-action Home indicator, preserving its edited face on later runs.
  let first = menu.deckEntry(1)
  if first.isNil or first["action"] != %*{"kind": "none"}: return false
  for target in LinkTargets:
    var found = false
    for entry in menu["deck"]:
      if entry["action"] == deckLink(target): found = true
    if not found: return false
  result = true

proc fillMissing(menu: JsonNode, faces: seq[JsonNode]) =
  ## Add any generated key a completed menu lacks at its standard key, leaving edited keys alone.
  for wanted in faces:
    var present = false
    for entry in menu["deck"]:
      if entry["action"] == wanted["action"]: present = true
    let current = menu.deckEntry(wanted["key"].getInt())
    if not present:
      if not current.isNil and not current.isPlaceholder():
        raise newException(ValueError, "The " & menu["id"].getStr() & " menu has no " &
          wanted["title"].getStr() & " key and Deck key " & $wanted["key"].getInt() &
          " holds another action; refusing to replace it.")
      menu.setEntry(wanted)

proc organizeRoot(menu: JsonNode, rootId: string, artwork: Table[string, string]) =
  ## Give Home its indicator and three links, moving custom keys 1 to 4 onto free keys.
  var
    kept, displaced: seq[JsonNode]
    freeKeys: seq[int]
  for entry in sortedDeck(menu):
    if isNavigation(entry["action"], rootId) or entry.isPlaceholder(): continue
    if entry["key"].getInt() >= FirstFreeRootKey: kept.add(entry)
    else: displaced.add(entry)
  for key in FirstFreeRootKey..DeckKeyCount:
    let entry = menu.deckEntry(key)
    if entry.isNil or entry.isPlaceholder() or isNavigation(entry["action"], rootId): freeKeys.add(key)
  finishDeck(menu, @[homeFace(artwork)] & rootLinkFaces(artwork) & kept &
    placeEntries(displaced, freeKeys, rootId))

proc positionLinks(menu: JsonNode, links: openArray[(int, string)]) =
  ## Move whole contextual links together, refusing occupied destinations before replacing anything.
  var
    moved: seq[JsonNode]
    actions: seq[JsonNode]
  for (key, target) in links:
    let action = deckLink(target)
    actions.add(action)
    var matching: JsonNode
    for entry in menu["deck"]:
      if entry["action"] == action:
        if not matching.isNil:
          raise newException(ValueError, "Duplicate contextual link to " & target & ".")
        matching = entry
    if not matching.isNil: moved.add(matching.copyEntry(key))
  for wanted in moved:
    let current = menu.deckEntry(wanted["key"].getInt())
    if not current.isNil and not current.isPlaceholder() and current["action"] notin actions:
      raise newException(ValueError, "Deck key " & $wanted["key"].getInt() & " in " &
        menu["id"].getStr() & " holds a custom control; refusing to replace it.")
  var kept: seq[JsonNode]
  for entry in menu["deck"]:
    if entry["action"] notin actions: kept.add(entry)
  menu["deck"] = %kept
  for entry in moved: menu.setEntry(entry)

proc organizeObs(obs, setups: JsonNode, rootId: string, artwork: Table[string, string]) =
  ## Flatten OBS Setups into OBS: generated open, setup, and resize keys, whole Record, Pause,
  ## and Commentary entries, then custom extras from both menus on the remaining keys.
  var
    preserved = initTable[string, JsonNode]()
    extras: seq[JsonNode]
    sources = @[obs]
  if not setups.isNil: sources.add(setups)
  for source in sources:
    for entry in sortedDeck(source):
      let action = entry["action"]
      if isNavigation(action, rootId) or entry.isPlaceholder(): continue
      let operation = if action["kind"].getStr() == "obs": action["operation"].getStr() else: ""
      if operation in PreservedObsOperations:
        if preserved.hasKey(operation):
          raise newException(ValueError, "OBS has more than one " & operation &
            " key; refusing an ambiguous layout.")
        preserved[operation] = entry
      elif operation notin GeneratedObsOperations:
        extras.add(entry)
  var entries = contextFaces(rootId, artwork) & obsFaces(artwork)
  for index, operation in PreservedObsOperations:
    if not preserved.hasKey(operation):
      raise newException(ValueError, "The OBS menu has no " & operation &
        " key; install the OBS menu before applying the workflow layout.")
    entries.add(preserved[operation].copyEntry(PreservedObsKeys[index]))
  finishDeck(obs, entries & placeEntries(extras, ObsExtraKeys, ObsMenuId))

proc organizeDiscord(menu: JsonNode, rootId: string, artwork: Table[string, string]) =
  ## Place the whole Discord controls on keys 2 to 4 and 6 to 8, then the Softmax and OBS links
  ## and custom extras.
  var
    controls = initTable[string, JsonNode]()
    extras: seq[JsonNode]
  for entry in sortedDeck(menu):
    if isNavigation(entry["action"], rootId) or entry.isPlaceholder(): continue
    let kind = entry["action"]["kind"].getStr()
    if kind in DiscordControlKinds:
      if controls.hasKey(kind):
        raise newException(ValueError, "Discord has more than one " & kind &
          " key; refusing an ambiguous layout.")
      controls[kind] = entry
    else:
      extras.add(entry)
  var entries = contextFaces(rootId, artwork)
  for index, kind in DiscordControlKinds:
    if not controls.hasKey(kind):
      raise newException(ValueError, "The Discord menu has no " & kind &
        " key; install the Discord menu before applying the workflow layout.")
    entries.add(controls[kind].copyEntry(DiscordControlKeys[index]))
  finishDeck(menu, entries & linkFaces(DiscordLinks, artwork) &
    placeEntries(extras, DiscordExtraKeys, DiscordMenuId))

proc organizeWork(menu: JsonNode, rootId: string, artwork: Table[string, string]) =
  ## Pack the whole Softmax launchers on keys 2 to 4 and 6 to 12 in their existing order, Open
  ## Discord on key 13, then the Discord and OBS links; extra launchers take key 13 when it is free.
  var
    actions: seq[JsonNode]
    openDiscord: JsonNode
  for entry in sortedDeck(menu):
    if isNavigation(entry["action"], rootId) or entry.isPlaceholder(): continue
    if entry["action"] == %*{"kind": "openDiscord"} and openDiscord.isNil: openDiscord = entry
    else: actions.add(entry)
  let packed = min(actions.len, WorkActionKeys.len)
  var entries = contextFaces(rootId, artwork)
  for index in 0..<packed: entries.add(actions[index].copyEntry(WorkActionKeys[index]))
  entries.add(linkFaces(WorkLinks, artwork))
  if openDiscord.isNil:
    entries.add(placeEntries(actions[packed..^1], [WorkOpenDiscordKey], WorkMenuId))
  else:
    entries.add(placeEntries(actions[packed..^1], [], WorkMenuId))
    entries.add(openDiscord.copyEntry(WorkOpenDiscordKey))
  for entry in entries:
    if entry["action"] == %*{"kind": "openDiscord"} and
        entry{"title"}.getStr() == OpenDiscordDefaultTitle:
      entry["title"] = %OpenDiscordTitle
  finishDeck(menu, entries)

proc clearHomeMenuKey(root: JsonNode, rootId: string) =
  ## Keep Home's key 5 blank: drop navigation there and move a custom control to a free spare key.
  let current = root.deckEntry(MenuKey)
  if not current.isNil and isNavigation(current["action"], rootId): root.removeKey(MenuKey)
  root.vacateMenuKey(0)

proc installNavigationMenu(config: JsonNode, rootId: string, artwork: Table[string, string]) =
  ## Add or complete the drawer menu with Home on key 1, the workflow links on keys 2 to 4, and the
  ## open Menu on key 5. A legacy drawer's whole entries move to those keys, keeping edited faces;
  ## any other action on keys 1 to 5 refuses.
  var menu = findMenu(config, DeckNavigationMenuId)
  if menu.isNil:
    menu = %*{"id": DeckNavigationMenuId, "title": DeckNavigationTitle, "mixer": [], "deck": []}
    config["menus"].add(menu)
  if menu.hasMenuAt(LegacyMenuKey):
    let wanted = navigationFaces(rootId, artwork)
    var moved: seq[JsonNode]
    for key in 1..DrawerKeyCount:
      let current = menu.deckEntry(key)
      if current.isNil or current.isPlaceholder(): continue
      var destination = 0
      for face in wanted:
        if face["action"] == current["action"]: destination = face["key"].getInt()
      if destination == 0:
        raise newException(ValueError, "The " & DeckNavigationMenuId & " menu key " & $key &
          " holds another action; refusing to replace it.")
      for previous in moved:
        if previous["key"].getInt() == destination:
          raise newException(ValueError, "Duplicate navigation destination; refusing to discard a face.")
      moved.add(current.copyEntry(destination))
    for key in 1..DrawerKeyCount: menu.removeKey(key)
    for entry in moved: menu.setEntry(entry)
  for wanted in navigationFaces(rootId, artwork):
    let current = menu.deckEntry(wanted["key"].getInt())
    if current.isNil or current.isPlaceholder():
      menu.setEntry(wanted)
    elif current["action"] != wanted["action"]:
      raise newException(ValueError, "The " & DeckNavigationMenuId & " menu key " &
        $wanted["key"].getInt() & " holds another action; refusing to replace it.")

proc moveSetupMixer(obs, setups: JsonNode) =
  ## Move OBS Setups mixer bindings into OBS, refusing a key both menus bind differently.
  if setups{"mixer"}.isNil or setups["mixer"].len == 0: return
  if obs{"mixer"}.isNil: obs["mixer"] = newJArray()
  var mixer = obs["mixer"].elems
  for entry in setups["mixer"]:
    var clash = false
    for current in obs["mixer"]:
      if current["key"] == entry["key"]:
        if current != entry:
          raise newException(ValueError, "OBS and OBS Setups bind mixer key " &
            $entry["key"].getInt() & " differently; refusing to drop either.")
        clash = true
    if not clash: mixer.add(parseJson($entry))
  mixer.sort(byKey)
  obs["mixer"] = %mixer

proc retargetSetupLinks(config: JsonNode) =
  ## Point every remaining OBS Setups link at OBS, keeping its title, target, and artwork.
  for menu in config["menus"]:
    for device in ["mixer", "deck"]:
      if menu.hasKey(device):
        for entry in menu[device]:
          if entry["action"]{"kind"}.getStr() == "menu" and
              entry["action"]{"menu"}.getStr() == ObsSetupsMenuId:
            entry["action"]["menu"] = %ObsMenuId

proc migrateWorkflowMenus*(source: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Return an owned configuration with the Menu drawer layout and a flattened OBS page.
  ## Home has a non-action indicator, links on keys 2 to 4, and a blank key 5. Other Deck pages
  ## show a Home link on key 1 and Menu on key 5, whose drawer shows the links on keys 2 to 4.
  ## A legacy key 1 Menu moves whole to key 5, and key 5's control moves to its standard key
  ## (Commentary 9, Discord's Open Discord 8, Softmax's Open Discord 13) or a free spare key 6 to 15
  ## on other pages. Context links occupy 14–15.
  ## OBS Setups is merged into OBS and removed, with remaining links retargeted to OBS.
  ## Whole Record, Pause, Commentary, Discord, and Softmax entries are moved, never rebuilt, and
  ## every mixer binding and unrelated menu is kept. A missing menu or control, an ambiguous
  ## duplicate, overflowing custom keys, or a foreign key 1 raises before anything is returned.
  ## Once Home is aligned, later runs preserve edited layouts and only restore missing links.
  result = parseJson($source)
  let
    rootId = result["root"].getStr()
    root = requireMenu(result, rootId)
    obs = requireMenu(result, ObsMenuId)
    discord = requireMenu(result, DiscordMenuId)
    work = requireMenu(result, WorkMenuId)
    setups = findMenu(result, ObsSetupsMenuId)
    aligned = root.isHomePage()
  if rootId in [ObsSetupsMenuId, DeckNavigationMenuId]:
    raise newException(ValueError, "The root menu cannot be " & rootId & ".")
  if root.isCompleted():
    root.clearHomeMenuKey(rootId)
    root.fillMissing(rootLinkFaces(artwork))
    root.setEntry(homeFace(artwork))
  elif root.isHomePage():
    root.clearHomeMenuKey(rootId)
    root.fillMissing(rootLinkFaces(artwork))
  else:
    organizeRoot(root, rootId, artwork)
    root.clearHomeMenuKey(rootId)
  if setups.isNil and obs.isCompleted():
    obs.moveMenuRight(rootId, artwork, PreservedObsKeys[^1])
    obs.fillMissing(obsFaces(artwork))
  else: organizeObs(obs, setups, rootId, artwork)
  if discord.isCompleted():
    if not aligned: discord.positionLinks(DiscordLinks)
    discord.moveMenuRight(rootId, artwork, DiscordControlKeys[DiscordControlKinds.find("openDiscord")])
    discord.fillMissing(linkFaces(DiscordLinks, artwork))
  else: organizeDiscord(discord, rootId, artwork)
  if work.isCompleted():
    if not aligned: work.positionLinks(WorkLinks)
    work.moveMenuRight(rootId, artwork, WorkOpenDiscordKey)
    work.fillMissing(linkFaces(WorkLinks, artwork))
  else: organizeWork(work, rootId, artwork)
  for menu in result["menus"]:
    if menu["id"].getStr() notin [rootId, ObsMenuId, DiscordMenuId, WorkMenuId,
        ObsSetupsMenuId, DeckNavigationMenuId]:
      menu.moveMenuRight(rootId, artwork)
  installNavigationMenu(result, rootId, artwork)
  if not setups.isNil:
    moveSetupMixer(obs, setups)
    var menus: seq[JsonNode]
    for menu in result["menus"]:
      if menu["id"].getStr() != ObsSetupsMenuId: menus.add(menu)
    result["menus"] = %menus
  retargetSetupLinks(result)

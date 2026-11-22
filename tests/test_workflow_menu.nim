import
  std/[json, strutils, tables, unittest],
  knobby/[button_config, obs_menu, workflow_menu]

const
  StartCommand = "cd /home/monofuel/src/wow-coworld && " &
    "nix develop /home/monofuel/src/wow-coworld/wow-shadow-army --command " &
    "bash /home/monofuel/src/wow-coworld/tools/private_realm.sh start"
  WorkCommands = [("Prism", "\"$HOME/.local/bin/knobby-obs\" prism"),
    ("WoW Vanilla", "make -C /home/monofuel/src/wow-coworld/wow-shadow-army play-classic"),
    ("WoW Nim", "cd /home/monofuel/src/wow-coworld/wow-shadow-army && nix develop --command make play")]
  WorkLinks = [("Slack", "slack -s"), ("Autoresearch", "xdg-open http://127.0.0.1:8103/"),
    ("Fast-XP Prod", "xdg-open https://fast-xp-k8s-prod.tail0f4a29.ts.net/"),
    ("Fast-XP Staging", "xdg-open https://fast-xp-k8s-staging.tail0f4a29.ts.net/"),
    ("Next Games", "xdg-open https://fast-xp-k8s-staging.tail0f4a29.ts.net/next/"),
    ("WoW Dashboard", "xdg-open http://127.0.0.1:7777/"), ("Start WoW Server", StartCommand)]
  MenuAction = """{"kind": "deckMenu", "menu": "deck-navigation"}"""

proc artwork(): Table[string, string] =
  ## Map every layout artwork name to a distinct managed path.
  for name in workflowArtworkNames(): result[name] = "assets/new-" & name.replace("/", "-") & ".png"

proc link(menu: string): JsonNode =
  ## Return a Deck-only menu link.
  %*{"kind": "menu", "menu": menu, "target": "deck"}

proc obsOp(operation: string): JsonNode =
  ## Return an OBS operation action.
  %*{"kind": "obs", "operation": operation}

proc button(key: int, title: string, action: JsonNode, states: openArray[string] = []): JsonNode =
  ## Build a Deck entry with distinct legacy artwork and optional state artwork.
  result = %*{"key": key, "title": title, "action": action,
    "visual": {"image": "assets/old-" & $key & "-" & title.replace(" ", "-") & ".png", "showTitle": false}}
  if states.len > 0:
    result["visual"]["states"] = newJObject()
    for state in states: result["visual"]["states"][state] = %("assets/old-" & title.replace(" ", "-") & "-" & state & ".png")

proc prefix(): seq[JsonNode] =
  ## Return the retired shared Home, OBS, Discord, and Softmax prefix.
  @[button(1, "Home", link("root")), button(2, "OBS", link("obs")),
    button(3, "Discord", link("discord")), button(4, "Softmax", link("work"))]

proc liveLikeConfig(): JsonNode =
  ## Build the pre-workflow layout: shared prefix on every page, OBS Setups beside OBS.
  var root = prefix()
  for key in 5..15: root.add(%*{"key": key, "title": $key, "action": {"kind": "none"},
    "visual": {"builtinNumber": key, "showTitle": false}})
  let obs = prefix() & @[
    button(5, "Record", obsOp("recordToggle"), ["recording", "paused", "unavailable"]),
    button(6, "Pause", obsOp("pauseToggle"), ["recording", "paused", "unavailable"]),
    button(7, "Commentary", obsOp("micToggle"), ["muted", "unavailable"]),
    button(8, "Open OBS", obsOp("open"), ["running", "unavailable"]),
    button(9, "Minecraft 1080p", obsOp("minecraft1080"), ["running", "ready", "unavailable"]),
    button(10, "OBS Setups", link("obs-setups"))]
  let discord = prefix() & @[
    button(5, "System Mic", %*{"kind": "microphones"}, ["muted", "mixed", "unavailable"]),
    button(6, "Discord Mic", %*{"kind": "discord"}, ["muted", "deafened", "unavailable"]),
    button(7, "Deafen", %*{"kind": "discordDeafen"}, ["deafened", "unavailable"]),
    button(8, "Open Discord", %*{"kind": "openDiscord"}, ["running", "ready", "unavailable"]),
    button(9, "Answer voice", %*{"kind": "discordAcceptVoice"}, ["ready", "unavailable"]),
    button(10, "Answer video", %*{"kind": "discordAcceptVideo"}, ["ready", "unavailable"])]
  var work = prefix()
  for index, (title, command) in WorkCommands:
    work.add(button(5 + index, title, %*{"kind": "command", "command": command}))
  work.add(button(8, "Discord", %*{"kind": "openDiscord"}))
  for index, (title, command) in WorkLinks:
    work.add(button(9 + index, title, %*{"kind": "command", "command": command}))
  let setups = prefix() & @[
    button(5, "Minecraft AI Demos", obsOp("selectMinecraft"), ["active", "blocked", "unavailable"]),
    button(6, "Firefox Demos", obsOp("selectFirefox"), ["active", "blocked", "unavailable"]),
    button(7, "WoW Demos", obsOp("selectWow"), ["active", "blocked", "unavailable"]),
    button(10, "Minecraft 1080p", obsOp("minecraft1080"), ["running", "ready", "unavailable"]),
    button(11, "Firefox demo 1080p", obsOp("firefox1080"), ["running", "ready", "unavailable"]),
    button(12, "WoW 1080p", obsOp("wow1080"), ["running", "ready", "unavailable"])]
  result = %*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Main", "deck": root, "mixer": [
      {"key": 3, "title": "Show buttons", "action": {"kind": "mixerOverlay"}},
      {"key": 9, "title": "Claude", "action": {"kind": "claude"}},
      {"key": 11, "title": "Microphones", "action": {"kind": "microphones"}}]},
    {"id": "obs", "title": "OBS", "mixer": [], "deck": obs},
    {"id": "discord", "title": "Discord", "mixer": [], "deck": discord},
    {"id": "work", "title": "Softmax", "mixer": [], "deck": work},
    {"id": "obs-setups", "title": "OBS Setups", "mixer": [], "deck": setups}]}

proc menu(config: JsonNode, id: string): JsonNode =
  ## Return a stored menu by id, or nil.
  for candidate in config["menus"]:
    if candidate["id"].getStr() == id: result = candidate

proc entry(config: JsonNode, id: string, key: int): JsonNode =
  ## Return an explicit stored Deck entry, or nil.
  for candidate in menu(config, id)["deck"]:
    if candidate["key"].getInt() == key: result = candidate

proc layout(config: JsonNode, id: string): seq[(int, string, string)] =
  ## Summarize a menu's Deck as key, title, and action.
  for candidate in menu(config, id)["deck"]:
    result.add((candidate["key"].getInt(), candidate["title"].getStr(), $candidate["action"]))

proc keyed(entry: JsonNode, key: int): JsonNode =
  ## Return a copy of an entry moved to a key.
  result = parseJson($entry)
  result["key"] = %key

proc sameEntry(config: JsonNode, id: string, key: int, original: JsonNode): bool =
  ## Report whether a stored entry is the original whole entry moved to the key.
  entry(config, id, key) == original.keyed(key)

proc oldEntry(id: string, key: int): JsonNode =
  ## Return one entry from a fresh live-like source.
  entry(liveLikeConfig(), id, key)

proc relocate(config: JsonNode, id: string, moves: openArray[(int, int)]) =
  ## Construct an earlier known layout without losing entries during overlapping moves.
  var moved, kept: seq[JsonNode]
  for (source, target) in moves: moved.add(entry(config, id, source).keyed(target))
  for current in menu(config, id)["deck"]:
    var moving = false
    for (source, target) in moves:
      if current["key"].getInt() in [source, target]: moving = true
    if not moving: kept.add(current)
  menu(config, id)["deck"] = %(kept & moved)

proc leftMenuConfig(): JsonNode =
  ## Recreate the installed Home-left/Menu-left layout with the original key 5 controls.
  result = migrateWorkflowMenus(liveLikeConfig(), artwork())
  for (id, oldKey) in [("obs", 9), ("discord", 8), ("work", 13)]:
    relocate(result, id, [(5, 1), (oldKey, 5)])
  relocate(result, DeckNavigationMenuId, [(1, 5), (5, 1)])

suite "Workflow menu layout":
  test "upgrades the installed offset drawer and moves whole crosslinks to the bottom-right pair":
    let expected = migrateWorkflowMenus(liveLikeConfig(), artwork())
    let previous = leftMenuConfig()
    entry(previous, "root", 1)["action"] = parseJson(MenuAction)
    entry(previous, "root", 1)["title"] = %"Menu"
    entry(previous, "root", 1)["visual"]["image"] = %artwork()[MenuArt]
    relocate(previous, DeckNavigationMenuId, [(2, 3), (3, 4), (4, 5), (5, 2)])
    relocate(previous, "discord", [(14, 8), (15, 9)])
    relocate(previous, "work", [(14, 13), (15, 14)])
    let original = $previous
    check migrateWorkflowMenus(previous, artwork()) == expected
    check $previous == original
    let occupied = previous.copy()
    menu(occupied, "discord")["deck"].add(button(14, "Custom", %*{"kind": "command", "command": "custom"}))
    let before = $occupied
    expect ValueError: discard migrateWorkflowMenus(occupied, artwork())
    check $occupied == before

  test "migrates the live layout to the agreed keys and leaves the source untouched":
    let
      source = liveLikeConfig()
      before = $source
      result = migrateWorkflowMenus(source, artwork())
    check $source == before
    check layout(result, "root")[0..3] == @[(1, "Home", $(%*{"kind": "none"})),
      (2, "OBS Controls", $link("obs")), (3, "Discord Controls", $link("discord")),
      (4, "Softmax", $link("work"))]
    check entry(result, "root", 5).isNil
    check entry(result, "root", 6) == entry(source, "root", 6)
    for key in 7..15: check entry(result, "root", key).isNil
    check layout(result, "obs") == @[(1, "Home", $link("root")),
      (2, "Open OBS", $obsOp("open")), (3, "Record", $obsOp("recordToggle")),
      (4, "Pause", $obsOp("pauseToggle")), (5, "Menu", $parseJson(MenuAction)),
      (6, "Minecraft Setup", $obsOp("selectMinecraft")), (7, "WoW Setup", $obsOp("selectWow")),
      (8, "Firefox Setup", $obsOp("selectFirefox")), (9, "Commentary", $obsOp("micToggle")),
      (11, "Minecraft 1080p", $obsOp("minecraft1080")),
      (12, "WoW 1080p", $obsOp("wow1080")), (13, "Firefox 1080p", $obsOp("firefox1080"))]
    var discordTitles, workTitles: seq[string]
    for (key, title, action) in layout(result, "discord"): discordTitles.add(title)
    for (key, title, action) in layout(result, "work"): workTitles.add(title)
    check discordTitles == @["Home", "System Mic", "Discord Mic", "Deafen", "Menu",
      "Answer voice", "Answer video", "Open Discord", "Softmax", "OBS Controls"]
    check workTitles == @["Home", "Prism", "WoW Vanilla", "WoW Nim", "Menu", "Slack",
      "Autoresearch", "Fast-XP Prod", "Fast-XP Staging", "Next Games", "WoW Dashboard",
      "Start WoW Server", "Open Discord", "Discord Controls", "OBS Controls"]
    check entry(result, "discord", 14)["action"] == link("work")
    check entry(result, "discord", 15)["action"] == link("obs")
    check entry(result, "work", 14)["action"] == link("discord")
    check entry(result, "work", 15)["action"] == link("obs")
    check entry(result, "work", 13)["action"] == %*{"kind": "openDiscord"}
    check menu(result, "obs-setups").isNil
    check "obs-setups" notin $result

  test "builds the drawer menu with its open face and four destinations":
    let
      result = migrateWorkflowMenus(liveLikeConfig(), artwork())
      drawer = menu(result, DeckNavigationMenuId)
    check drawer["mixer"].len == 0
    check layout(result, DeckNavigationMenuId) == @[(1, "Home", $link("root")),
      (2, "OBS Controls", $link("obs")), (3, "Discord Controls", $link("discord")),
      (4, "Softmax", $link("work")), (5, "Menu", $parseJson(MenuAction))]
    check entry(result, DeckNavigationMenuId, 5)["visual"]["image"].getStr() ==
      "assets/new-workflow-menu-open.png"
    for id in ["obs", "discord", "work"]:
      check entry(result, id, 1)["action"] == link("root")
      check entry(result, id, 5)["action"] == parseJson(MenuAction)
      check entry(result, id, 5)["visual"]["image"].getStr() == "assets/new-workflow-menu.png"
    check entry(result, "root", 1)["action"] == %*{"kind": "none"}
    for key in 2..4:
      check entry(result, "root", key)["action"] == entry(result, DeckNavigationMenuId, key)["action"]

  test "moves whole state, Discord, and launcher entries unchanged":
    let result = migrateWorkflowMenus(liveLikeConfig(), artwork())
    check sameEntry(result, "obs", 3, oldEntry("obs", 5))
    check sameEntry(result, "obs", 4, oldEntry("obs", 6))
    check sameEntry(result, "obs", 9, oldEntry("obs", 7))
    for offset, key in [2, 3, 4, 8, 6, 7]:
      check sameEntry(result, "discord", key, oldEntry("discord", 5 + offset))
    for offset in 0..10:
      let original = oldEntry("work", 5 + offset)
      if original["action"] == %*{"kind": "openDiscord"}:
        original["title"] = %"Open Discord"
      check sameEntry(result, "work", [2, 3, 4, 13, 6, 7, 8, 9, 10, 11, 12][offset], original)
    check entry(result, "work", 12)["action"]["command"].getStr() == StartCommand
    for id in ["root", "obs", "discord", "work"]:
      check menu(result, id)["mixer"] == menu(liveLikeConfig(), id)["mixer"]

  test "uses clear generated art for open, setup, and resize keys":
    let result = migrateWorkflowMenus(liveLikeConfig(), artwork())
    check entry(result, "obs", 2)["visual"] == %*{"image": "assets/new-workflow-open-obs.png",
      "showTitle": false, "states": {"running": "assets/new-workflow-open-obs-running.png",
        "unavailable": "assets/new-workflow-open-obs-unavailable.png"}}
    check entry(result, "obs", 7)["visual"] == %*{"image": "assets/new-workflow-setup-wow.png",
      "showTitle": false, "states": {"active": "assets/new-workflow-setup-wow-active.png",
        "blocked": "assets/new-workflow-setup-wow-unavailable.png",
        "unavailable": "assets/new-workflow-setup-wow-unavailable.png"}}
    check entry(result, "obs", 11)["visual"] == %*{
      "image": "assets/new-obs-setup-minecraft-1080-needed.png", "showTitle": false,
      "states": {"unavailable": "assets/new-obs-setup-minecraft-1080-unavailable.png",
        "running": "assets/new-obs-setup-minecraft-1080-needed.png",
        "ready": "assets/new-obs-setup-minecraft-1080.png"}}
    var resizes = 0
    for candidate in menu(result, "obs")["deck"]:
      if candidate["action"] == obsOp("minecraft1080"): inc resizes
    check resizes == 1

  test "adds missing WoW and resize keys when OBS Setups is older or absent":
    let source = liveLikeConfig()
    var menus: seq[JsonNode]
    for candidate in source["menus"]:
      if candidate["id"].getStr() != "obs-setups": menus.add(candidate)
    source["menus"] = %menus
    entry(source, "obs", 10)["action"] = %*{"kind": "command", "command": "true"}
    let result = migrateWorkflowMenus(source, artwork())
    for (key, operation) in [(6, "selectMinecraft"), (7, "selectWow"), (8, "selectFirefox"),
        (11, "minecraft1080"), (12, "wow1080"), (13, "firefox1080")]:
      check entry(result, "obs", key)["action"] == obsOp(operation)
    check entry(result, "obs", 10)["action"] == %*{"kind": "command", "command": "true"}

  test "keeps custom extras from both OBS menus and refuses overflow":
    let source = liveLikeConfig()
    menu(source, "obs")["deck"].add(button(11, "Clip", %*{"kind": "command", "command": "clip"}))
    menu(source, "obs-setups")["deck"].add(button(13, "Scene", %*{"kind": "command", "command": "scene"}))
    menu(source, "obs-setups")["mixer"].add(%*{"key": 4, "title": "Setups", "action": link("obs-setups")})
    menu(source, "discord")["deck"].add(button(12, "Ping", %*{"kind": "command", "command": "ping"}))
    let result = migrateWorkflowMenus(source, artwork())
    check sameEntry(result, "obs", 10, entry(source, "obs", 11))
    check sameEntry(result, "obs", 14, entry(source, "obs-setups", 13))
    check sameEntry(result, "discord", 9, entry(source, "discord", 12))
    check menu(result, "obs")["mixer"] == %*[
      {"key": 4, "title": "Setups", "action": {"kind": "menu", "menu": "obs", "target": "deck"}}]
    let crowded = parseJson($source)
    for key in [12, 14, 15]:
      menu(crowded, "obs")["deck"].add(button(key, "Extra " & $key,
        %*{"kind": "command", "command": "echo " & $key}))
    let before = $crowded
    expect ValueError: discard migrateWorkflowMenus(crowded, artwork())
    check $crowded == before

  test "refuses missing menus, missing controls, and ambiguous duplicates":
    let missingWork = liveLikeConfig()
    var menus: seq[JsonNode]
    for candidate in missingWork["menus"]:
      if candidate["id"].getStr() != "work": menus.add(candidate)
    missingWork["menus"] = %menus
    expect ValueError: discard migrateWorkflowMenus(missingWork, artwork())
    let duplicate = liveLikeConfig()
    menu(duplicate, "obs-setups")["deck"].add(button(14, "Record", obsOp("recordToggle")))
    expect ValueError: discard migrateWorkflowMenus(duplicate, artwork())
    let noDeafen = liveLikeConfig()
    entry(noDeafen, "discord", 7)["action"] = %*{"kind": "command", "command": "true"}
    expect ValueError: discard migrateWorkflowMenus(noDeafen, artwork())

  test "relocates custom root keys and keeps foreign menus and their links":
    let source = liveLikeConfig()
    entry(source, "root", 3)["action"] = %*{"kind": "command", "command": "custom"}
    source["menus"].add(%*{"id": "games", "title": "Games", "mixer": [
      {"key": 2, "title": "Mixer Setups", "action": {"kind": "menu", "menu": "obs-setups", "target": "mixer"}}],
      "deck": [{"key": 1, "title": "Back", "action": {"kind": "back"}},
        {"key": 2, "title": "Setups", "action": {"kind": "menu", "menu": "obs-setups", "target": "both"},
          "visual": {"image": "assets/custom.png", "showTitle": true}}]})
    let result = migrateWorkflowMenus(source, artwork())
    check sameEntry(result, "root", 6, entry(source, "root", 3))
    check entry(result, "root", 3)["action"] == link("discord")
    check entry(result, "games", 1)["action"] == link("root")
    check entry(result, "games", 5)["action"] == parseJson(MenuAction)
    check entry(result, "games", 2) == %*{"key": 2, "title": "Setups",
      "action": {"kind": "menu", "menu": "obs", "target": "both"},
      "visual": {"image": "assets/custom.png", "showTitle": true}}
    check menu(result, "games")["mixer"][0]["action"] == %*{"kind": "menu", "menu": "obs", "target": "mixer"}
    let foreign = parseJson($source)
    entry(foreign, "games", 1)["action"] = %*{"kind": "command", "command": "foreign"}
    expect ValueError: discard migrateWorkflowMenus(foreign, artwork())

  test "rerunning keeps customized art, titles, and moved keys":
    let first = migrateWorkflowMenus(liveLikeConfig(), artwork())
    check migrateWorkflowMenus(first, artwork()) == first
    entry(first, "obs", 7)["title"] = %"Raid"
    entry(first, "obs", 7)["visual"]["image"] = %"assets/raid.png"
    entry(first, "root", 1)["visual"]["image"] = %"assets/my-menu.png"
    entry(first, DeckNavigationMenuId, 2)["title"] = %"Main"
    relocate(first, "work", [(13, 15), (15, 13)])
    let before = $first
    check migrateWorkflowMenus(first, artwork()) == first
    check $first == before

  test "rerunning restores a deleted generated key without a shared header":
    let first = migrateWorkflowMenus(liveLikeConfig(), artwork())
    var deck: seq[JsonNode]
    for candidate in menu(first, "obs")["deck"]:
      if candidate["action"] != obsOp("wow1080"): deck.add(candidate)
    menu(first, "obs")["deck"] = %deck
    let result = migrateWorkflowMenus(first, artwork())
    check entry(result, "obs", 12)["action"] == obsOp("wow1080")
    check layout(result, "root").len == layout(first, "root").len

  test "the legacy OBS Setups installer leaves a flattened OBS menu alone":
    let
      flattened = migrateWorkflowMenus(liveLikeConfig(), artwork())
      setupArt = block:
        var names = initTable[string, string]()
        for name in ObsSetupsArtworkNames: names[name] = "assets/" & name & ".png"
        names
    check installObsSetupsMenu(flattened, setupArt) == flattened

  test "upgrades the current left Menu without changing commands or edited faces":
    let source = leftMenuConfig()
    menu(source, "root")["deck"].add(%*{"key": 5, "title": "5",
      "action": {"kind": "none"}, "visual": {"builtinNumber": 5}})
    entry(source, "obs", 1)["visual"]["image"] = %"assets/custom-menu.png"
    entry(source, "work", 10)["action"]["command"] = %"xdg-open https://polyworld.gg/"
    let original = $source
    let updated = migrateWorkflowMenus(source, artwork())
    validateButtonConfig(updated)
    check $source == original
    check entry(updated, "root", 5).isNil
    for (id, key) in [("obs", 9), ("discord", 8), ("work", 13)]:
      check sameEntry(updated, id, key, entry(source, id, 5))
      check sameEntry(updated, id, 5, entry(source, id, 1))
    check entry(updated, "work", 10) == entry(source, "work", 10)
    check migrateWorkflowMenus(updated, artwork()) == updated

  test "occupied standard destinations refuse without changing the source":
    for (id, key) in [("obs", 9), ("discord", 8), ("work", 13)]:
      let source = leftMenuConfig()
      menu(source, id)["deck"].add(button(key, "Keep", %*{"kind": "command", "command": "keep"}))
      let original = $source
      expect ValueError: discard migrateWorkflowMenus(source, artwork())
      check $source == original

  test "custom Home key 5 moves whole and a full Home page refuses":
    let source = leftMenuConfig()
    let custom = button(5, "Keep", %*{"kind": "command", "command": "keep"})
    menu(source, "root")["deck"].add(custom)
    let updated = migrateWorkflowMenus(source, artwork())
    check sameEntry(updated, "root", 6, custom)
    check entry(updated, "root", 5).isNil
    for key in 6..15:
      let occupied = entry(source, "root", key)
      if occupied.isNil:
        menu(source, "root")["deck"].add(button(key, "Keep " & $key,
          %*{"kind": "command", "command": "keep " & $key}))
      else:
        occupied["action"] = %*{"kind": "command", "command": "keep " & $key}
    let original = $source
    expect ValueError: discard migrateWorkflowMenus(source, artwork())
    check $source == original

  test "a duplicate legacy navigation destination is refused rather than overwritten":
    let source = leftMenuConfig()
    entry(source, DeckNavigationMenuId, 3)["action"] = link("obs")
    validateButtonConfig(source)
    let original = $source
    expect ValueError: discard migrateWorkflowMenus(source, artwork())
    check $source == original

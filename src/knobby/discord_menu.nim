import
  std/[json, tables]

const
  DiscordMenuId* = "discord"
  DiscordArtworkNames* = ["menu-discord", "back", "system-live", "system-muted",
    "system-mixed", "system-unavailable", "discord-live", "discord-muted",
    "discord-deafened", "discord-unavailable", "deafen-live", "deafen-muted",
    "deafen-unavailable", "open-idle", "open-running", "voice-wait", "voice-ready",
    "voice-unavailable", "video-wait", "video-ready", "video-unavailable"]

proc installDiscordMenu*(source: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Return an owned configuration adding Discord and Help without replacing existing bindings.
  result = parseJson($source)
  var root: JsonNode
  for menu in result["menus"]:
    if menu["id"].getStr() == DiscordMenuId:
      raise newException(ValueError, "The Discord menu already exists; use the editor to change it.")
    if menu["id"].getStr() == result["root"].getStr(): root = menu
  if root.isNil:
    raise newException(ValueError, "The root menu is missing.")
  for device in ["deck", "mixer"]:
    for button in root[device]:
      if button["key"].getInt() == 3 and button["action"]["kind"].getStr() != "none":
        raise newException(ValueError, "Root " & device & " key 3 already has an action; refusing to replace it.")
  proc key(number: int, title, kind, image: string,
      states: openArray[(string, string)] = []): JsonNode =
    ## Build a key face whose variants are selected from daemon observations.
    result = %*{"key": number, "title": title, "action": {"kind": kind},
      "visual": {"image": artwork[image], "showTitle": false}}
    if states.len > 0:
      result["visual"]["states"] = newJObject()
      for (state, art) in states: result["visual"]["states"][state] = %artwork[art]
  let menu = %*{"id": DiscordMenuId, "title": "Discord", "mixer": [], "deck": []}
  menu["deck"].add(key(1, "Back", "back", "back"))
  menu["deck"].add(key(2, "System Mic", "microphones", "system-live",
    [("muted", "system-muted"), ("mixed", "system-mixed"), ("unavailable", "system-unavailable")]))
  menu["deck"].add(key(3, "Discord Mic", "discord", "discord-live",
    [("muted", "discord-muted"), ("deafened", "discord-deafened"), ("unavailable", "discord-unavailable")]))
  menu["deck"].add(key(4, "Deafen", "discordDeafen", "deafen-live",
    [("deafened", "deafen-muted"), ("unavailable", "deafen-unavailable")]))
  menu["deck"].add(key(5, "Open Discord", "openDiscord", "open-idle",
    [("running", "open-running"), ("ready", "open-running"), ("unavailable", "open-idle")]))
  menu["deck"].add(key(6, "Answer voice", "discordAcceptVoice", "voice-wait",
    [("ready", "voice-ready"), ("unavailable", "voice-unavailable")]))
  menu["deck"].add(key(7, "Answer video", "discordAcceptVideo", "video-wait",
    [("ready", "video-ready"), ("unavailable", "video-unavailable")]))
  let
    deckEntry = key(3, "Discord", "menu", "menu-discord")
    mixerEntry = %*{"key": 3, "title": "Show buttons", "action": {"kind": "mixerOverlay"}}
  deckEntry["action"]["menu"] = %DiscordMenuId
  deckEntry["action"]["target"] = %"deck"
  for (device, entry) in [("deck", deckEntry), ("mixer", mixerEntry)]:
    var replaced = false
    for index in 0..<root[device].len:
      if root[device][index]["key"].getInt() == 3:
        root[device].elems[index] = entry
        replaced = true
    if not replaced: root[device].add(entry)
  result["menus"].add(menu)

proc refreshDiscordArtwork*(source: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Refresh standard Discord key faces, preserving titles, actions, other menus, and custom bindings.
  result = parseJson($source)
  var current: JsonNode
  for menu in result["menus"]:
    if menu["id"].getStr() == DiscordMenuId: current = menu
  if current.isNil:
    raise newException(ValueError, "The Discord menu is missing; install it before refreshing artwork.")
  let templateConfig = installDiscordMenu(%*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Main", "mixer": [], "deck": []}]}, artwork)
  for button in current["deck"]:
    for standard in templateConfig["menus"][1]["deck"]:
      if button["key"] == standard["key"] and button["action"] == standard["action"]:
        button["visual"] = standard["visual"]
  let rootEntry = templateConfig["menus"][0]["deck"][0]
  for menu in result["menus"]:
    if menu["id"].getStr() == result["root"].getStr():
      for button in menu["deck"]:
        if button["key"] == rootEntry["key"] and button["action"] == rootEntry["action"]:
          button["visual"] = rootEntry["visual"]

proc upgradeDiscordMenu*(source: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Add missing answer controls and refresh standard faces without replacing occupied slots.
  result = refreshDiscordArtwork(source, artwork)
  let templateConfig = installDiscordMenu(%*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Main", "mixer": [], "deck": []}]}, artwork)
  for menu in result["menus"]:
    if menu["id"].getStr() != DiscordMenuId: continue
    for standard in templateConfig["menus"][1]["deck"]:
      let number = standard["key"].getInt()
      if number notin [6, 7]: continue
      var found = false
      for index in 0..<menu["deck"].len:
        let button = menu["deck"][index]
        if button["key"].getInt() != number: continue
        found = true
        if button["action"] == standard["action"]: continue
        if button["action"]["kind"].getStr() != "none" or button{"visual"} != nil:
          raise newException(ValueError, "Discord key " & $number & " is occupied; refusing to replace it.")
        menu["deck"].elems[index] = standard
      if not found: menu["deck"].add(standard)

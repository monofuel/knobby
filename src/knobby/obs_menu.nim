import
  std/[json, tables]

const
  ObsSetupsMenuId* = "obs-setups"
  ObsSetupsMenuTitle* = "OBS Setups"
  ObsSetupsArtworkNames* = ["menu-setups", "project-minecraft", "project-minecraft-active",
    "project-minecraft-unavailable", "project-firefox", "project-firefox-active",
    "project-firefox-unavailable", "firefox-launch", "firefox-1080-needed", "firefox-1080",
    "project-wow", "project-wow-active", "project-wow-unavailable",
    "setup-minecraft-1080", "setup-minecraft-1080-needed", "setup-minecraft-1080-unavailable",
    "setup-firefox-1080", "setup-firefox-1080-needed", "setup-firefox-1080-unavailable",
    "setup-wow-1080", "setup-wow-1080-needed", "setup-wow-1080-unavailable"]
  FlattenedObsOperations = ["selectMinecraft", "selectFirefox", "selectWow",
    "minecraft1080", "firefox1080", "wow1080"]

proc deckEntry(menu: JsonNode, key: int): JsonNode =
  ## Return an explicit Deck entry or nil when the key is unassigned.
  for entry in menu["deck"]:
    if entry["key"].getInt() == key: return entry

proc face(key: int, title, operation, image: string, artwork: Table[string, string],
    states: openArray[(string, string)]): JsonNode =
  ## Build a state-aware setup action using the same managed media as the button editor.
  result = %*{"key": key, "title": title, "action": {"kind": "obs", "operation": operation},
    "visual": {"image": artwork[image], "showTitle": false, "states": {}}}
  for (state, name) in states: result["visual"]["states"][state] = %artwork[name]

proc installObsSetupsMenu*(source: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Add paired recording setups inside OBS, preserving all existing menus and MIDI controls.
  ## The four standard navigation keys are copied unchanged; a free OBS key from 10 to 15
  ## opens the new menu. Reapplying an identical installation is a no-op; custom occupants
  ## and an edited existing setup menu are refused without modifying the source. An OBS menu
  ## already holding all six setup and resize keys without this submenu is returned unchanged.
  result = parseJson($source)
  var obs, existing: JsonNode
  for menu in result["menus"]:
    if menu["id"].getStr() == "obs": obs = menu
    if menu["id"].getStr() == ObsSetupsMenuId: existing = menu
  if obs.isNil: raise newException(ValueError, "Install the OBS menu before adding its setups.")
  # The workflow layout flattens these controls into OBS and removes this submenu.
  var flattened = 0
  for operation in FlattenedObsOperations:
    for entry in obs["deck"]:
      if entry["action"] == %*{"kind": "obs", "operation": operation}:
        inc flattened
        break
  if existing.isNil and flattened == FlattenedObsOperations.len: return
  let menu = %*{"id": ObsSetupsMenuId, "title": ObsSetupsMenuTitle, "mixer": [], "deck": []}
  for key, target in [source["root"].getStr(), "obs", "discord", "work"]:
    let entry = obs.deckEntry(key + 1)
    if entry.isNil or entry["action"] != %*{"kind": "menu", "menu": target, "target": "deck"}:
      raise newException(ValueError, "Organize the Home/OBS/Discord/Softmax navigation keys first.")
    menu["deck"].add(parseJson($entry))
  for (key, title, operation, art) in [(5, "Minecraft AI Demos", "selectMinecraft", "project-minecraft"),
      (6, "Firefox Demos", "selectFirefox", "project-firefox"),
      (7, "WoW Demos", "selectWow", "project-wow")]:
    menu["deck"].add(face(key, title, operation, art, artwork,
      [("active", art & "-active"), ("blocked", art & "-unavailable"),
        ("unavailable", art & "-unavailable")]))
  for (key, title, operation, art) in [
      (10, "Minecraft 1080p", "minecraft1080", "setup-minecraft-1080"),
      (11, "Firefox demo 1080p", "firefox1080", "setup-firefox-1080"),
      (12, "WoW 1080p", "wow1080", "setup-wow-1080")]:
    menu["deck"].add(face(key, title, operation, art & "-needed", artwork,
      [("unavailable", art & "-unavailable"), ("running", art & "-needed"), ("ready", art)]))
  let link = %*{"kind": "menu", "menu": ObsSetupsMenuId, "target": "deck"}
  if not existing.isNil:
    var links = 0
    for entry in obs["deck"]:
      if entry["action"] == link: inc links
    if links != 1:
      raise newException(ValueError, "OBS Setups has ambiguous navigation; no buttons were replaced.")
    var complete = true
    for entry in menu["deck"]:
      let current = existing.deckEntry(entry["key"].getInt())
      if current.isNil or current["action"] != entry["action"]: complete = false
    if complete: return
    if existing["deck"].len != 7:
      raise newException(ValueError, "OBS Setups has custom slots; no buttons were replaced.")
    for key in 1..6:
      let current = existing.deckEntry(key)
      if current.isNil or current["action"] != menu.deckEntry(key)["action"]:
        raise newException(ValueError, "OBS Setups has custom actions; no buttons were replaced.")
    let firefox = existing.deckEntry(7)
    if firefox.isNil or firefox["action"] != %*{"kind": "obs", "operation": "firefox1080"}:
      raise newException(ValueError, "OBS Setups key 7 was customized; no buttons were replaced.")
    for index in 0..<6:
      menu["deck"].elems[index] = parseJson($existing.deckEntry(index + 1))
    let originalFirefox = face(7, "Firefox demo window / 1080p", "firefox1080", "firefox-launch", artwork,
      [("unavailable", "firefox-launch"), ("running", "firefox-1080-needed"), ("ready", "firefox-1080")])
    if firefox{"visual"} != originalFirefox{"visual"}:
      menu.deckEntry(11)["visual"] = parseJson($firefox["visual"])
    if firefox["title"].getStr() != "Firefox demo window / 1080p":
      menu.deckEntry(11)["title"] = firefox["title"]
    existing["deck"] = menu["deck"]
    return
  var slot = 0
  for key in 10..15:
    let entry = obs.deckEntry(key)
    if entry.isNil or (entry["action"]["kind"].getStr() == "none" and
        entry{"visual"}{"image"}.isNil and entry{"visual"}{"states"}.isNil):
      slot = key
      break
  if slot == 0: raise newException(ValueError, "OBS keys 10 to 15 are occupied; no existing button was replaced.")
  let entry = %*{"key": slot, "title": "OBS Setups", "action": link,
    "visual": {"image": artwork["menu-setups"], "showTitle": false}}
  var replaced = false
  for index in 0..<obs["deck"].len:
    if obs["deck"][index]["key"].getInt() == slot:
      obs["deck"].elems[index] = entry
      replaced = true
  if not replaced: obs["deck"].add(entry)
  result["menus"].add(menu)

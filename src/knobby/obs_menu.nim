import
  std/[json, tables]

const
  ObsSetupsMenuId* = "obs-setups"
  ObsSetupsMenuTitle* = "OBS Setups"
  ObsSetupsArtworkNames* = ["menu-setups", "project-minecraft", "project-minecraft-active",
    "project-minecraft-unavailable", "project-firefox", "project-firefox-active",
    "project-firefox-unavailable", "firefox-launch", "firefox-1080-needed", "firefox-1080"]

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
  ## and an edited existing setup menu are refused without modifying the source.
  result = parseJson($source)
  var obs, existing: JsonNode
  for menu in result["menus"]:
    if menu["id"].getStr() == "obs": obs = menu
    if menu["id"].getStr() == ObsSetupsMenuId: existing = menu
  if obs.isNil: raise newException(ValueError, "Install the OBS menu before adding its setups.")
  let menu = %*{"id": ObsSetupsMenuId, "title": ObsSetupsMenuTitle, "mixer": [], "deck": []}
  for key, target in [source["root"].getStr(), "obs", "discord", "work"]:
    let entry = obs.deckEntry(key + 1)
    if entry.isNil or entry["action"] != %*{"kind": "menu", "menu": target, "target": "deck"}:
      raise newException(ValueError, "Organize the Home/OBS/Discord/Softmax navigation keys first.")
    menu["deck"].add(parseJson($entry))
  for (key, title, operation, art) in [(5, "Minecraft AI Demos", "selectMinecraft", "project-minecraft"),
      (6, "Firefox Demos", "selectFirefox", "project-firefox")]:
    menu["deck"].add(face(key, title, operation, art, artwork,
      [("ready", art & "-active"), ("unavailable", art & "-unavailable")]))
  menu["deck"].add(face(7, "Firefox demo window / 1080p", "firefox1080", "firefox-launch", artwork,
    [("unavailable", "firefox-launch"), ("running", "firefox-1080-needed"), ("ready", "firefox-1080")]))
  let link = %*{"kind": "menu", "menu": ObsSetupsMenuId, "target": "deck"}
  if not existing.isNil:
    var links = 0
    for entry in obs["deck"]:
      if entry["action"] == link: inc links
    let
      currentShape = parseJson($existing)
      wantedShape = parseJson($menu)
    for shape in [currentShape, wantedShape]:
      for entry in shape["deck"]: entry.delete("visual")
    if currentShape == wantedShape and links == 1: return
    raise newException(ValueError, "OBS Setups already exists; use the editor to change it.")
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

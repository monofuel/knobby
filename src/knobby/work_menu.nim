import
  std/[json, tables]

const
  WorkMenuId* = "work"
  WorkRootKey* = 4
  WorkMenuArt* = "work/menu-work"
  WorkBackArt* = "obs/back"

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
  if target.hasKey("states"):
    result["visual"]["states"] = newJObject()
    for state, art in target["states"].pairs:
      result["visual"]["states"][state] = %artwork[art.getStr()]

proc sameControl(current, wanted: JsonNode): bool =
  ## Compare one button by key, title, and action, ignoring artwork paths.
  result = true
  for field in ["key", "title", "action"]:
    if current{field} != wanted[field]: result = false

proc sameControls(current, wanted: JsonNode): bool =
  ## Compare button arrays in order by key, title, and action, ignoring artwork paths.
  result = current.len == wanted.len
  if result:
    for index in 0..<wanted.len:
      if not sameControl(current[index], wanted[index]): result = false

proc installWorkMenu*(source, targets: JsonNode, artwork: Table[string, string]): JsonNode =
  ## Return an owned configuration adding the Deck-only Work menu at root Deck key 4.
  ## An identical existing installation is returned unchanged; any other occupant is refused.
  result = parseJson($source)
  var root, existing: JsonNode
  for menu in result["menus"]:
    if menu["id"].getStr() == WorkMenuId: existing = menu
    if menu["id"].getStr() == result["root"].getStr(): root = menu
  if root.isNil:
    raise newException(ValueError, "The root menu is missing.")
  let menu = %*{"id": WorkMenuId, "title": "Work", "mixer": [], "deck": [
    {"key": 1, "title": "Back", "action": {"kind": "back"},
      "visual": {"image": artwork[WorkBackArt], "showTitle": false}}]}
  for target in targets:
    if target["key"].getInt() == 1:
      raise newException(ValueError, "Work key 1 is reserved for Back.")
    menu["deck"].add(workButton(target, artwork))
  let entry = %*{"key": WorkRootKey, "title": "Work",
    "action": {"kind": "menu", "menu": WorkMenuId, "target": "deck"},
    "visual": {"image": artwork[WorkMenuArt], "showTitle": false}}
  var slot = -1
  for index in 0..<root["deck"].len:
    if root["deck"][index]["key"].getInt() == WorkRootKey: slot = index
  if not existing.isNil:
    let unchanged = slot >= 0 and sameControl(root["deck"][slot], entry) and
      existing["mixer"].len == 0 and sameControls(existing["deck"], menu["deck"])
    if not unchanged:
      raise newException(ValueError, "A different Work menu already exists; use the editor to change it.")
  elif slot >= 0 and root["deck"][slot]["action"]["kind"].getStr() != "none":
    raise newException(ValueError, "Root deck key " & $WorkRootKey & " already has an action; refusing to replace it.")
  else:
    if slot >= 0: root["deck"].elems[slot] = entry
    else: root["deck"].add(entry)
    result["menus"].add(menu)

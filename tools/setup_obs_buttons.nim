import
  std/[json, os, tables],
  ../src/knobby/[button_client, button_config]

const
  ObsMenuId = "obs"
  DefaultArtDirectory = currentSourcePath().parentDir().parentDir() / "assets/obs"

proc installObsButtons(artDirectory: string) =
  ## Add the approved OBS submenu through the same revision-checked API as the editor.
  let
    reply = requireConfigResult(requestConfig("config.get"))
    envelope = reply["envelope"]
    config = envelope["config"]
  var
    root: JsonNode
    existing: JsonNode
    artwork = initTable[string, string]()
  for menu in config["menus"]:
    if menu["id"].getStr() == config["root"].getStr(): root = menu
    if menu["id"].getStr() == ObsMenuId: existing = menu
  if existing != nil:
    raise newException(ValueError, "The OBS menu already exists; edit it with the GUI or config export/apply.")
  if root == nil: raise newException(ValueError, "The root menu is missing.")
  for name in ["menu-obs", "back", "record-idle", "record-recording", "record-paused",
      "pause-idle", "pause-running", "pause-paused", "mic-enabled", "mic-muted",
      "obs-open", "unavailable", "minecraft-1080"]:
    let record = runConfigOperation("config.importAsset",
      %*{"source": absolutePath(artDirectory / (name & ".png"))})
    artwork[name] = record["path"].getStr()
  let menu = %*{"id": ObsMenuId, "title": "OBS", "mixer": [], "deck": []}
  proc key(number: int, title: string, action: JsonNode, image: string,
      states: openArray[(string, string)] = []): JsonNode =
    ## Build a button with native artwork and optional actual-state variants.
    result = %*{"key": number, "title": title, "action": action,
      "visual": {"image": artwork[image], "showTitle": false}}
    if states.len > 0:
      result["visual"]["states"] = newJObject()
      for (state, art) in states: result["visual"]["states"][state] = %artwork[art]
  menu["deck"].add(key(1, "Back", %*{"kind": "back"}, "back"))
  menu["deck"].add(key(2, "Record", %*{"kind": "obs", "operation": "recordToggle"},
    "record-idle", [("recording", "record-recording"), ("paused", "record-paused"),
    ("unavailable", "unavailable")]))
  menu["deck"].add(key(3, "Pause", %*{"kind": "obs", "operation": "pauseToggle"},
    "pause-idle", [("recording", "pause-running"), ("paused", "pause-paused"),
    ("unavailable", "pause-idle")]))
  menu["deck"].add(key(4, "Commentary", %*{"kind": "obs", "operation": "micToggle"},
    "mic-enabled", [("muted", "mic-muted"), ("unavailable", "unavailable")]))
  menu["deck"].add(key(5, "Open OBS", %*{"kind": "obs", "operation": "open"},
    "obs-open", [("unavailable", "unavailable")]))
  menu["deck"].add(key(6, "Minecraft 1080p", %*{"kind": "obs", "operation": "minecraft1080"},
    "minecraft-1080"))
  let entry = key(2, "OBS", %*{"kind": "menu", "menu": ObsMenuId, "target": "deck"}, "menu-obs")
  var replaced = false
  for index in 0..<root["deck"].len:
    if root["deck"][index]["key"].getInt() == 2:
      root["deck"].elems[index] = entry
      replaced = true
  if not replaced: root["deck"].add(entry)
  config["menus"].add(menu)
  validateButtonConfig(config)
  echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1..2 or args[0] != "--apply":
    quit("Usage: setup_obs_buttons --apply [ART_DIRECTORY]", 2)
  installObsButtons(if args.len == 2: args[1] else: DefaultArtDirectory)

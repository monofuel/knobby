import
  std/json,
  ./[button_config, spotify_menu, workflow_menu]

proc markCustomButtons*(source, workTargets: JsonNode): JsonNode =
  ## Mark only known integration actions as editor-protected, retaining their commands, labels, positions and artwork.
  result = parseJson($source)
  var actions: seq[JsonNode]
  for (key, title, operation, art) in SpotifyCommands:
    actions.add(%*{"kind": "command", "command": spotifyCommand(operation)})
  for target in workTargets:
    if target{"customLogic"}.getBool(): actions.add(target["action"])
  for menu in result["menus"]:
    for device in ["mixer", "deck"]:
      for entry in menu{device}.getElems():
        if entry["action"] in actions: entry["customLogic"] = %true
  result = clearUnusedHomeNumbers(result)
  validateButtonConfig(result)

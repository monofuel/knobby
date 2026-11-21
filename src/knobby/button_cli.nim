import
  std/[json, os, strutils],
  ./[button_client, button_config]

proc configUsage*(): string =
  ## Describe the shared configuration workflow for humans and automation.
  """Usage: knobby config export [FILE]
       knobby config validate [--prepare] FILE
       knobby config apply FILE
       knobby config import-asset FILE

Export an editable {baseRevision, config} JSON document, edit it, validate,
then apply it. Apply rejects stale revisions and never executes button actions.
Import copies PNG, JPEG, or GIF artwork into managed configuration assets."""

proc navigationUsage*(): string =
  ## Describe the Deck drawer navigation commands.
  """Usage: knobby navigation status
       knobby navigation toggle|cancel
       knobby navigation select KEY

Open, cancel, or choose a destination (keys 1-5) of the Stream Deck Menu drawer or Home,
exactly as the physical keys do, then wait for the Deck to confirm the page.
It never presses other keys or runs application actions."""

proc navigationSummary(status: JsonNode): JsonNode =
  ## Select the Deck navigation fields of the daemon's button status.
  result = newJObject()
  for key in ["deckMenu", "deckDrawer", "deckDrawerMenu", "deckKeyMenus", "deckGeneration",
      "deckReadGeneration", "deckReady", "historyDepth", "mixerMenu", "revision"]:
    result[key] = if status.hasKey(key): status[key] else: newJNull()

proc runNavigationCli*(args: seq[string]) =
  ## Drive the Deck drawer through the daemon's bounded navigation request.
  if args.len == 0 or args[0] in ["--help", "help"]:
    echo navigationUsage()
    return
  var payload: JsonNode
  case args[0]
  of "status":
    if args.len != 1:
      raise newException(ValueError, navigationUsage())
    echo navigationSummary(readButtonStatus())
    return
  of "toggle", "cancel":
    if args.len != 1:
      raise newException(ValueError, navigationUsage())
    payload = %*{"operation": args[0]}
  of "select":
    if args.len != 2:
      raise newException(ValueError, navigationUsage())
    payload = %*{"operation": "select", "key": parseInt(args[1])}
  else:
    raise newException(ValueError, navigationUsage())
  let reply = requireConfigResult(requestConfig("deck.navigation", payload))
  echo navigationSummary(waitDeckPage(reply["deckGeneration"].getBiggestInt()))

proc readCandidate(path: string): JsonNode =
  ## Read an exported draft or a bare configuration for validation.
  let node = parseFile(path)
  if node.kind == JObject and node.hasKey("config"): node["config"]
  else: node

proc runButtonConfigCli*(args: seq[string]) =
  ## Use the same validator and daemon transactions as the graphical editor.
  if args.len == 0 or args[0] in ["--help", "help"]:
    echo configUsage()
    return
  case args[0]
  of "export":
    if args.len notin 1..2:
      raise newException(ValueError, configUsage())
    let
      reply = requireConfigResult(requestConfig("config.get"))
      content = reply["envelope"].pretty() & "\n"
    if args.len == 2: writeFile(args[1], content)
    else: stdout.write(content)
  of "validate":
    let prepare = args.len == 3 and args[1] == "--prepare"
    if (not prepare and args.len != 2) or (args.len == 3 and not prepare):
      raise newException(ValueError, configUsage())
    let config = readCandidate(args[^1])
    validateButtonConfig(config)
    if prepare:
      echo runConfigOperation("config.preview", %*{"config": config})
    else:
      echo %*{"ok": true, "revision": configRevision(config)}
  of "apply":
    if args.len != 2:
      raise newException(ValueError, configUsage())
    let envelope = parseFile(args[1])
    discard parseConfigEnvelope(envelope)
    echo runConfigOperation("config.apply", %*{"envelope": envelope})
  of "import-asset":
    if args.len != 2:
      raise newException(ValueError, configUsage())
    echo runConfigOperation("config.importAsset", %*{"source": absolutePath(args[1])})
  else:
    raise newException(ValueError, configUsage())

import
  std/[json, os],
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

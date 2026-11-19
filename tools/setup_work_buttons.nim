import
  std/[json, os, tables],
  ../src/knobby/[button_client, button_config, work_menu]

const
  RepositoryDirectory = currentSourcePath().parentDir().parentDir()
  DefaultTargetsFile = RepositoryDirectory / "docs/work-menu-targets.json"
  DefaultAssetsDirectory = RepositoryDirectory / "assets"

proc main() =
  ## Install the Deck-only Softmax menu through the shared configuration API.
  let args = commandLineParams()
  if args.len notin 1..3 or args[0] != "--apply":
    quit("Usage: setup_work_buttons --apply [TARGETS_FILE [ASSETS_DIRECTORY]]", 2)
  let
    targets = parseFile(if args.len >= 2: args[1] else: DefaultTargetsFile)
    assetsDirectory = if args.len == 3: args[2] else: DefaultAssetsDirectory
    reply = requireConfigResult(requestConfig("config.get"))
    envelope = reply["envelope"]
    names = workArtworkNames(targets)
  var artwork = initTable[string, string]()
  for name in names: artwork[name] = "assets/" & name.extractFilename() & ".png"
  let preview = installWorkMenu(envelope["config"], targets, artwork)
  validateButtonConfig(preview)
  if preview == envelope["config"]:
    echo "The Softmax menu is already installed; nothing to apply."
  else:
    for name in names:
      let record = runConfigOperation("config.importAsset",
        %*{"source": absolutePath(assetsDirectory / (name & ".png"))})
      artwork[name] = record["path"].getStr()
    envelope["config"] = installWorkMenu(envelope["config"], targets, artwork)
    validateButtonConfig(envelope["config"])
    echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  main()

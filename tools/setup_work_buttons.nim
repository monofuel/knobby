import
  std/[json, os, tables],
  ../src/knobby/[button_client, button_config, work_menu]

const
  RepositoryDirectory = currentSourcePath().parentDir().parentDir()
  DefaultTargetsFile = RepositoryDirectory / "docs/work-menu-targets.json"
  DefaultAssetsDirectory = RepositoryDirectory / "assets"
  Usage = "Usage: setup_work_buttons --apply [TARGETS_FILE [ASSETS_DIRECTORY]]\n" &
    "       setup_work_buttons --refresh-menu-art [ASSETS_DIRECTORY]"

proc installMenu(args: seq[string]) =
  ## Install the Deck-only Softmax menu through the shared configuration API.
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

proc refreshMenuArt(args: seq[string]) =
  ## Replace only the root Softmax key image with the repository artwork.
  let
    assetsDirectory = if args.len == 2: args[1] else: DefaultAssetsDirectory
    current = requireConfigResult(requestConfig("config.get"))["envelope"]["config"]
  validateButtonConfig(refreshWorkMenuArtwork(current, "assets/menu-work.png"))
  let
    record = runConfigOperation("config.importAsset",
      %*{"source": absolutePath(assetsDirectory / (WorkMenuArt & ".png"))})
    envelope = requireConfigResult(requestConfig("config.get"))["envelope"]
    candidate = refreshWorkMenuArtwork(envelope["config"], record["path"].getStr())
  validateButtonConfig(candidate)
  if candidate == envelope["config"]:
    echo "The Softmax key already shows this artwork; nothing to apply."
  else:
    envelope["config"] = candidate
    echo runConfigOperation("config.apply", %*{"envelope": envelope})

proc main() =
  ## Dispatch the install or artwork refresh mode.
  let args = commandLineParams()
  if args.len in 1..3 and args[0] == "--apply": installMenu(args)
  elif args.len in 1..2 and args[0] == "--refresh-menu-art": refreshMenuArt(args)
  else: quit(Usage, 2)

when isMainModule:
  main()

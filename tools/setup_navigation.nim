import
  std/[json, os, tables],
  ../src/knobby/[button_client, button_config, navigation_menu]

const
  RepositoryDirectory = currentSourcePath().parentDir().parentDir()
  DefaultTargetsFile = RepositoryDirectory / "docs/work-menu-targets.json"
  DefaultAssetsDirectory = RepositoryDirectory / "assets"
  Usage = "Usage: setup_navigation --apply [TARGETS_FILE [ASSETS_DIRECTORY]]"

proc main() =
  ## Give the root, OBS, Discord, and Softmax Decks the shared navigation prefix through the config API.
  let args = commandLineParams()
  if args.len notin 1..3 or args[0] != "--apply": quit(Usage, 2)
  let
    startTarget = startServerTarget(parseFile(if args.len >= 2: args[1] else: DefaultTargetsFile))
    assetsDirectory = if args.len == 3: args[2] else: DefaultAssetsDirectory
    names = navigationArtworkNames()
    current = requireConfigResult(requestConfig("config.get"))["envelope"]["config"]
  var artwork = initTable[string, string]()
  for name in names: artwork[name] = "assets/" & name.extractFilename() & ".png"
  validateButtonConfig(migrateNavigation(current, artwork, startTarget))
  for name in names:
    let record = runConfigOperation("config.importAsset",
      %*{"source": absolutePath(assetsDirectory / (name & ".png"))})
    artwork[name] = record["path"].getStr()
  let
    envelope = requireConfigResult(requestConfig("config.get"))["envelope"]
    candidate = migrateNavigation(envelope["config"], artwork, startTarget)
  validateButtonConfig(candidate)
  if candidate == envelope["config"]:
    echo "The shared navigation keys are already organized; nothing to apply."
  else:
    envelope["config"] = candidate
    echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  main()

import
  std/[json, os, tables],
  ../src/knobby/[button_client, button_config, workflow_menu]

const
  DefaultAssetsDirectory = currentSourcePath().parentDir().parentDir() / "assets"
  Usage = "Usage: setup_workflow_layout --apply [ASSETS_DIRECTORY]"

proc placeholderArtwork(): Table[string, string] =
  ## Map every layout artwork name to a harmless managed path for checking before any import.
  for name in workflowArtworkNames(): result[name] = "assets/" & name.extractFilename() & ".png"

proc runWorkflowSetup*(args: seq[string]) =
  ## Apply the Menu drawer and flattened OBS layout through the revision-checked configuration API.
  ## The candidate is checked before importing artwork, then rebuilt from a fresh revision.
  if args.len notin 1..2 or args[0] != "--apply": quit(Usage, 2)
  let
    assetsDirectory = if args.len == 2: absolutePath(args[1]) else: DefaultAssetsDirectory
    initial = requireConfigResult(requestConfig("config.get"))["envelope"]["config"]
  validateButtonConfig(migrateWorkflowMenus(initial, placeholderArtwork()))
  var artwork = initTable[string, string]()
  for name in workflowArtworkNames():
    artwork[name] = runConfigOperation("config.importAsset",
      %*{"source": assetsDirectory / (name & ".png")})["path"].getStr()
  let
    envelope = requireConfigResult(requestConfig("config.get"))["envelope"]
    candidate = migrateWorkflowMenus(envelope["config"], artwork)
  validateButtonConfig(candidate)
  if candidate == envelope["config"]:
    echo "The workflow layout is already in place; nothing to apply."
  else:
    envelope["config"] = candidate
    echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  runWorkflowSetup(commandLineParams())

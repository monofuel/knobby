import
  std/[json, os, tables],
  ../src/knobby/[button_client, button_config, obs_menu]

const
  DefaultArtDirectory = currentSourcePath().parentDir().parentDir() / "assets/obs"
  Usage = "Usage: setup_obs_setups --apply [ART_DIRECTORY]"

proc main() =
  ## Add the OBS setups submenu through the shared revision-checked configuration API.
  let
    args = commandLineParams()
    artDirectory = if args.len == 2: absolutePath(args[1]) else: DefaultArtDirectory
  if args.len notin 1..2 or args[0] != "--apply": quit(Usage, 2)
  var artwork = initTable[string, string]()
  for name in ObsSetupsArtworkNames: artwork[name] = "assets/" & name & ".png"
  let initial = requireConfigResult(requestConfig("config.get"))["envelope"]["config"]
  validateButtonConfig(installObsSetupsMenu(initial, artwork))
  for name in ObsSetupsArtworkNames:
    artwork[name] = runConfigOperation("config.importAsset",
      %*{"source": artDirectory / (name & ".png")})["path"].getStr()
  let
    envelope = requireConfigResult(requestConfig("config.get"))["envelope"]
    candidate = installObsSetupsMenu(envelope["config"], artwork)
  validateButtonConfig(candidate)
  if candidate == envelope["config"]:
    echo "OBS Setups is already installed; nothing to apply."
  else:
    envelope["config"] = candidate
    echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  main()

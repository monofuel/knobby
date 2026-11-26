import
  std/[json, os, tables],
  knobby/[button_client, games_menu]

const DefaultAssetsDirectory = currentSourcePath().parentDir().parentDir() / "assets"

proc main() =
  ## Import artwork and install Games through the daemon's revision-checked transaction.
  if commandLineParams() != @["--apply"]:
    quit("Usage: setup_games_buttons --apply", 2)
  let current = requireConfigResult(requestConfig("config.get"))["envelope"]["config"]
  var artwork = initTable[string, string]()
  for name in GamesArtwork: artwork[name] = "assets/" & name.extractFilename() & ".png"
  if installGamesMenu(current, artwork) == current:
    echo "Games is already installed; existing edits were preserved."
    return
  for name in GamesArtwork:
    artwork[name] = runConfigOperation("config.importAsset",
      %*{"source": DefaultAssetsDirectory / (name & ".png")})["path"].getStr()
  let envelope = requireConfigResult(requestConfig("config.get"))["envelope"]
  envelope["config"] = installGamesMenu(envelope["config"], artwork)
  echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  main()

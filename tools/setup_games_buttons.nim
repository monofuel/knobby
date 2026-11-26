import
  std/[json, os, tables],
  knobby/[button_client, games_menu]

const DefaultAssetsDirectory = currentSourcePath().parentDir().parentDir() / "assets"

proc main() =
  ## Import artwork and install Games through the daemon's revision-checked transaction.
  let args = commandLineParams()
  if args != @["--apply"] and args != @["--refresh-decompbound-art"]:
    quit("Usage: setup_games_buttons --apply|--refresh-decompbound-art", 2)
  let refresh = args == @["--refresh-decompbound-art"]
  let current = requireConfigResult(requestConfig("config.get"))["envelope"]["config"]
  var artwork = initTable[string, string]()
  let names = if refresh: @["games/decompbound"] else: @GamesArtwork
  for name in names: artwork[name] = "assets/" & name.extractFilename() & ".png"
  let preview = if refresh: refreshDecompboundArtwork(current, artwork["games/decompbound"])
    else: installGamesMenu(current, artwork)
  if preview == current:
    echo "Games is already installed; existing edits were preserved."
    return
  for name in names:
    artwork[name] = runConfigOperation("config.importAsset",
      %*{"source": DefaultAssetsDirectory / (name & ".png")})["path"].getStr()
  let envelope = requireConfigResult(requestConfig("config.get"))["envelope"]
  envelope["config"] = if refresh: refreshDecompboundArtwork(envelope["config"], artwork["games/decompbound"])
    else: installGamesMenu(envelope["config"], artwork)
  echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  main()

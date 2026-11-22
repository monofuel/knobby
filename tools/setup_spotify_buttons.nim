import
  std/[json, os, tables],
  ../src/knobby/[button_client, button_config, spotify_menu]

const DefaultAssetsDirectory = currentSourcePath().parentDir().parentDir() / "assets"

proc main() =
  ## Install Spotify through managed artwork imports and a fresh revision-checked configuration apply.
  let args = commandLineParams()
  if args.len notin 1..2 or args[0] != "--apply":
    quit("Usage: setup_spotify_buttons --apply [ASSETS_DIRECTORY]", 2)
  let
    assetsDirectory = if args.len == 2: absolutePath(args[1]) else: DefaultAssetsDirectory
    current = requireConfigResult(requestConfig("config.get"))["envelope"]["config"]
  var artwork = initTable[string, string]()
  for name in SpotifyArtwork: artwork[name] = "assets/" & name.extractFilename() & ".png"
  let preview = installSpotifyMenu(current, artwork)
  if preview == current:
    echo "Spotify is already installed; existing edits were preserved."
  else:
    for name in SpotifyArtwork:
      artwork[name] = runConfigOperation("config.importAsset",
        %*{"source": assetsDirectory / (name & ".png")})["path"].getStr()
    let envelope = requireConfigResult(requestConfig("config.get"))["envelope"]
    envelope["config"] = installSpotifyMenu(envelope["config"], artwork)
    echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  main()

import
  std/[json, os, tables],
  ../src/knobby/[button_client, spotify_menu]

const DefaultAssetsDirectory = currentSourcePath().parentDir().parentDir() / "assets"

proc main() =
  ## Install Spotify through managed artwork imports and a fresh revision-checked configuration apply.
  let args = commandLineParams()
  if args.len notin 1..2 or args[0] notin ["--apply", "--refresh-album-art"]:
    quit("Usage: setup_spotify_buttons --apply|--refresh-album-art [ASSETS_DIRECTORY]", 2)
  let
    assetsDirectory = if args.len == 2: absolutePath(args[1]) else: DefaultAssetsDirectory
    current = requireConfigResult(requestConfig("config.get"))["envelope"]["config"]
  var artwork = initTable[string, string]()
  let names = if args[0] == "--refresh-album-art": @["spotify/zero", "spotify/low-roar"] else: @SpotifyArtwork
  for name in names: artwork[name] = "assets/" & name.extractFilename() & ".png"
  let preview = if args[0] == "--refresh-album-art": refreshSpotifyAlbumArtwork(current, artwork)
    else: installSpotifyMenu(current, artwork)
  if preview == current:
    echo "Spotify is already installed; existing edits were preserved."
  else:
    for name in names:
      artwork[name] = runConfigOperation("config.importAsset",
        %*{"source": assetsDirectory / (name & ".png")})["path"].getStr()
    let envelope = requireConfigResult(requestConfig("config.get"))["envelope"]
    envelope["config"] = if args[0] == "--refresh-album-art": refreshSpotifyAlbumArtwork(envelope["config"], artwork)
      else: installSpotifyMenu(envelope["config"], artwork)
    echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  main()

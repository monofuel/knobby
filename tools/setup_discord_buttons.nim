import
  std/[json, os, tables],
  ../src/knobby/[button_client, button_config, discord_menu]

const DefaultArtDirectory = currentSourcePath().parentDir().parentDir() / "assets/discord"

proc main() =
  ## Install the Discord submenu or refresh its artwork through the shared configuration API.
  let args = commandLineParams()
  if args.len notin 1..2 or args[0] notin ["--apply", "--refresh-art"]:
    quit("Usage: setup_discord_buttons --apply|--refresh-art [ART_DIRECTORY]", 2)
  let
    artDirectory = if args.len == 2: args[1] else: DefaultArtDirectory
    reply = requireConfigResult(requestConfig("config.get"))
    envelope = reply["envelope"]
  var artwork = initTable[string, string]()
  let transform = if args[0] == "--refresh-art": refreshDiscordArtwork else: installDiscordMenu
  for name in DiscordArtworkNames: artwork[name] = "assets/" & name & ".png"
  validateButtonConfig(transform(envelope["config"], artwork))
  for name in DiscordArtworkNames:
    let record = runConfigOperation("config.importAsset",
      %*{"source": absolutePath(artDirectory / (name & ".png"))})
    artwork[name] = record["path"].getStr()
  envelope["config"] = transform(envelope["config"], artwork)
  validateButtonConfig(envelope["config"])
  echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  main()

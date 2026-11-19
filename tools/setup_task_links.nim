import
  std/[json, os, tables],
  ../src/knobby/[button_client, button_config, task_menu_links]

const
  DefaultAssetsDirectory = currentSourcePath().parentDir().parentDir() / "assets"
  Usage = "Usage: setup_task_links --apply [ASSETS_DIRECTORY]"

proc main() =
  ## Link the Softmax and Discord menus to each other through the shared configuration API.
  let args = commandLineParams()
  if args.len notin 1..2 or args[0] != "--apply": quit(Usage, 2)
  let
    assetsDirectory = if args.len == 2: args[1] else: DefaultAssetsDirectory
    current = requireConfigResult(requestConfig("config.get"))["envelope"]["config"]
  var artwork = initTable[string, string]()
  for link in TaskMenuLinks: artwork[link.art] = "assets/" & link.art.extractFilename() & ".png"
  validateButtonConfig(installTaskMenuLinks(current, artwork))
  for link in TaskMenuLinks:
    let record = runConfigOperation("config.importAsset",
      %*{"source": absolutePath(assetsDirectory / (link.art & ".png"))})
    artwork[link.art] = record["path"].getStr()
  let
    envelope = requireConfigResult(requestConfig("config.get"))["envelope"]
    candidate = installTaskMenuLinks(envelope["config"], artwork)
  validateButtonConfig(candidate)
  if candidate == envelope["config"]:
    echo "The Softmax and Discord menu links are already installed; nothing to apply."
  else:
    envelope["config"] = candidate
    echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  main()

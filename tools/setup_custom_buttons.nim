import
  std/[json, os],
  ../src/knobby/[button_client, custom_buttons]

const TargetsFile = currentSourcePath().parentDir().parentDir() / "docs/work-menu-targets.json"

proc main() =
  ## Apply only custom-action metadata and blank Home placeholders through the revision-safe shared configuration API.
  if commandLineParams() != @["--apply"]:
    quit("Usage: setup_custom_buttons --apply", 2)
  let
    envelope = requireConfigResult(requestConfig("config.get"))["envelope"]
    candidate = markCustomButtons(envelope["config"], parseFile(TargetsFile))
  if candidate == envelope["config"]:
    echo "Custom action metadata and blank Home placeholders are already current."
  else:
    envelope["config"] = candidate
    echo runConfigOperation("config.apply", %*{"envelope": envelope})

when isMainModule:
  main()

import
  std/[json, os, parseopt, strutils],
  knobby/button_media

const
  Usage = """
Usage:
  prepare_button_media prepare --config <buttons.json> --config-dir <dir>
      --cache-dir <dir> --font <font.ttf> [--output <manifest.json>]
  prepare_button_media import --source <file> --config-dir <dir>

Prepare prints the manifest JSON on stdout, or writes it atomically to
--output. Import prints {"path":"assets/<sha1>.<ext>"}. Diagnostics go to
stderr only; failures exit 1 and usage errors exit 2."""
  UsageExit = 2
  FailureExit = 1

proc usageError(message: string) {.noreturn.} =
  ## Print a usage problem to stderr and exit with the usage status.
  stderr.writeLine("error: " & message)
  stderr.writeLine(Usage)
  quit(UsageExit)

proc writeAtomically(path, content: string) =
  ## Write a file through a sibling temporary file and rename.
  let temporary = path & ".tmp-" & $getCurrentProcessId()
  writeFile(temporary, content)
  moveFile(temporary, path)

proc requireOption(options: seq[(string, string)], name: string): string =
  ## Return a required option value or report a usage error.
  for (key, value) in options:
    if key == name:
      result = value
  if result.len == 0:
    usageError("--" & name & " is required.")

proc optionalOption(options: seq[(string, string)], name: string): string =
  ## Return an option value, or an empty string when absent.
  for (key, value) in options:
    if key == name:
      result = value

proc run(command: string, options: seq[(string, string)]) =
  ## Execute one helper command and print its structured result.
  case command
  of "prepare":
    let
      config = parseJson(readFile(requireOption(options, "config")))
      manifest = prepareButtonMedia(config, requireOption(options, "config-dir"),
        requireOption(options, "cache-dir"), requireOption(options, "font"))
      output = optionalOption(options, "output")
    if output.len > 0:
      writeAtomically(output, $manifest)
    else:
      stdout.writeLine($manifest)
  of "import":
    let path = importButtonAsset(requireOption(options, "source"),
      requireOption(options, "config-dir"))
    stdout.writeLine($(%*{"path": path}))
  else:
    usageError("Unknown command: " & command)

proc main() =
  ## Parse arguments and report failures on stderr with a nonzero status.
  var
    command = ""
    options: seq[(string, string)]
    parser = initOptParser(commandLineParams(), shortNoVal = {'h'},
      longNoVal = @["help"])
  for kind, key, value in parser.getopt():
    case kind
    of cmdArgument:
      if command.len > 0:
        usageError("Unexpected argument: " & key)
      command = key
    of cmdLongOption, cmdShortOption:
      if key in ["h", "help"]:
        stdout.writeLine(Usage)
        quit(0)
      if value.len == 0:
        usageError("--" & key & " needs a value.")
      options.add((key, value))
    of cmdEnd:
      discard
  if command.len == 0:
    usageError("A command is required.")
  try:
    run(command, options)
  except MediaError as error:
    # Expected rejections are reported without a stack trace.
    stderr.writeLine("error: " & error.msg)
    quit(FailureExit)
  except CatchableError as error:
    stderr.writeLine("error: " & error.msg.strip())
    quit(FailureExit)

when isMainModule:
  main()

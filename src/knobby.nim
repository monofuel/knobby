import
  knobby/common

proc appName*(): string =
  ## Return the application name.
  result = AppName

proc daemonDescription*(): string =
  ## Return a short daemon description.
  result = AppDescription

proc run*() =
  ## Start the daemon process.
  discard

when isMainModule:
  run()

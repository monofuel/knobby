import
  std/os,
  knobby/midi_monitor

proc normalizedArgs(args: seq[string]): seq[string] =
  ## Remove CLI separators used by `nim r ... -- ...`.
  for arg in args:
    if arg != "--":
      result.add(arg)

proc main() =
  ## Run the MIDI monitor demo for debugging a controller.
  let args = normalizedArgs(commandLineParams())
  if args.len > 0 and args[0] == "--list":
    listMidiPorts()
  elif args.len > 0 and args[0] == "--help":
    echo midiMonitorUsage()
  elif args.len > 0 and args[0] == "--auto":
    runMidiMonitorAuto()
  elif args.len > 0:
    runMidiMonitor(args[0])
  else:
    runMidiMonitorAuto()

when isMainModule:
  main()

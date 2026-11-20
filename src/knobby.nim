import
  std/[os, posix, strformat],
  knobby/[actions, button_cli, common, daemon_workers, ipc, midi_events, midi_monitor,
    midi_supervisor, razer_lighting, runtime, status]

proc appName*(): string =
  ## Return the application name.
  result = AppName

proc daemonDescription*(): string =
  ## Return a short daemon description.
  result = AppDescription

proc handleMidiLines(lines: seq[string]) =
  ## Record a batch of aseqdump lines and queue its button and fader actions.
  var events: seq[MidiEvent]
  for line in lines:
    events.add(parseMidiEvent(line))
  observeMidi(events)
  try: queueActions(events)
  except IOError as error:
    setComponentError("actions", error.msg)
    stderr.writeLine(error.msg)

proc daemonMidiSupervisor(): MidiSupervisor =
  ## Wire the reconnect loop to ALSA discovery, aseqdump sessions, and shared status.
  MidiSupervisor(
    discover: detectArduinoSeqPort,
    runSession: proc (port: string, onBatch: MidiBatchHandler,
        shouldStop: proc (): bool): int =
      runSeqBatchSession(port, onBatch, shouldStop),
    onBatch: handleMidiLines,
    setPort: setMixerPort,
    wait: proc (ms: int) = waitUnlessStopped(ms, shouldStop, markProgress),
    shouldStop: shouldStop,
    progress: markProgress,
    log: proc (message: string) = echo message)

proc run*() =
  ## Run the daemon: connect to the Arduino MIDI mixer, dispatch its events
  ## to volume and launcher actions, and reconnect locally when the device drops.
  let ownership = acquireOwnership(runtimePath("knobby-owner", "daemon.lock"))
  defer: discard posix.close(ownership)
  installStopHooks()
  startDeviceWorkers()
  defer: stopDeviceWorkers()
  startProgressWatchdog()
  startStreamWatcher()
  startMousepadLighting()
  echo fmt"{AppName}: {AppDescription}"
  superviseMidi(daemonMidiSupervisor())

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "config":
    runButtonConfigCli(args[1..^1])
  elif args.len > 0 and args[0] == "navigation":
    runNavigationCli(args[1..^1])
  elif args == @["--help"]:
    echo "Usage: knobby [config COMMAND | navigation COMMAND]"
    echo configUsage()
    echo navigationUsage()
  elif args.len == 0:
    run()
  else:
    raise newException(ValueError, "Usage: knobby [config COMMAND | navigation COMMAND]")

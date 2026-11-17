import
  std/[os, posix, strformat],
  knobby/[actions, common, daemon_workers, ipc, midi_events, midi_monitor, razer_lighting, runtime, status]

proc appName*(): string =
  ## Return the application name.
  result = AppName

proc daemonDescription*(): string =
  ## Return a short daemon description.
  result = AppDescription

proc run*() =
  ## Run the daemon: connect to the Arduino MIDI mixer, dispatch its events
  ## to volume and launcher actions, and reconnect when the device drops.
  let ownership = acquireOwnership(runtimePath("knobby-owner", "daemon.lock"))
  defer: discard posix.close(ownership)
  installStopHooks()
  startDeviceWorkers()
  defer: stopDeviceWorkers()
  startProgressWatchdog()
  startStreamWatcher()
  startMousepadLighting()
  echo fmt"{AppName}: {AppDescription}"
  while not shouldStop():
    markProgress()
    let port = detectArduinoSeqPort()
    if port.len == 0:
      echo "No Arduino MIDI device detected. Polling again in 1 second."
      sleep(ReconnectPollIntervalMs)
    else:
      setMixerPort(port)
      echo fmt"Connected to Arduino MIDI at {port}."
      let exitCode = runSeqBatchSession(port, proc (lines: seq[string]) =
        var events: seq[MidiEvent]
        for line in lines:
          events.add(parseMidiEvent(line))
        observeMidi(events)
        try: queueActions(events)
        except IOError as error:
          setComponentError("actions", error.msg)
          stderr.writeLine(error.msg), shouldStop)
      setMixerPort("")
      echo fmt"MIDI device at {port} disconnected (aseqdump exit {exitCode}). Retrying in 1 second."
      sleep(ReconnectPollIntervalMs)

when isMainModule:
  run()

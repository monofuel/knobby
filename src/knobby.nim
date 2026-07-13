import
  std/[os, strformat],
  knobby/[actions, common, midi_events, midi_monitor]

proc appName*(): string =
  ## Return the application name.
  result = AppName

proc daemonDescription*(): string =
  ## Return a short daemon description.
  result = AppDescription

proc run*() =
  ## Run the daemon: connect to the Arduino MIDI mixer, dispatch its events
  ## to volume and launcher actions, and reconnect when the device drops.
  let dispatcher = newDispatcher()
  echo fmt"{AppName}: {AppDescription}"
  while true:
    let port = detectArduinoSeqPort()
    if port.len == 0:
      echo "No Arduino MIDI device detected. Polling again in 1 second."
      sleep(ReconnectPollIntervalMs)
    else:
      echo fmt"Connected to Arduino MIDI at {port}."
      let exitCode = runSeqBatchSession(port, proc (lines: seq[string]) =
        var events: seq[MidiEvent]
        for line in lines:
          events.add(parseMidiEvent(line))
        dispatcher.handleBatch(events))
      echo fmt"MIDI device at {port} disconnected (aseqdump exit {exitCode}). Retrying in 1 second."
      sleep(ReconnectPollIntervalMs)

when isMainModule:
  run()

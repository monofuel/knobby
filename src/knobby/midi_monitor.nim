import
  std/[os, osproc, posix, streams, strformat, strutils],
  ./common

const
  DefaultMidiPort* = "32:0"
  ArduinoMicroName = "arduino micro"
  SessionShutdownMs = 1000
  BatchReadLimit = 64
  ReadBufferSize = 4096
  MaxPendingLineBytes = 65536
  MidiPollMs = 100

proc midiMonitorUsage*(): string =
  ## Return usage text for the MIDI monitor demo.
  result = "Usage: nim r examples/midi_monitor.nim [client:port] [--list] [--auto]"

proc ensureToolInstalled(toolName: string) =
  ## Ensure an ALSA command-line tool is available on PATH.
  if findExe(toolName).len == 0:
    raise newException(OSError, fmt"Required tool '{toolName}' was not found on PATH.")

proc listMidiPorts*() =
  ## Print ALSA sequencer clients and ports using aconnect.
  ensureToolInstalled("aconnect")
  let output = runCommand("aconnect", @["-l"])
  echo output

proc parseLeadingNumber(text: string): string =
  ## Return the leading decimal number from a string.
  var i = 0
  while i < text.len and text[i].isDigit:
    inc(i)
  if i > 0:
    result = text[0..<i]

proc detectArduinoSeqPort*(): string =
  ## Detect Arduino Micro ALSA sequencer port in client:port format.
  ensureToolInstalled("aconnect")
  let output = runAudioCommand("aconnect", @["-l"])

  var currentClient = ""
  var isArduinoClient = false
  for line in output.splitLines():
    let lowered = line.toLowerAscii()
    if line.startsWith("client "):
      let content = line["client ".len..^1]
      let clientId = parseLeadingNumber(content)
      currentClient = clientId
      isArduinoClient = lowered.contains(ArduinoMicroName) or lowered.contains("arduino")
    elif isArduinoClient and currentClient.len > 0:
      let stripped = line.strip()
      let portId = parseLeadingNumber(stripped)
      if portId.len > 0:
        result = fmt"{currentClient}:{portId}"
        break

proc detectArduinoAmidiPort*(): string =
  ## Detect Arduino Micro raw MIDI port in amidi hw:X,Y,Z format.
  ensureToolInstalled("amidi")
  let output = runAudioCommand("amidi", @["-l"])

  for line in output.splitLines():
    let lowered = line.toLowerAscii()
    if lowered.contains(ArduinoMicroName) or lowered.contains("arduino"):
      for token in line.splitWhitespace():
        if token.startsWith("hw:"):
          result = token
          break
    if result.len > 0:
      break

proc runSeqBatchSession*(port: string, onBatch: proc (lines: seq[string]),
    shouldStop: proc (): bool = nil): int =
  ## Poll MIDI output in bounded batches with session-local buffering.
  let monitor = spawnCommand("aseqdump", @["-p", port])
  defer:
    if running(monitor):
      kill(monitor)
    discard waitForExit(monitor)
    close(monitor)
  let handle = monitor.outputHandle.cint
  let flags = fcntl(handle, F_GETFL, 0)
  if flags < 0 or fcntl(handle, F_SETFL, flags or O_NONBLOCK) < 0:
    raiseOSError(osLastError())
  var
    pending = ""
    buffer: array[ReadBufferSize, char]
    finished = false
  while not finished and (shouldStop.isNil or not shouldStop()):
    markProgress()
    var descriptor = TPollfd(fd: handle, events: POLLIN)
    let ready = poll(addr descriptor, Tnfds(1), MidiPollMs)
    if ready < 0:
      if errno == EINTR:
        continue
      raiseOSError(osLastError())
    if ready == 0:
      continue
    var lines: seq[string]
    for attempt in 0..<BatchReadLimit:
      let size = posix.read(handle, addr buffer[0], buffer.len)
      if size == 0:
        finished = true
        break
      if size < 0:
        if errno == EINTR:
          continue
        if errno == EAGAIN:
          break
        raiseOSError(osLastError())
      for index in 0..<int(size):
        if buffer[index] == '\n':
          lines.add(pending)
          if pending.toLowerAscii().contains("port unsubscribed"):
            finished = true
          pending.setLen(0)
        else:
          pending.add(buffer[index])
          if pending.len > MaxPendingLineBytes:
            raise newException(IOError, "MIDI output line exceeds size limit.")
      if finished:
        break
    if finished and pending.len > 0:
      lines.add(pending)
    if lines.len > 0:
      onBatch(lines)
  if running(monitor):
    terminate(monitor)
  result = waitForExit(monitor, SessionShutdownMs)

proc runSeqSession*(port: string, onLine: proc (line: string)): int =
  ## Deliver individual lines using the same bounded session lifecycle.
  result = runSeqBatchSession(port, proc (lines: seq[string]) =
    for line in lines:
      onLine(line))

proc runSeqMonitorSession(port: string): int =
  ## Stream MIDI events from a sequencer port and echo each line.
  result = runSeqSession(port, proc (line: string) = echo line)

proc runAmidiMonitorSession(port: string): int =
  ## Stream raw MIDI bytes from a hardware port until the process exits.
  let monitor = spawnCommand("amidi", @["-p", port, "-d"])

  var line: string
  while monitor.outputStream.readLine(line):
    echo line

  result = waitForExit(monitor)
  close(monitor)

proc runMidiMonitor*(port: string = DefaultMidiPort) =
  ## Stream MIDI events from an explicit ALSA sequencer port and reconnect when disconnected.
  ensureToolInstalled("aseqdump")

  while true:
    echo fmt"Monitoring ALSA sequencer port {port}."
    let exitCode = runSeqMonitorSession(port)
    echo fmt"MIDI device at {port} disconnected (aseqdump exit {exitCode}). Retrying in 1 second."
    sleep(ReconnectPollIntervalMs)

proc runMidiMonitorAuto*() =
  ## Detect an Arduino Micro MIDI port, wait when unavailable, and reconnect after disconnects.
  let hasSeqTools = findExe("aconnect").len > 0 and findExe("aseqdump").len > 0
  let hasAmidi = findExe("amidi").len > 0

  if not hasSeqTools and not hasAmidi:
    raise newException(
      OSError,
      "Could not auto-detect an Arduino Micro MIDI port because required tools are unavailable. Install aconnect+aseqdump or amidi."
    )

  while true:
    if hasSeqTools:
      let seqPort = detectArduinoSeqPort()
      if seqPort.len > 0:
        echo fmt"Auto-detected Arduino sequencer port: {seqPort}"
        let exitCode = runSeqMonitorSession(seqPort)
        echo fmt"MIDI device at {seqPort} disconnected (aseqdump exit {exitCode}). Retrying discovery in 1 second."
        sleep(ReconnectPollIntervalMs)
        continue

    if hasAmidi:
      let amidiPort = detectArduinoAmidiPort()
      if amidiPort.len > 0:
        echo fmt"Auto-detected Arduino raw MIDI port: {amidiPort}"
        let exitCode = runAmidiMonitorSession(amidiPort)
        echo fmt"MIDI device at {amidiPort} disconnected (amidi exit {exitCode}). Retrying discovery in 1 second."
        sleep(ReconnectPollIntervalMs)
        continue

    echo "No Arduino MIDI device detected. Polling again in 1 second."
    sleep(ReconnectPollIntervalMs)

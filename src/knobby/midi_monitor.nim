import
  std/[os, osproc, posix, streams, strformat, strutils],
  ./common

const
  DefaultMidiPort* = "32:0"
  ArduinoMicroName = "arduino micro"
  SessionEndMarker = "\x04knobby-session-end"

var seqLineChannel: Channel[string]

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
  let output = execProcess(
    "aconnect",
    args = @["-l"],
    options = {poUsePath, poStdErrToStdOut}
  )
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
  let output = execProcess(
    "aconnect",
    args = @["-l"],
    options = {poUsePath, poStdErrToStdOut}
  )

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
  let output = execProcess(
    "amidi",
    args = @["-l"],
    options = {poUsePath, poStdErrToStdOut}
  )

  for line in output.splitLines():
    let lowered = line.toLowerAscii()
    if lowered.contains(ArduinoMicroName) or lowered.contains("arduino"):
      for token in line.splitWhitespace():
        if token.startsWith("hw:"):
          result = token
          break
    if result.len > 0:
      break

proc runSeqSession*(port: string, onLine: proc (line: string)): int =
  ## Stream MIDI event lines from a sequencer port to a callback until the
  ## process exits or the port unsubscribes.
  let monitor = startProcess(
    "aseqdump",
    args = @["-p", port],
    options = {poUsePath, poStdErrToStdOut}
  )

  var line: string
  var sawUnsubscribe = false
  while monitor.outputStream.readLine(line):
    onLine(line)
    if line.toLowerAscii().contains("port unsubscribed"):
      sawUnsubscribe = true
      break

  if sawUnsubscribe:
    terminate(monitor)

  result = waitForExit(monitor)
  close(monitor)

proc runSeqMonitorSession(port: string): int =
  ## Stream MIDI events from a sequencer port and echo each line.
  result = runSeqSession(port, proc (line: string) = echo line)

proc readSeqLines(outputHandle: FileHandle) {.thread.} =
  ## Forward aseqdump output lines to the session channel until EOF.
  var file: File
  if open(file, outputHandle, fmRead):
    var line: string
    while file.readLine(line):
      seqLineChannel.send(line)
    close(file)
  seqLineChannel.send(SessionEndMarker)

proc runSeqBatchSession*(port: string, onBatch: proc (lines: seq[string])): int =
  ## Stream MIDI event lines in drained batches until the process exits or the
  ## port unsubscribes. Lines that arrive while a batch is being handled are
  ## delivered together in the next batch, so slow handlers see bursts of
  ## events at once instead of falling behind one line at a time.
  let monitor = startProcess(
    "aseqdump",
    args = @["-p", port],
    options = {poUsePath, poStdErrToStdOut}
  )
  open(seqLineChannel)
  var reader: Thread[FileHandle]
  createThread(reader, readSeqLines, FileHandle(dup(monitor.outputHandle.cint)))

  var sessionOver = false
  while not sessionOver:
    var lines: seq[string]
    let first = seqLineChannel.recv()
    if first == SessionEndMarker:
      sessionOver = true
    else:
      lines.add(first)
      var draining = true
      while draining:
        let (received, line) = seqLineChannel.tryRecv()
        if not received:
          draining = false
        elif line == SessionEndMarker:
          sessionOver = true
          draining = false
        else:
          lines.add(line)

      var sawUnsubscribe = false
      for line in lines:
        if line.toLowerAscii().contains("port unsubscribed"):
          sawUnsubscribe = true
      onBatch(lines)
      if sawUnsubscribe:
        terminate(monitor)
        sessionOver = true

  result = waitForExit(monitor)
  close(monitor)
  joinThread(reader)
  close(seqLineChannel)

proc runAmidiMonitorSession(port: string): int =
  ## Stream raw MIDI bytes from a hardware port until the process exits.
  let monitor = startProcess(
    "amidi",
    args = @["-p", port, "-d"],
    options = {poUsePath, poStdErrToStdOut}
  )

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

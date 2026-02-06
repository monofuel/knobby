import
  std/[os, osproc, streams, strformat, strutils]

const
  DefaultMidiPort* = "32:0"
  ArduinoMicroName = "arduino micro"

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

proc runSeqMonitor(port: string) =
  ## Stream MIDI events from a specific ALSA sequencer port with aseqdump.
  ensureToolInstalled("aseqdump")
  let monitor = startProcess(
    "aseqdump",
    args = @["-p", port],
    options = {poUsePath, poStdErrToStdOut}
  )
  defer:
    close(monitor)

  var line: string
  while monitor.outputStream.readLine(line):
    echo line

  let exitCode = waitForExit(monitor)
  if exitCode != 0:
    raise newException(OSError, fmt"aseqdump exited with status {exitCode}.")

proc runAmidiMonitor(port: string) =
  ## Stream raw MIDI bytes from a specific amidi hardware port.
  ensureToolInstalled("amidi")
  let monitor = startProcess(
    "amidi",
    args = @["-p", port, "-d"],
    options = {poUsePath, poStdErrToStdOut}
  )
  defer:
    close(monitor)

  var line: string
  while monitor.outputStream.readLine(line):
    echo line

  let exitCode = waitForExit(monitor)
  if exitCode != 0:
    raise newException(OSError, fmt"amidi exited with status {exitCode}.")

proc runMidiMonitor*(port: string = DefaultMidiPort) =
  ## Stream MIDI events from an explicit ALSA sequencer port.
  runSeqMonitor(port)

proc runMidiMonitorAuto*() =
  ## Detect an Arduino Micro MIDI port and stream events.
  if findExe("aconnect").len > 0 and findExe("aseqdump").len > 0:
    let seqPort = detectArduinoSeqPort()
    if seqPort.len > 0:
      echo fmt"Auto-detected Arduino sequencer port: {seqPort}"
      runSeqMonitor(seqPort)
      return

  if findExe("amidi").len > 0:
    let amidiPort = detectArduinoAmidiPort()
    if amidiPort.len > 0:
      echo fmt"Auto-detected Arduino raw MIDI port: {amidiPort}"
      runAmidiMonitor(amidiPort)
      return

  raise newException(
    OSError,
    "Could not auto-detect an Arduino Micro MIDI port. Run with --list or pass client:port."
  )

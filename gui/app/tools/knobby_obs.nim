import
  std/[asyncdispatch, json, os, posix, strutils],
  knobby/common,
  obs_client, obs_workspace

const
  Usage = """Usage:
  knobby_obs request REQUEST [JSON]   Run one OBS request and print responseData.
  knobby_obs bridge                   Bridge stdin commands to OBS status lines."""
  MaxFrameBytes = 1024 * 1024
  ReadChunkBytes = 65536
  PollMs = 25
  ObsProcessNames = ["obs", ".obs-wrapped"]
  ObsWindowClass = "obs"
  UsageExitCode = 2

type
  StdinMessageKind = enum
    StdinLine, StdinOversized, StdinEnd

  StdinMessage = object
    kind: StdinMessageKind
    line: string

var stdinChannel: Channel[StdinMessage]

proc readStdin() {.thread.} =
  ## Split stdin into lines, replacing any line over 1 MiB with a rejection marker.
  var
    buffer: array[ReadChunkBytes, char]
    line = ""
    oversized = false
  while true:
    let count = posix.read(STDIN_FILENO, addr buffer[0], buffer.len)
    if count < 0 and errno == EINTR:
      continue
    if count <= 0:
      break
    for index in 0..<int(count):
      let character = buffer[index]
      if character == '\n':
        if oversized:
          stdinChannel.send(StdinMessage(kind: StdinOversized))
        elif line.len > 0:
          stdinChannel.send(StdinMessage(kind: StdinLine, line: move(line)))
        line = ""
        oversized = false
      elif not oversized:
        if line.len >= MaxFrameBytes:
          oversized = true
          line = ""
        else:
          line.add(character)
  stdinChannel.send(StdinMessage(kind: StdinEnd))

proc obsRunning(): bool {.gcsafe.} =
  ## Check /proc for a running OBS process.
  for kind, path in walkDir("/proc"):
    if kind == pcDir and path.lastPathPart.allCharsInSet(Digits):
      try:
        if readFile(path / "comm").strip() in ObsProcessNames:
          return true
      except IOError:
        # Processes may exit between listing and reading.
        discard

proc launchObs() {.gcsafe.} =
  ## Start OBS on the Minecraft project as an independent user service.
  discard runAudioCommand("systemd-run", @["--user", "--collect", "--quiet",
    "--property=Type=exec", "--property=StandardInput=null",
    "--property=StandardOutput=null", "--property=StandardError=null",
    "--", "obs", "--profile", ObsProfileName, "--collection", ObsCollectionName,
    "--scene", ObsSceneName])

proc focusObs() {.gcsafe.} =
  ## Raise the existing OBS window.
  discard runAudioCommand("wmctrl", @["-x", "-a", ObsWindowClass])

proc emitLine(line: JsonNode) {.gcsafe.} =
  ## Write one protocol line to stdout.
  stdout.writeLine($line)
  stdout.flushFile()

proc logLine(message: string) {.gcsafe.} =
  ## Write one diagnostic to stderr.
  stderr.writeLine("knobby_obs: " & message)

proc runRequest(requestType: string, data: JsonNode) =
  ## Authenticate, execute one request, and print only its responseData.
  let
    settings = loadObsSettings()
    client = waitFor connectObs(settings.url, settings.password)
    response = waitFor client.request(requestType, data)
  client.close()
  stdout.writeLine($response)

proc runBridge() =
  ## Bridge stdin commands to OBS until stdin closes.
  stdinChannel.open(MaxCommandBacklog)
  var reader: Thread[void]
  createThread(reader, readStdin)
  let bridge = newObsBridge(ObsHooks(
    loadSettings: proc (): tuple[url, password: string] {.gcsafe.} =
      loadObsSettings(),
    obsRunning: obsRunning,
    launchObs: launchObs,
    focusObs: focusObs,
    emit: emitLine,
    log: logLine
  ))
  bridge.start()
  var running = true
  while running:
    poll(PollMs)
    while running:
      let received = stdinChannel.tryRecv()
      if not received.dataAvailable:
        break
      case received.msg.kind
      of StdinLine:
        bridge.submitLine(received.msg.line)
      of StdinOversized:
        emitLine(resultJson(nil, "Command exceeds 1 MiB."))
      of StdinEnd:
        running = false
  bridge.stop()
  joinThread(reader)

proc main() =
  ## Dispatch the request and bridge subcommands.
  let args = commandLineParams()
  if args.len >= 2 and args.len <= 3 and args[0] == "request":
    runRequest(args[1], if args.len == 3: parseJson(args[2]) else: nil)
  elif args == @["bridge"]:
    runBridge()
  else:
    stderr.writeLine(Usage)
    quit(UsageExitCode)

when isMainModule:
  main()

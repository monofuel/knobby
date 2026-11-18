import
  std/[asyncdispatch, json, os, posix, strutils],
  knobby/common,
  obs_client, obs_workspace, obs_targets, minecraft_window

const
  Usage = """Usage:
  knobby_obs request REQUEST [JSON]   Run one OBS request and print responseData.
  knobby_obs bridge                   Bridge stdin commands to OBS status lines."""
  MaxFrameBytes = 1024 * 1024
  ReadChunkBytes = 65536
  PollMs = 25
  ObsProcessNames = ["obs", ".obs-wrapped"]
  ObsWindowClass = "obs"
  PrismProcessNames = ["prismlauncher"]
  PrismClassName = "prismlauncher"
  PrismScript = "bin/prism"
  PrismUnit = "knobby-prism.service"
  PendingUnitStates = ["active", "activating", "reloading"]
  # The kernel truncates /proc/PID/comm to 15 bytes.
  ProcessNameBytes = 15
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

proc processRunning(names: openArray[string]): bool {.gcsafe.} =
  ## Check /proc for a process whose kernel name matches one of names.
  for kind, path in walkDir("/proc"):
    if kind == pcDir and path.lastPathPart.allCharsInSet(Digits):
      try:
        let comm = readFile(path / "comm").strip()
        for name in names:
          if comm == name[0 ..< min(name.len, ProcessNameBytes)]:
            return true
      except IOError:
        # Processes may exit between listing and reading.
        discard

proc obsRunning(): bool {.gcsafe.} =
  ## Check /proc for a running OBS process, independent of its WebSocket.
  processRunning(ObsProcessNames)

proc prismWindow(): string {.gcsafe.} =
  ## Return the X11 id of a Prism Launcher window, or "" when none is mapped.
  for window in listClientWindows():
    if result.len == 0 and (PrismClassName in window.instance.toLowerAscii() or
        PrismClassName in window.class.toLowerAscii()):
      result = windowLabel(window.id)

proc prismLaunchPending(): bool {.gcsafe.} =
  ## Report whether the Knobby-started Prism unit is still starting or running.
  let state = runAudioCommand("systemctl", @["--user", "show",
    "--property=ActiveState", "--value", PrismUnit]).strip()
  state in PendingUnitStates

proc launchPrism() {.gcsafe.} =
  ## Focus Prism Launcher, leave a pending launch alone, or start ~/bin/prism detached.
  ## No instance is selected; the user picks the modpack in Prism. The transient
  ## unit gets the user manager's environment rather than this helper's packaged
  ## PATH and libraries, and the game survives Prism exiting.
  let window = prismWindow()
  if window.len > 0:
    discard runAudioCommand("wmctrl", @["-i", "-a", window])
  elif not processRunning(PrismProcessNames) and not prismLaunchPending():
    discard runAudioCommand("systemd-run", @["--user", "--collect", "--quiet",
      "--unit=" & PrismUnit, "--property=Type=exec", "--property=KillMode=process",
      "--property=StandardInput=null", "--property=StandardOutput=null",
      "--property=StandardError=null", "--", getHomeDir() / PrismScript])

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
    minecraftState: minecraftWindowState,
    launchPrism: launchPrism,
    resizeMinecraft: resizeMinecraftWindow,
    audioTarget: minecraftAudioTarget,
    videoTarget: minecraftVideoTarget,
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

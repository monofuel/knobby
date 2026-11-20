import
  std/[os, strformat, strutils, tables],
  knobby/[common, firefox_demo_config],
  ./[minecraft_audio, minecraft_window, obs_client]

type
  FirefoxDemoError* = object of ObsError
    ## Raised when the dedicated Firefox demo cannot be identified, isolated, or opened.

const
  FirefoxDemoUnit* = "knobby-firefox-demos.service"
  # Firefox uses this as its remoting name and, on X11, as the WM_CLASS class.
  RemotingVariable* = "MOZ_APP_REMOTINGNAME"
  # libpulse replaces client properties from this proplist for every process in the tree.
  PulseOverrideVariable* = "PULSE_PROP_OVERRIDE"
  # The demo must be an X11 client so OBS window capture and WM_CLASS identity apply.
  WaylandVariable = "MOZ_ENABLE_WAYLAND"
  DemoSubject = "Firefox demo"
  PendingUnitStates = ["active", "activating", "reloading"]
  # Names that also identify ordinary Firefox windows or audio streams.
  GenericFirefoxNames = ["firefox", "firefox-bin", "firefox-esr", ".firefox-wrapped",
    "firefox-wrapped", "navigator", "mozilla firefox", "toolkit", "dialog"]
  IdentityChars = {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}
  # Ordinary Firefox profile roots below the home directory.
  NormalProfileRoots = [".mozilla", ".config/mozilla"]
  MaxProcessDepth = 64
  StatParentField = 1

proc demoError(message: string): ref FirefoxDemoError =
  ## Build a Firefox demo error.
  newException(FirefoxDemoError, message)

proc isGenericFirefoxName(name: string): bool =
  ## Report whether a class or audio label would also match ordinary Firefox.
  for generic in GenericFirefoxNames:
    if cmpIgnoreCase(name, generic) == 0: return true

proc requireIdentity(name, field: string) =
  ## Require a distinctive window class or audio label made of safe characters.
  if name.len == 0 or not name.allCharsInSet(IdentityChars):
    raise demoError(&"Firefox demo {field} \"{name}\" must use only letters, digits, '.', '-', or '_'.")
  if isGenericFirefoxName(name):
    raise demoError(&"Firefox demo {field} \"{name}\" would also match ordinary Firefox.")

proc validateFirefoxDemoConfig*(config: FirefoxDemoConfig, home = getHomeDir()) =
  ## Refuse settings that could select, capture, or modify an ordinary Firefox session.
  requireIdentity(config.windowClass, "windowClass")
  requireIdentity(config.audioLabel, "audioLabel")
  if config.executable.strip().len == 0:
    raise demoError("Firefox demo executable is empty.")
  if config.startUrl.startsWith("-"):
    raise demoError("Firefox demo startUrl must not look like a command-line option.")
  if not config.profileDirectory.isAbsolute:
    raise demoError("Firefox demo profileDirectory must be absolute.")
  let profile = config.profileDirectory.normalizedPath()
  for root in NormalProfileRoots:
    let normal = (home / root).normalizedPath()
    if profile == normal or profile.isRelativeTo(normal):
      raise demoError(&"Firefox demo profileDirectory {profile} is inside the normal " &
        &"Firefox profiles at {normal}.")

proc loadDemoConfig*(): FirefoxDemoConfig =
  ## Load and validate the shared Firefox demo settings, reporting bad files as demo errors.
  try:
    result = loadFirefoxDemoConfig()
  except ValueError, IOError, OSError:
    # JSON and validation failures become one-line OBS status errors.
    raise demoError("Firefox demo settings " & firefoxDemoConfigPath() & ": " &
      getCurrentExceptionMsg())
  validateFirefoxDemoConfig(result)

proc isFirefoxDemoWindow*(window: ClientWindow, config: FirefoxDemoConfig): bool =
  ## Match only the exact configured X11 class; titles and ordinary Firefox classes never count.
  window.class == config.windowClass

proc demoWindows(windows: openArray[ClientWindow], config: FirefoxDemoConfig): seq[ClientWindow] =
  ## List client windows carrying the dedicated demo identity.
  for window in windows:
    if isFirefoxDemoWindow(window, config): result.add(window)

proc selectFirefoxDemoWindow*(windows: openArray[ClientWindow],
    config: FirefoxDemoConfig): ClientWindow =
  ## Choose the single demo window, raising when none or several carry the identity.
  let matches = demoWindows(windows, config)
  if matches.len == 0:
    raise demoError(&"The Firefox demo window (class \"{config.windowClass}\") is not open.")
  if matches.len > 1:
    var labels: seq[string]
    for window in matches: labels.add(window.describe())
    raise demoError(&"Found {matches.len} Firefox demo windows; refusing to guess between " &
      labels.join(", ") & ".")
  matches[0]

proc firefoxDemoPresence*(windows: openArray[ClientWindow],
    config: FirefoxDemoConfig): tuple[running, sized: bool] =
  ## Report whether the demo window exists and whether exactly one is at 1920x1080.
  let matches = demoWindows(windows, config)
  result.running = matches.len > 0
  result.sized = matches.len == 1 and matches[0].width == TargetWidth and
    matches[0].height == TargetHeight and
    matches[0].states * {wsFullscreen, wsMaximizedVert, wsMaximizedHorz} == {}

proc xcompositeValue*(window: ClientWindow): string =
  ## Encode a client for OBS window capture as id, title, and class lines.
  $window.id & "\r\n" & window.title & "\r\n" & window.class

proc parseProcessParent*(stat: string): int =
  ## Read the parent PID from /proc/PID/stat text, whose command name may contain spaces.
  let close = stat.rfind(')')
  if close < 0:
    raise newException(ValueError, "Malformed process status.")
  let fields = stat[close + 1 .. ^1].splitWhitespace()
  if fields.len <= StatParentField:
    raise newException(ValueError, "Malformed process status.")
  parseInt(fields[StatParentField])

proc readProcessParents*(): Table[int, int] =
  ## Snapshot parent PIDs for every visible process.
  for kind, path in walkDir("/proc"):
    let name = path.lastPathPart
    if kind == pcDir and name.len > 0 and name.allCharsInSet(Digits):
      let statPath = path / "stat"
      # Processes may exit between listing and reading.
      if fileExists(statPath):
        var text = ""
        try:
          text = readFile(statPath)
        except IOError:
          continue
        result[parseInt(name)] = parseProcessParent(text)

proc inProcessTree*(parents: Table[int, int], pid, root: int): bool =
  ## Report whether pid is root or one of its descendants.
  var current = pid
  for _ in 0..MaxProcessDepth:
    if current == root: return true
    if current <= 1 or current notin parents: return false
    current = parents[current]

proc firefoxAudioOverride*(label: string): string =
  ## Return the libpulse property override that labels every demo audio stream.
  "application.name='" & label & "'"

proc hasFirefoxAudioLabel*(environ, label: string): bool =
  ## Report whether NUL-separated process environment data carries the demo audio label.
  (PulseOverrideVariable & "=" & firefoxAudioOverride(label)) in environ.split('\0')

proc verifyFirefoxAudioTarget*(graph: AppAudioGraph, parents: Table[int, int],
    demoPid: int, label: string, labelProven: bool): seq[AppStream] =
  ## Return the demo's streams when the label captures exactly the demo process tree.
  ## Raise when the label would capture another process or miss a demo stream. A
  ## silent demo is accepted only when its launch environment proves the label.
  if demoPid <= 0:
    raise demoError("The Firefox demo window has no process ID.")
  requireIdentity(label, "audioLabel")
  for stream in graph.streams:
    let
      targeted = graph.isTargeted(stream, label)
      ours = stream.processId > 0 and parents.inProcessTree(stream.processId, demoPid)
    if targeted and not ours:
      raise demoError(&"Audio label {label} also captures {stream.appName} " &
        &"(PID {stream.processId}) outside the Firefox demo.")
    if ours and not targeted:
      raise demoError(&"Firefox demo audio ({stream.appName}) is not labeled {label}; " &
        "relaunch the demo from Knobby.")
    if targeted:
      result.add(stream)
  if result.len == 0 and not labelProven:
    raise demoError(&"The Firefox demo (PID {demoPid}) was not launched with audio label " &
      &"{label}; close it and open it from Knobby.")

proc firefoxLaunchArgs*(config: FirefoxDemoConfig): seq[string] =
  ## Build the systemd-run arguments for a separate demo instance and profile.
  ## The distinct remoting name keeps Firefox from joining an ordinary instance
  ## and gives the X11 windows the configured class.
  @["--user", "--collect", "--quiet", "--unit=" & FirefoxDemoUnit,
    "--property=Type=exec", "--property=StandardInput=null",
    "--property=StandardOutput=null", "--property=StandardError=null",
    "--setenv=" & RemotingVariable & "=" & config.windowClass,
    "--setenv=" & WaylandVariable & "=0",
    "--setenv=" & PulseOverrideVariable & "=" & firefoxAudioOverride(config.audioLabel),
    "--", config.executable, "--new-instance", "--profile", config.profileDirectory,
    config.startUrl]

proc launchPending(): bool =
  ## Report whether the Knobby-started demo unit is still starting or running.
  let state = runAudioCommand("systemctl", @["--user", "show",
    "--property=ActiveState", "--value", FirefoxDemoUnit]).strip()
  state in PendingUnitStates

proc launchFirefoxDemo*() {.gcsafe.} =
  ## Start the dedicated demo unless its window or a pending launch already exists.
  let config = loadDemoConfig()
  if demoWindows(listClientWindows(), config).len == 0 and not launchPending():
    if not dirExists(config.profileDirectory):
      createDir(config.profileDirectory)
      setFilePermissions(config.profileDirectory, {fpUserRead, fpUserWrite, fpUserExec})
    discard runAudioCommand("systemd-run", firefoxLaunchArgs(config))

proc resizeFirefoxDemo*() {.gcsafe.} =
  ## Resize the single demo window to 1920x1080, or focus it once it already is.
  ## Resizing never moves focus; only the demo window is ever touched.
  let
    config = loadDemoConfig()
    windows = listClientWindows()
    window = selectFirefoxDemoWindow(windows, config)
  if firefoxDemoPresence(windows, config).sized:
    discard runAudioCommand("wmctrl", @["-i", "-a", windowLabel(window.id)])
  else:
    let select = proc (candidates: openArray[ClientWindow]): ClientWindow {.closure, gcsafe.} =
      result = selectFirefoxDemoWindow(candidates, config)
      if result.id != window.id:
        raise demoError("The Firefox demo window changed before resizing.")
    discard resizeSelected1080(select, DemoSubject)

proc firefoxDemoState*(): tuple[running, sized: bool] {.gcsafe.} =
  ## Read demo window presence and size from the X11 client list.
  try:
    result = firefoxDemoPresence(listClientWindows(), loadDemoConfig())
  except MinecraftWindowError:
    raise demoError(getCurrentExceptionMsg())

proc firefoxDemoVideoTarget*(): string {.gcsafe.} =
  ## Encode the single demo window for OBS, "" when absent, raising when ambiguous.
  try:
    let
      config = loadDemoConfig()
      windows = listClientWindows()
    if demoWindows(windows, config).len > 0:
      result = xcompositeValue(selectFirefoxDemoWindow(windows, config))
  except MinecraftWindowError:
    raise demoError(getCurrentExceptionMsg())

proc firefoxDemoAudioTarget*(): tuple[target: string, pending: bool] {.gcsafe.} =
  ## Verify the demo audio label captures only the demo process tree.
  ## pending reports a proven label whose page has not played sound yet.
  try:
    let
      config = loadDemoConfig()
      window = selectFirefoxDemoWindow(listClientWindows(), config)
      environPath = "/proc" / $window.processId / "environ"
      proven = window.processId > 0 and fileExists(environPath) and
        hasFirefoxAudioLabel(readFile(environPath), config.audioLabel)
      graph = parseAppAudioGraph(runAudioCommand("pw-dump", @[]))
      streams = verifyFirefoxAudioTarget(graph, readProcessParents(), window.processId,
        config.audioLabel, proven)
    result = (config.audioLabel, streams.len == 0)
  except MinecraftWindowError, MinecraftAudioError, ValueError, OSError, IOError:
    raise demoError(getCurrentExceptionMsg())

import
  std/[os, strformat, strutils, tables],
  knobby/common,
  ./[firefox_demo, minecraft_audio, minecraft_window, obs_client]

type
  WowCaptureError* = object of ObsError
    ## Raised when the WoW client cannot be identified exactly or its audio is not isolated.

  WowClientKind* = enum
    ClassicClient, NativeClient

  WowWindow* = object
    ## One client window proven to be a supported WoW game.
    window*: ClientWindow
    kind*: WowClientKind

const
  # Wine names the X11 class after the executable and keeps the game's own title.
  ClassicWindowClass* = "wow.exe"
  ClassicWindowTitle* = "World of Warcraft"
  # The native player sets only _NET_WM_NAME, so its process comes from the X server.
  NativeWindowTitle* = "Vanilla WoW Player"
  NativeExecutable* = "player"
  # Names shared by unrelated Wine programs or every OpenAL application.
  GenericAudioNames = ["wine", "wine64", "wine-preloader", "wine64-preloader", "wineserver",
    "openal soft"]
  WowSubject = "WoW"

proc wowError(message: string): ref WowCaptureError =
  ## Build a WoW capture error.
  newException(WowCaptureError, message)

proc isClassicWindow*(window: ClientWindow): bool =
  ## Match the Wine Classic client by its exact class pair and title.
  window.instance == ClassicWindowClass and window.class == ClassicWindowClass and
    window.title == ClassicWindowTitle

proc isNativeTitle(window: ClientWindow): bool =
  ## Match the native player's exact title; the process check happens separately.
  window.title == NativeWindowTitle

proc wowCandidates*(windows: openArray[ClientWindow], executables: Table[int, string]):
    tuple[verified: seq[WowWindow], unverified: seq[ClientWindow]] =
  ## Split windows into proven WoW clients and native-titled windows without a process.
  ## Native windows count only when their process executable is the native player;
  ## titled windows from other programs, such as browsers, are ignored.
  for window in windows:
    if isClassicWindow(window):
      result.verified.add(WowWindow(window: window, kind: ClassicClient))
    elif isNativeTitle(window) and window.instance.len == 0 and window.class.len == 0:
      if window.processId <= 0:
        if window.class.len == 0: result.unverified.add(window)
      elif executables.getOrDefault(window.processId) == NativeExecutable:
        result.verified.add(WowWindow(window: window, kind: NativeClient))

proc selectWowWindow*(windows: openArray[ClientWindow],
    executables: Table[int, string]): WowWindow =
  ## Choose the single proven WoW client, refusing absence, ambiguity, and missing PIDs.
  let candidates = wowCandidates(windows, executables)
  if candidates.verified.len + candidates.unverified.len > 1:
    var labels: seq[string]
    for candidate in candidates.verified: labels.add(candidate.window.describe())
    for window in candidates.unverified: labels.add(window.describe())
    raise wowError(&"Found {labels.len} WoW clients; refusing to guess between " &
      labels.join(", ") & ".")
  if candidates.unverified.len == 1:
    raise wowError(&"The \"{NativeWindowTitle}\" window has no process ID; Knobby needs " &
      "the X server's XRes client lookup (libXRes) to verify it.")
  if candidates.verified.len == 0:
    raise wowError("The WoW client window is not open.")
  result = candidates.verified[0]
  if result.window.processId <= 0:
    raise wowError(&"WoW window {result.window.describe()} has no process ID.")

proc wowPresence*(windows: openArray[ClientWindow],
    executables: Table[int, string]): tuple[running, sized: bool] =
  ## Report whether a proven WoW client exists and whether exactly one is at 1920x1080.
  let candidates = wowCandidates(windows, executables)
  result.running = candidates.verified.len > 0
  result.sized = candidates.verified.len == 1 and candidates.unverified.len == 0 and
    candidates.verified[0].window.width == TargetWidth and
    candidates.verified[0].window.height == TargetHeight and
    candidates.verified[0].window.states * {wsFullscreen, wsMaximizedVert, wsMaximizedHorz} == {}

proc verifyWowAudio*(graph: AppAudioGraph, parents: Table[int, int],
    gamePid: int): tuple[target: string, pending: bool] =
  ## Choose the game's own application name when it captures exactly the game's process tree.
  ## A silent game is pending with no target, so nothing is captured until it plays sound.
  if gamePid <= 0:
    raise wowError("The WoW client has no process ID.")
  var ours: seq[AppStream]
  for stream in graph.streams:
    if stream.processId > 0 and parents.inProcessTree(stream.processId, gamePid):
      ours.add(stream)
  if ours.len == 0:
    result = ("", true)
  else:
    let selection = ours[0].appName
    if selection.strip().len == 0 or selection.toLowerAscii() in GenericAudioNames:
      raise wowError(&"WoW audio is named \"{selection}\", which would also capture other programs.")
    for stream in ours:
      if not graph.isTargeted(stream, selection):
        raise wowError(&"WoW audio streams use different names (\"{selection}\" and " &
          &"\"{stream.appName}\"); refusing to capture only part of the game.")
    for stream in graph.streams:
      if graph.isTargeted(stream, selection) and stream notin ours:
        raise wowError(&"WoW audio name \"{selection}\" also captures {stream.appName} " &
          &"(PID {stream.processId}).")
    result = (selection, false)

proc processExecutable(pid: int): string =
  ## Return the executable file name of a live process, or "" when it cannot be read.
  try:
    result = expandSymlink("/proc" / $pid / "exe").lastPathPart
  except OSError:
    # The process may have exited or belong to another user.
    result = ""

proc nativeExecutables(windows: openArray[ClientWindow]): Table[int, string] =
  ## Read executables only for windows carrying the native player's title.
  for window in windows:
    if isNativeTitle(window) and window.processId > 0:
      result[window.processId] = processExecutable(window.processId)

proc currentWowWindow(windows: openArray[ClientWindow]): WowWindow =
  ## Select the single WoW client from a live window snapshot.
  selectWowWindow(windows, nativeExecutables(windows))

proc wowState*(): tuple[running, sized: bool] {.gcsafe.} =
  ## Read WoW client presence and size from the X11 client list.
  try:
    let windows = listClientWindows()
    result = wowPresence(windows, nativeExecutables(windows))
  except MinecraftWindowError:
    raise wowError(getCurrentExceptionMsg())

proc wowVideoTarget*(): string {.gcsafe.} =
  ## Encode the single WoW client window for OBS, "" when none is open, raising when unsure.
  try:
    let
      windows = listClientWindows()
      candidates = wowCandidates(windows, nativeExecutables(windows))
    if candidates.verified.len + candidates.unverified.len > 0:
      result = xcompositeValue(currentWowWindow(windows).window)
  except MinecraftWindowError:
    raise wowError(getCurrentExceptionMsg())

proc wowAudioTarget*(): tuple[target: string, pending: bool] {.gcsafe.} =
  ## Verify which application name captures only the selected WoW process tree.
  try:
    let
      game = currentWowWindow(listClientWindows())
      graph = parseAppAudioGraph(runAudioCommand("pw-dump", @[]))
    result = verifyWowAudio(graph, readProcessParents(), game.window.processId)
  except MinecraftWindowError, MinecraftAudioError, ValueError, OSError, IOError:
    raise wowError(getCurrentExceptionMsg())

proc resizeWow*() {.gcsafe.} =
  ## Resize the single WoW client to a verified 1920x1080 client area.
  let
    expected = currentWowWindow(listClientWindows()).window.id
    select = proc (candidates: openArray[ClientWindow]): ClientWindow {.closure, gcsafe.} =
      result = currentWowWindow(candidates).window
      if result.id != expected:
        raise wowError("The WoW client window changed before resizing.")
  discard resizeSelected1080(select, WowSubject)

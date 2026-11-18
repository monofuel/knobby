import
  knobby/common,
  ./[minecraft_audio, minecraft_window, obs_client]

proc minecraftVideoTarget*(): string {.gcsafe.} =
  ## Encode the actual Minecraft X11 window for OBS, or leave capture unbound when absent.
  try:
    let windows = listClientWindows()
    var found = false
    for window in windows:
      if isMinecraftClient(window.instance, window.class): found = true
    if found:
      let window = selectMinecraftWindow(windows)
      result = $window.id & "\r\n" & window.title & "\r\n" & window.class
  except MinecraftWindowError:
    raise newException(ObsError, getCurrentExceptionMsg())

proc isMinecraftSized*(window: ClientWindow): bool =
  ## Check for a normal, non-fullscreen client area of exactly 1920x1080.
  window.width == TargetWidth and window.height == TargetHeight and
    window.states * {wsFullscreen, wsMaximizedVert, wsMaximizedHorz} == {}

proc minecraftPresence*(windows: openArray[ClientWindow]): tuple[running, sized: bool] =
  ## Report whether a Minecraft game window exists and whether exactly one is at 1920x1080.
  ## Only the X11 game class counts; launchers and other Java processes never do.
  var matches: seq[ClientWindow]
  for window in windows:
    if isMinecraftClient(window.instance, window.class): matches.add(window)
  result.running = matches.len > 0
  result.sized = matches.len == 1 and isMinecraftSized(matches[0])

proc minecraftWindowState*(): tuple[running, sized: bool] {.gcsafe.} =
  ## Read Minecraft game presence and size from the X11 client list.
  try:
    result = minecraftPresence(listClientWindows())
  except MinecraftWindowError:
    raise newException(ObsError, getCurrentExceptionMsg())

proc resizeMinecraftWindow*() {.gcsafe.} =
  ## Resize the single Minecraft game window to a verified 1920x1080 client area.
  discard resizeMinecraft1080()

proc minecraftAudioTarget*(): string {.gcsafe.} =
  ## Verify the dedicated application label captures only the actual Minecraft process.
  try:
    let window = selectMinecraftWindow(listClientWindows())
    let graph = parseAppAudioGraph(runAudioCommand("pw-dump", @[]))
    discard verifyMinecraftAudioTarget(graph, window.processId)
    result = MinecraftAudioTarget
  except MinecraftWindowError, MinecraftAudioError, ValueError, OSError, IOError:
    raise newException(ObsError, getCurrentExceptionMsg())

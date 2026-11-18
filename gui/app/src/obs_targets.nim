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

proc minecraftAudioTarget*(): string {.gcsafe.} =
  ## Verify the dedicated application label captures only the actual Minecraft process.
  try:
    let window = selectMinecraftWindow(listClientWindows())
    let graph = parseAppAudioGraph(runAudioCommand("pw-dump", @[]))
    discard verifyMinecraftAudioTarget(graph, window.processId)
    result = MinecraftAudioTarget
  except MinecraftWindowError, MinecraftAudioError, ValueError, OSError, IOError:
    raise newException(ObsError, getCurrentExceptionMsg())

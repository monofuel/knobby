import
  std/[monotimes, os, osproc, streams, strtabs, strutils, tempfiles, times],
  minecraft_window

type
  XWindow = culong
  XAtom = culong

const
  LibX11 = "libX11.so(|.6)"
  ScreenWidth = 2560
  ScreenHeight = 1440
  WaitMs = 5000
  PollMs = 20
  ExitMs = 2000
  XaAtom = XAtom(4)
  XaCardinal = XAtom(6)
  XaString = XAtom(31)
  WmSizeHintsAtom = XAtom(41)
  PropModeReplace = cint(0)
  PMaxSize = clong(1 shl 5)
  SizeHintLongs = 18
  MaxWidthIndex = 7
  MaxHeightIndex = 8
  LimitedWidth = 1600
  LimitedHeight = 900
  MinecraftClass = "Minecraft* 1.20.1"
  ProbeSize = cuint(16)

proc XOpenDisplay(name: cstring): pointer {.cdecl, importc, dynlib: LibX11.}
  ## Open the private test display.
proc XCloseDisplay(display: pointer): cint {.cdecl, importc, dynlib: LibX11.}
  ## Close the private test display.
proc XDefaultRootWindow(display: pointer): XWindow {.cdecl, importc, dynlib: LibX11.}
  ## Find the private display's root window.
proc XInternAtom(display: pointer, name: cstring, onlyIfExists: cint): XAtom {.cdecl, importc, dynlib: LibX11.}
  ## Intern an atom for fixture window properties.
proc XCreateSimpleWindow(display: pointer, parent: XWindow, x, y: cint,
    width, height, border: cuint, borderColor, background: culong): XWindow {.cdecl, importc, dynlib: LibX11.}
  ## Create a fixture application window.
proc XChangeProperty(display: pointer, window: XWindow, property, kind: XAtom,
    format, mode: cint, data: pointer, count: cint): cint {.cdecl, importc, dynlib: LibX11.}
  ## Set a fixture window property before mapping it.
proc XMapWindow(display: pointer, window: XWindow): cint {.cdecl, importc, dynlib: LibX11.}
  ## Ask the window manager to manage a fixture window.
proc XDestroyWindow(display: pointer, window: XWindow): cint {.cdecl, importc, dynlib: LibX11.}
  ## Remove a fixture window.
proc XSync(display: pointer, discardEvents: cint): cint {.cdecl, importc, dynlib: LibX11.}
  ## Wait for fixture requests to reach the X server.
proc XGetGeometry(display: pointer, drawable: XWindow, root: ptr XWindow,
    x, y: ptr cint, width, height, border, depth: ptr cuint): cint {.cdecl, importc, dynlib: LibX11.}
  ## Read the root size to confirm the screen resolution is unchanged.
proc XGetInputFocus(display: pointer, focus: ptr XWindow, revert: ptr cint): cint {.cdecl, importc, dynlib: LibX11.}
  ## Read input focus to confirm resizing does not move it.

proc waitFor(description: string, condition: proc (): bool) =
  ## Give an asynchronous window-manager transition a bounded time to finish.
  let deadline = getMonoTime() + initDuration(milliseconds = WaitMs)
  while not condition():
    if getMonoTime() >= deadline: raise newException(IOError, description)
    sleep(PollMs)

proc stop(process: Process) =
  ## Terminate an owned helper process, killing it if it ignores SIGTERM.
  if process.running():
    process.terminate()
    if process.waitForExit(ExitMs) == -1 and process.running():
      process.kill()
  discard process.waitForExit()
  process.close()

proc startXvfb(workDir: string): tuple[process: Process, name: string] =
  ## Start a private Xvfb and read its display number from the displayfd pipe.
  result.process = startProcess("/bin/sh", args = ["-c",
    "exec Xvfb -displayfd 1 -screen 0 " & $ScreenWidth & "x" & $ScreenHeight &
    "x24 -nolisten tcp 2>\"$1/xvfb.log\"", "sh", workDir])
  let
    process = result.process
    deadline = getMonoTime() + initDuration(milliseconds = WaitMs)
  while not process.hasData() and process.running() and getMonoTime() < deadline:
    sleep(PollMs)
  if not process.hasData():
    process.stop()
    raise newException(IOError, "Xvfb did not report a display: " &
      readFile(workDir / "xvfb.log"))
  result.name = ":" & process.outputStream.readLine().strip()

proc startOpenbox(workDir, displayName: string): Process =
  ## Start Openbox with default configuration on the private display only.
  let environment = newStringTable()
  for key, value in envPairs(): environment[key] = value
  environment["DISPLAY"] = displayName
  environment["XDG_CONFIG_HOME"] = workDir / "config"
  createDir(workDir / "config")
  startProcess("/bin/sh", args = ["-c",
    "exec openbox --sm-disable >\"$1/openbox.log\" 2>&1", "sh", workDir],
    env = environment)

proc setText(display: pointer, window: XWindow, property, kind: XAtom, text: string) =
  ## Store a format-8 text property on a fixture window.
  discard XChangeProperty(display, window, property, kind, 8, PropModeReplace,
    text.cstring, text.len.cint)

proc createClient(display: pointer, instance, class, title: string,
    width, height: int, states: openArray[string] = [], maxSize = false): XWindow =
  ## Create and map a fixture client with an identity, initial states, and hints.
  result = XCreateSimpleWindow(display, XDefaultRootWindow(display), 40, 40,
    width.cuint, height.cuint, 0, 0, 0)
  setText(display, result, XInternAtom(display, "WM_CLASS", 0), XaString,
    instance & "\0" & class & "\0")
  setText(display, result, XInternAtom(display, "_NET_WM_NAME", 0),
    XInternAtom(display, "UTF8_STRING", 0), title)
  if states.len > 0:
    var atoms: seq[clong]
    for state in states: atoms.add(clong(XInternAtom(display, state.cstring, 0)))
    discard XChangeProperty(display, result, XInternAtom(display, "_NET_WM_STATE", 0),
      XaAtom, 32, PropModeReplace, addr atoms[0], atoms.len.cint)
  if maxSize:
    var hints: array[SizeHintLongs, clong]
    hints[0] = PMaxSize
    hints[MaxWidthIndex] = LimitedWidth
    hints[MaxHeightIndex] = LimitedHeight
    discard XChangeProperty(display, result, XInternAtom(display, "WM_NORMAL_HINTS", 0),
      WmSizeHintsAtom, 32, PropModeReplace, addr hints[0], hints.len.cint)
  discard XMapWindow(display, result)
  discard XSync(display, 0)

proc find(windows: seq[ClientWindow], id: XWindow): ClientWindow =
  ## Find one client window in a snapshot.
  var found = false
  for window in windows:
    if window.id == id.uint64:
      result = window
      found = true
  if not found:
    raise newException(KeyError, "Window " & windowLabel(id.uint64) & " is not managed.")

proc managed(displayName: string, id: XWindow): bool =
  ## Check whether the window manager lists a fixture window.
  for window in listClientWindows(displayName):
    result = result or window.id == id.uint64

proc waitForWindowManager(display: pointer, displayName: string) =
  ## Wait until Openbox manages a probe, since maps during its startup can be lost.
  let probe = XCreateSimpleWindow(display, XDefaultRootWindow(display), 0, 0,
    ProbeSize, ProbeSize, 0, 0, 0)
  waitFor("Openbox did not start managing windows.", proc (): bool =
    discard XMapWindow(display, probe)
    discard XSync(display, 0)
    try:
      managed(displayName, probe)
    except MinecraftWindowError:
      false)
  discard XDestroyWindow(display, probe)
  discard XSync(display, 0)
  waitFor("Openbox did not release the probe window.", proc (): bool =
    not managed(displayName, probe))

proc rootSize(display: pointer): tuple[width, height: int] =
  ## Read the private screen size.
  var
    root: XWindow
    x, y: cint
    width, height, border, depth: cuint
  doAssert XGetGeometry(display, XDefaultRootWindow(display), addr root, addr x,
    addr y, addr width, addr height, addr border, addr depth) != 0
  (width.int, height.int)

proc focus(display: pointer): XWindow =
  ## Read the current input focus window.
  var revert: cint
  discard XGetInputFocus(display, addr result, addr revert)

proc expectFailure(displayName, fragment: string) =
  ## Require resizing to fail with a descriptive message.
  var message = ""
  try:
    discard resizeMinecraft1080(displayName)
  except MinecraftWindowError as error:
    message = error.msg
  doAssert fragment in message, "Expected \"" & fragment & "\" in: " & message

proc checkPureLogic() =
  ## Check WM_CLASS parsing and matching against classes seen on Openbox desktops.
  doAssert parseWmClass("Minecraft* 1.20.1\0Minecraft* 1.20.1\0") ==
    ("Minecraft* 1.20.1", "Minecraft* 1.20.1")
  doAssert parseWmClass("Navigator\0firefox\0") == ("Navigator", "firefox")
  doAssert parseWmClass("") == ("", "")
  doAssert isMinecraftClient(MinecraftClass, MinecraftClass)
  doAssert isMinecraftClient("Minecraft 1.21.4", "Minecraft 1.21.4")
  doAssert not isMinecraftClient("prismlauncher", "PrismLauncher")
  doAssert not isMinecraftClient("minecraft-launcher", "minecraft-launcher")
  doAssert not isMinecraftClient("Minecraft Launcher", "Minecraft Launcher")
  doAssert not isMinecraftClient("Navigator", "firefox")
  doAssert not isMinecraftClient("", "")
  let
    game = ClientWindow(id: 1, instance: MinecraftClass, class: MinecraftClass)
    browser = ClientWindow(id: 2, instance: "Navigator", class: "firefox",
      title: "Minecraft Wiki — Mozilla Firefox")
    launcher = ClientWindow(id: 3, instance: "prismlauncher", class: "PrismLauncher")
  doAssert selectMinecraftWindow([browser, game, launcher]).id == 1
  doAssertRaises(MinecraftWindowError): discard selectMinecraftWindow([browser, launcher])
  doAssertRaises(MinecraftWindowError): discard selectMinecraftWindow([game, game])
  doAssert windowLabel(0x09a00007'u64) == "0x09a00007"

proc checkDesktop(displayName: string) =
  ## Resize a fullscreen fake Minecraft client while other windows stay unchanged.
  let display = XOpenDisplay(displayName.cstring)
  doAssert display != nil
  defer: discard XCloseDisplay(display)
  waitForWindowManager(display, displayName)
  let
    launcher = createClient(display, "prismlauncher", "PrismLauncher",
      "Prism Launcher 11.1.1", 900, 600,
      ["_NET_WM_STATE_MAXIMIZED_VERT", "_NET_WM_STATE_MAXIMIZED_HORZ"])
    browser = createClient(display, "Navigator", "firefox",
      "Minecraft Wiki — Mozilla Firefox", 800, 600)
  waitFor("Fixture windows were not managed.", proc (): bool =
    managed(displayName, launcher) and managed(displayName, browser) and
      listClientWindows(displayName).find(launcher).states != {})
  expectFailure(displayName, "No Minecraft client window found")

  let game = createClient(display, MinecraftClass, MinecraftClass,
    "Minecraft* Forge 1.20.1", 854, 480, ["_NET_WM_STATE_FULLSCREEN",
    "_NET_WM_STATE_MAXIMIZED_VERT", "_NET_WM_STATE_MAXIMIZED_HORZ"])
  waitFor("Fake Minecraft did not become fullscreen.", proc (): bool =
    managed(displayName, game) and
      listClientWindows(displayName).find(game).width == ScreenWidth)
  let
    before = listClientWindows(displayName)
    screenBefore = rootSize(display)
    focusBefore = focus(display)
  doAssert wsFullscreen in before.find(game).states

  let resized = resizeMinecraft1080(displayName)
  doAssert resized.id == game.uint64
  doAssert (resized.width, resized.height) == (TargetWidth, TargetHeight)
  doAssert resized.states == {}
  let after = listClientWindows(displayName)
  doAssert (after.find(game).width, after.find(game).height) == (TargetWidth, TargetHeight)
  doAssert after.find(game).states == {}
  doAssert after.find(launcher) == before.find(launcher), "Launcher window changed."
  doAssert after.find(browser) == before.find(browser), "Browser window changed."
  doAssert rootSize(display) == screenBefore, "Screen resolution changed."
  doAssert focus(display) == focusBefore, "Resizing moved input focus."

  let repeated = resizeMinecraft1080(displayName)
  doAssert repeated == after.find(game), "A second resize changed the window."

  let extra = createClient(display, "Minecraft 1.21.4", "Minecraft 1.21.4",
    "Minecraft 1.21.4", 640, 360)
  waitFor("Second Minecraft window was not managed.", proc (): bool =
    managed(displayName, extra))
  expectFailure(displayName, "Found 2 Minecraft client windows")
  doAssert listClientWindows(displayName).find(game) == after.find(game)
  discard XDestroyWindow(display, extra)
  discard XDestroyWindow(display, game)
  discard XSync(display, 0)
  waitFor("Fake Minecraft windows were not removed.", proc (): bool =
    not managed(displayName, extra) and not managed(displayName, game))

  let limited = createClient(display, MinecraftClass, MinecraftClass,
    "Minecraft* Forge 1.20.1", 854, 480, maxSize = true)
  waitFor("Size-limited Minecraft was not managed.", proc (): bool =
    managed(displayName, limited))
  expectFailure(displayName, "did not reach 1920x1080")
  let final = listClientWindows(displayName)
  doAssert final.find(launcher) == before.find(launcher)
  doAssert final.find(browser) == before.find(browser)
  discard XDestroyWindow(display, limited)
  discard XDestroyWindow(display, launcher)
  discard XDestroyWindow(display, browser)
  discard XSync(display, 0)

proc main() =
  ## Run pure checks, then exercise resizing on a private Xvfb and Openbox desktop.
  checkPureLogic()
  let workDir = createTempDir("knobby-minecraft-window-", "")
  defer: removeDir(workDir)
  let xvfb = startXvfb(workDir)
  defer: xvfb.process.stop()
  doAssert xvfb.name != getEnv("DISPLAY"), "Refusing to test on the user's display."
  let openbox = startOpenbox(workDir, xvfb.name)
  defer: openbox.stop()
  checkDesktop(xvfb.name)

when isMainModule:
  main()

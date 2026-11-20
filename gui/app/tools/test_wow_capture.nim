import
  std/[monotimes, os, osproc, streams, strtabs, strutils, tables, tempfiles, times],
  minecraft_audio, minecraft_window, wow_capture

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
  PropModeReplace = cint(0)
  ProbeSize = cuint(16)
  FrameExtentLongs = 4
  FrameTopIndex = 2
  ClassicPid = 3040241
  OtherClassicPid = 3050000
  NativePid = 4100
  BotPid = 4200
  WineAppPid = 500
  ChildPid = 3040300

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
proc XGetWindowProperty(display: pointer, window: XWindow, property: XAtom,
    offset, length: clong, delete: cint, requiredType: XAtom, actualType: ptr XAtom,
    actualFormat: ptr cint, itemCount, bytesAfter: ptr culong,
    data: ptr pointer): cint {.cdecl, importc, dynlib: LibX11.}
  ## Read a window-manager property from a fixture window.
proc XFree(data: pointer): cint {.cdecl, importc, dynlib: LibX11.}
  ## Release Xlib property data.
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
    width, height: int, states: openArray[string] = [], pid = 0): XWindow =
  ## Create and map a fixture client; an empty class leaves WM_CLASS unset, as Windy does.
  result = XCreateSimpleWindow(display, XDefaultRootWindow(display), 40, 40,
    width.cuint, height.cuint, 0, 0, 0)
  if class.len > 0:
    setText(display, result, XInternAtom(display, "WM_CLASS", 0), XaString,
      instance & "\0" & class & "\0")
  setText(display, result, XInternAtom(display, "_NET_WM_NAME", 0),
    XInternAtom(display, "UTF8_STRING", 0), title)
  if pid > 0:
    var value = clong(pid)
    discard XChangeProperty(display, result, XInternAtom(display, "_NET_WM_PID", 0),
      XaCardinal, 32, PropModeReplace, addr value, 1)
  if states.len > 0:
    var atoms: seq[clong]
    for state in states: atoms.add(clong(XInternAtom(display, state.cstring, 0)))
    discard XChangeProperty(display, result, XInternAtom(display, "_NET_WM_STATE", 0),
      XaAtom, 32, PropModeReplace, addr atoms[0], atoms.len.cint)
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

proc managed(id: XWindow): bool =
  ## Check whether the window manager lists a fixture window.
  for window in listClientWindows():
    result = result or window.id == id.uint64

proc waitForWindowManager(display: pointer) =
  ## Wait until Openbox manages a probe, since maps during its startup can be lost.
  let probe = XCreateSimpleWindow(display, XDefaultRootWindow(display), 0, 0,
    ProbeSize, ProbeSize, 0, 0, 0)
  waitFor("Openbox did not start managing windows.", proc (): bool =
    discard XMapWindow(display, probe)
    discard XSync(display, 0)
    try:
      managed(probe)
    except MinecraftWindowError:
      false)
  discard XDestroyWindow(display, probe)
  discard XSync(display, 0)
  waitFor("Openbox did not release the probe window.", proc (): bool =
    not managed(probe))

proc frameTop(display: pointer, window: XWindow): int =
  ## Read the top window-manager decoration height from _NET_FRAME_EXTENTS.
  var
    actualType: XAtom
    actualFormat: cint
    itemCount, bytesAfter: culong
    data: pointer
  discard XGetWindowProperty(display, window, XInternAtom(display, "_NET_FRAME_EXTENTS", 0),
    0, FrameExtentLongs, 0, XaCardinal, addr actualType, addr actualFormat, addr itemCount,
    addr bytesAfter, addr data)
  if data != nil:
    if itemCount.int == FrameExtentLongs:
      result = cast[ptr UncheckedArray[clong]](data)[FrameTopIndex].int
    discard XFree(data)

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

proc expectWowError(fragment: string, action: proc ()) =
  ## Require a WoW operation to fail with a descriptive message.
  var message = ""
  try:
    action()
  except WowCaptureError as error:
    message = error.msg
  doAssert fragment in message, "Expected \"" & fragment & "\" in: " & message

proc stream(id, pid: int, appName, binary: string): AppStream =
  ## Build one synthetic PipeWire output stream.
  AppStream(id: id, processId: pid, name: appName, appName: appName, binary: binary)

proc checkIdentity() =
  ## Accept only exact Classic and native player identities, never titles from other programs.
  let
    classic = ClientWindow(id: 1, instance: "wow.exe", class: "wow.exe",
      title: "World of Warcraft", processId: ClassicPid, width: TargetWidth, height: TargetHeight)
    native = ClientWindow(id: 2, title: "Vanilla WoW Player", processId: NativePid,
      width: 1280, height: 720)
    pidless = ClientWindow(id: 3, title: "Vanilla WoW Player")
    browser = ClientWindow(id: 4, instance: "Navigator", class: "firefox",
      title: "World of Warcraft", processId: 77)
    browserNative = ClientWindow(id: 5, instance: "Navigator", class: "firefox",
      title: "Vanilla WoW Player", processId: 77)
    otherWine = ClientWindow(id: 6, instance: "battle.net.exe", class: "battle.net.exe",
      title: "World of Warcraft", processId: WineAppPid)
    suffixed = ClientWindow(id: 7, instance: "wow.exe", class: "wow.exe",
      title: "World of Warcraft - Classic", processId: ClassicPid)
    executables = {NativePid: "player", 77: "firefox", BotPid: "unheaded_player"}.toTable
  doAssert selectWowWindow([browser, browserNative, otherWine, suffixed, classic],
    executables).kind == ClassicClient
  doAssert selectWowWindow([browser, native], executables).window.id == 2
  doAssert selectWowWindow([native], executables).kind == NativeClient
  var retitledBrowser = browserNative
  retitledBrowser.processId = NativePid
  expectWowError("not open", proc () = discard selectWowWindow([retitledBrowser], executables))
  var bot = native
  bot.processId = BotPid
  expectWowError("not open", proc () = discard selectWowWindow([bot, browser,
    browserNative, otherWine, suffixed], executables))
  expectWowError("not open", proc () = discard selectWowWindow([], executables))
  expectWowError("Found 2 WoW clients", proc () =
    discard selectWowWindow([classic, native], executables))
  var second = classic
  second.id = 8
  second.processId = OtherClassicPid
  expectWowError("Found 2 WoW clients", proc () =
    discard selectWowWindow([classic, second], executables))
  expectWowError("libXRes", proc () = discard selectWowWindow([pidless], executables))
  expectWowError("Found 2 WoW clients", proc () =
    discard selectWowWindow([classic, pidless], executables))
  var classicPidless = classic
  classicPidless.processId = 0
  expectWowError("no process ID", proc () =
    discard selectWowWindow([classicPidless], executables))
  doAssert wowPresence([classic, browser], executables) == (running: true, sized: true)
  doAssert wowPresence([browser, browserNative, bot], executables) ==
    (running: false, sized: false)
  doAssert wowPresence([classic, second], executables) == (running: true, sized: false)
  doAssert wowPresence([classic, pidless], executables) == (running: true, sized: false)
  doAssert wowPresence([native], executables) == (running: true, sized: false)
  var fullscreen = classic
  fullscreen.states = {wsFullscreen}
  doAssert wowPresence([fullscreen], executables) == (running: true, sized: false)
  var maximized = classic
  maximized.states = {wsMaximizedVert, wsMaximizedHorz}
  doAssert wowPresence([maximized], executables) == (running: true, sized: false)

proc checkAudio() =
  ## Choose the game's own application name only when it captures exactly its process tree.
  let parents = {ClassicPid: 1, ChildPid: ClassicPid, OtherClassicPid: 1, NativePid: 1,
    BotPid: 1, WineAppPid: 1}.toTable
  let classic = AppAudioGraph(streams: @[
    stream(10, ClassicPid, "World of Warcraft", "wine-preloader"),
    stream(11, ChildPid, "World of Warcraft", "wine-preloader"),
    stream(12, WineAppPid, "Battle.net", "wine-preloader")])
  doAssert verifyWowAudio(classic, parents, ClassicPid) == ("World of Warcraft", false)
  doAssert verifyWowAudio(AppAudioGraph(), parents, ClassicPid) == ("", true)
  doAssert verifyWowAudio(AppAudioGraph(streams: @[classic.streams[2]]), parents,
    ClassicPid) == ("", true), "another Wine program never makes WoW audible"
  var twoGames = classic
  twoGames.streams.add(stream(13, OtherClassicPid, "World of Warcraft", "wine-preloader"))
  expectWowError("also captures", proc () = discard verifyWowAudio(twoGames, parents, ClassicPid))
  var unknownPid = classic
  unknownPid.streams.add(stream(14, 0, "World of Warcraft", "wine-preloader"))
  expectWowError("also captures", proc () = discard verifyWowAudio(unknownPid, parents, ClassicPid))
  let generic = AppAudioGraph(streams: @[stream(15, ClassicPid, "wine-preloader",
    "wine-preloader")])
  expectWowError("would also capture", proc () = discard verifyWowAudio(generic, parents,
    ClassicPid))
  let openal = AppAudioGraph(streams: @[stream(16, NativePid, "OpenAL Soft", "player")])
  expectWowError("would also capture", proc () = discard verifyWowAudio(openal, parents,
    NativePid))
  let mixed = AppAudioGraph(streams: @[stream(17, ClassicPid, "World of Warcraft", "wine-preloader"),
    stream(18, ChildPid, "Wine Audio", "wine-preloader")])
  expectWowError("different names", proc () = discard verifyWowAudio(mixed, parents, ClassicPid))
  let native = AppAudioGraph(streams: @[stream(19, NativePid, "player", "player"),
    stream(20, BotPid, "unheaded_player", "unheaded_player")])
  doAssert verifyWowAudio(native, parents, NativePid) == ("player", false)
  expectWowError("no process ID", proc () = discard verifyWowAudio(native, parents, 0))

proc checkDesktop(display: pointer) =
  ## Resize a decorated, fullscreen, maximized Classic fixture while other windows stay unchanged.
  waitForWindowManager(display)
  doAssert wowState() == (running: false, sized: false)
  doAssert wowVideoTarget() == ""
  expectWowError("not open", resizeWow)
  let
    browser = createClient(display, "Navigator", "firefox", "World of Warcraft", 800, 600,
      pid = 77)
    browserNative = createClient(display, "Navigator", "firefox", "Vanilla WoW Player",
      800, 600, pid = 78)
    native = createClient(display, "", "", "Vanilla WoW Player", 640, 480)
  waitFor("Fixture windows were not managed.", proc (): bool =
    managed(browser) and managed(browserNative) and managed(native))
  let snapshot = listClientWindows()
  doAssert snapshot.find(native).class == ""
  doAssert snapshot.find(native).processId == getCurrentProcessId(),
    "XRes supplies the PID of a client without _NET_WM_PID"
  doAssert snapshot.find(browser).processId == 77
  doAssert wowState() == (running: false, sized: false),
    "browser titles and a non-player process are never WoW"
  doAssert wowVideoTarget() == ""
  let asPlayer = {getCurrentProcessId(): "player"}.toTable
  doAssert selectWowWindow(snapshot, asPlayer).window.id == native.uint64
  discard XDestroyWindow(display, native)
  discard XSync(display, 0)
  waitFor("Native fixture was not removed.", proc (): bool = not managed(native))

  let game = createClient(display, "wow.exe", "wow.exe", "World of Warcraft", 854, 480,
    ["_NET_WM_STATE_FULLSCREEN", "_NET_WM_STATE_MAXIMIZED_VERT",
    "_NET_WM_STATE_MAXIMIZED_HORZ"], pid = ClassicPid)
  waitFor("Classic fixture did not become fullscreen.", proc (): bool =
    managed(game) and listClientWindows().find(game).width == ScreenWidth)
  let
    before = listClientWindows()
    screenBefore = rootSize(display)
    focusBefore = focus(display)
  doAssert wowState() == (running: true, sized: false)
  doAssert wowVideoTarget() == $game.uint64 & "\r\nWorld of Warcraft\r\nwow.exe"
  resizeWow()
  let after = listClientWindows()
  doAssert (after.find(game).width, after.find(game).height) == (TargetWidth, TargetHeight)
  doAssert after.find(game).states == {}
  doAssert frameTop(display, game) > 0, "the exact size is the client area inside decorations"
  doAssert wowState() == (running: true, sized: true)
  doAssert after.find(browser) == before.find(browser), "Browser window changed."
  doAssert after.find(browserNative) == before.find(browserNative), "Browser window changed."
  doAssert rootSize(display) == screenBefore, "Screen resolution changed."
  doAssert focus(display) == focusBefore, "Resizing moved input focus."
  resizeWow()
  doAssert listClientWindows().find(game) == after.find(game), "A second resize changed WoW."

  let maximized = createClient(display, "wow.exe", "wow.exe", "World of Warcraft", 640, 360,
    ["_NET_WM_STATE_MAXIMIZED_VERT", "_NET_WM_STATE_MAXIMIZED_HORZ"], pid = OtherClassicPid)
  waitFor("Second Classic fixture was not managed.", proc (): bool = managed(maximized))
  doAssert wowState() == (running: true, sized: false)
  expectWowError("Found 2 WoW clients", resizeWow)
  expectWowError("Found 2 WoW clients", proc () = discard wowVideoTarget())
  doAssert listClientWindows().find(game) == after.find(game)
  discard XDestroyWindow(display, game)
  discard XSync(display, 0)
  waitFor("Classic fixture was not removed.", proc (): bool = not managed(game))
  waitFor("Maximized Classic fixture was not maximized.", proc (): bool =
    listClientWindows().find(maximized).states != {})
  resizeWow()
  let normal = listClientWindows().find(maximized)
  doAssert (normal.width, normal.height) == (TargetWidth, TargetHeight)
  doAssert normal.states == {}
  for window in [maximized, browser, browserNative]:
    discard XDestroyWindow(display, window)
  discard XSync(display, 0)

proc main() =
  ## Run pure identity and audio checks, then resize fixtures on a private Xvfb and Openbox.
  checkIdentity()
  checkAudio()
  let workDir = createTempDir("knobby-wow-capture-", "")
  defer: removeDir(workDir)
  let xvfb = startXvfb(workDir)
  defer: xvfb.process.stop()
  doAssert xvfb.name != getEnv("DISPLAY"), "Refusing to test on the user's display."
  let openbox = startOpenbox(workDir, xvfb.name)
  defer: openbox.stop()
  # The WoW helpers use the default display, so point this test process at the private one.
  putEnv("DISPLAY", xvfb.name)
  let display = XOpenDisplay(xvfb.name.cstring)
  doAssert display != nil
  defer: discard XCloseDisplay(display)
  checkDesktop(display)

when isMainModule:
  main()

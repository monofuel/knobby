import
  std/[json, monotimes, os, osproc, streams, strtabs, strutils, tables, tempfiles, times],
  knobby/firefox_demo_config,
  firefox_demo, minecraft_audio, minecraft_window

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
  XaString = XAtom(31)
  XaCardinal = XAtom(6)
  PropModeReplace = cint(0)
  ProbeSize = cuint(16)
  DemoClass = "knobby-test-demos"
  DemoLabel = "knobby-test-audio"
  DemoPid = 4100
  ContentPid = 4101
  NormalPid = 5200
  StrangerPid = 6300

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
  ## Create a fixture browser window.
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
  environment["XDG_CONFIG_HOME"] = workDir / "openbox-config"
  createDir(workDir / "openbox-config")
  startProcess("/bin/sh", args = ["-c",
    "exec openbox --sm-disable >\"$1/openbox.log\" 2>&1", "sh", workDir],
    env = environment)

proc setText(display: pointer, window: XWindow, property, kind: XAtom, text: string) =
  ## Store a format-8 text property on a fixture window.
  discard XChangeProperty(display, window, property, kind, 8, PropModeReplace,
    text.cstring, text.len.cint)

proc createBrowser(display: pointer, instance, class, title: string, pid: int): XWindow =
  ## Create and map a fixture browser window with an identity and process ID.
  result = XCreateSimpleWindow(display, XDefaultRootWindow(display), 60, 60, 800, 600, 0, 0, 0)
  setText(display, result, XInternAtom(display, "WM_CLASS", 0), XaString,
    instance & "\0" & class & "\0")
  setText(display, result, XInternAtom(display, "_NET_WM_NAME", 0),
    XInternAtom(display, "UTF8_STRING", 0), title)
  var processId = clong(pid)
  discard XChangeProperty(display, result, XInternAtom(display, "_NET_WM_PID", 0),
    XaCardinal, 32, PropModeReplace, addr processId, 1)
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
  waitFor("Openbox did not release the probe window.", proc (): bool = not managed(probe))

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

proc expectDemoError(action: proc (), fragment: string) =
  ## Require a Firefox demo operation to fail with a descriptive message.
  var message = ""
  try:
    action()
  except FirefoxDemoError as error:
    message = error.msg
  doAssert fragment in message, "Expected \"" & fragment & "\" in: " & message

proc demoConfig(): FirefoxDemoConfig =
  ## Return a non-default demo identity, as the shared settings file may configure.
  result = defaultFirefoxDemoConfig()
  result.windowClass = DemoClass
  result.audioLabel = DemoLabel

proc stream(id, pid: int, appName: string, binary = "firefox"): AppStream =
  ## Build an application output stream for audio isolation checks.
  AppStream(id: id, processId: pid, name: "Firefox", appName: appName, binary: binary)

proc checkConfigGuards() =
  ## Refuse identities and paths that would reach ordinary Firefox sessions.
  let home = "/home/tester"
  validateFirefoxDemoConfig(defaultFirefoxDemoConfig(), home)
  validateFirefoxDemoConfig(demoConfig(), home)
  for (field, value, fragment) in [("windowClass", "firefox", "ordinary Firefox"),
      ("windowClass", "Navigator", "ordinary Firefox"),
      ("audioLabel", "Firefox", "ordinary Firefox"),
      ("audioLabel", "demo' x", "letters, digits"),
      ("windowClass", "", "letters, digits"),
      ("profileDirectory", home & "/.mozilla/firefox/abcd.default", "normal Firefox"),
      ("profileDirectory", home & "/.config/mozilla", "normal Firefox"),
      ("profileDirectory", "relative/demos", "absolute"),
      ("startUrl", "--headless", "command-line option")]:
    var config = defaultFirefoxDemoConfig()
    case field
    of "windowClass": config.windowClass = value
    of "audioLabel": config.audioLabel = value
    of "profileDirectory": config.profileDirectory = value
    of "startUrl": config.startUrl = value
    expectDemoError(proc () = validateFirefoxDemoConfig(config, home), fragment)

proc checkLaunchArguments() =
  ## Launch a separate instance with the configured identity, label, and profile.
  let
    config = demoConfig()
    args = firefoxLaunchArgs(config)
    command = args[args.find("--") + 1 .. ^1]
  doAssert "--unit=" & FirefoxDemoUnit in args
  doAssert "--setenv=MOZ_APP_REMOTINGNAME=" & DemoClass in args
  doAssert "--setenv=MOZ_ENABLE_WAYLAND=0" in args
  doAssert "--setenv=PULSE_PROP_OVERRIDE=application.name='" & DemoLabel & "'" in args
  doAssert command == @[config.executable, "--new-instance", "--profile",
    config.profileDirectory, config.startUrl], $command
  for arg in args:
    doAssert arg notin ["--headless", "--class", "-P"], arg
  doAssert hasFirefoxAudioLabel("HOME=/h\0PULSE_PROP_OVERRIDE=application.name='" &
    DemoLabel & "'\0", DemoLabel)
  doAssert not hasFirefoxAudioLabel("PULSE_PROP_OVERRIDE=application.name='other'\0", DemoLabel)
  doAssert not hasFirefoxAudioLabel("", DemoLabel)

proc checkWindowSelection() =
  ## Select only the exact configured class, never ordinary Firefox or matching titles.
  let
    config = demoConfig()
    normal = ClientWindow(id: 1, instance: "Navigator", class: "firefox",
      title: "Demo - Mozilla Firefox")
    titled = ClientWindow(id: 2, instance: "Navigator", class: "firefox", title: DemoClass)
    prefixed = ClientWindow(id: 3, instance: "Navigator", class: DemoClass & "-2")
    demo = ClientWindow(id: 4, instance: "Navigator", class: DemoClass,
      width: TargetWidth, height: TargetHeight)
  doAssert selectFirefoxDemoWindow([normal, titled, prefixed, demo], config).id == 4
  expectDemoError(proc () = discard selectFirefoxDemoWindow([normal, titled, prefixed], config),
    "not open")
  var second = demo
  second.id = 5
  expectDemoError(proc () = discard selectFirefoxDemoWindow([demo, second], config),
    "refusing to guess")
  doAssert firefoxDemoPresence([normal, titled], config) == (running: false, sized: false)
  doAssert firefoxDemoPresence([normal, demo], config) == (running: true, sized: true)
  doAssert firefoxDemoPresence([demo, second], config) == (running: true, sized: false)
  var fullscreen = demo
  fullscreen.states = {wsFullscreen}
  doAssert firefoxDemoPresence([fullscreen], config) == (running: true, sized: false)
  doAssert xcompositeValue(demo) == "4\r\n\r\n" & DemoClass

proc checkAudioIsolation() =
  ## Accept the label only when it captures exactly the demo process tree.
  let parents = {DemoPid: 1, ContentPid: DemoPid, NormalPid: 1, StrangerPid: 1}.toTable()
  doAssert parseProcessParent("4101 (Web Content) S 4100 4101 4100 0 -1") == DemoPid
  doAssert parseProcessParent("77 (a) b) c) R 9 77") == 9
  doAssert parents.inProcessTree(ContentPid, DemoPid)
  doAssert parents.inProcessTree(DemoPid, DemoPid)
  doAssert not parents.inProcessTree(NormalPid, DemoPid)
  doAssert not parents.inProcessTree(999, DemoPid)
  let
    normal = stream(1, NormalPid, "Firefox")
    demo = stream(2, ContentPid, DemoLabel)
    good = AppAudioGraph(streams: @[normal, demo])
  doAssert verifyFirefoxAudioTarget(good, parents, DemoPid, DemoLabel, false) == @[demo]
  doAssert verifyFirefoxAudioTarget(AppAudioGraph(streams: @[normal]), parents, DemoPid,
    DemoLabel, true).len == 0, "a silent demo with a proven label is ready"
  expectDemoError(proc () = discard verifyFirefoxAudioTarget(
    AppAudioGraph(streams: @[normal]), parents, DemoPid, DemoLabel, false), "not launched")
  expectDemoError(proc () = discard verifyFirefoxAudioTarget(
    AppAudioGraph(streams: @[normal, demo, stream(3, StrangerPid, DemoLabel, "mpv")]),
    parents, DemoPid, DemoLabel, true), "also captures")
  expectDemoError(proc () = discard verifyFirefoxAudioTarget(
    AppAudioGraph(streams: @[stream(4, ContentPid, "Firefox")]), parents, DemoPid,
    DemoLabel, true), "is not labeled")
  expectDemoError(proc () = discard verifyFirefoxAudioTarget(
    AppAudioGraph(streams: @[stream(5, 0, DemoLabel)]), parents, DemoPid, DemoLabel, true),
    "also captures")
  expectDemoError(proc () = discard verifyFirefoxAudioTarget(good, parents, 0, DemoLabel, true),
    "no process ID")
  expectDemoError(proc () = discard verifyFirefoxAudioTarget(good, parents, DemoPid,
    "firefox", true), "ordinary Firefox")

proc checkDesktop(workDir: string, display: pointer) =
  ## Find, size, and focus only the dedicated demo window on a private display.
  createDir(workDir / "config/knobby")
  writeFile(workDir / "config/knobby/firefox-demo.json",
    $(%*{"windowClass": DemoClass, "audioLabel": DemoLabel,
      "profileDirectory": workDir / "demo-profile"}))
  doAssert loadDemoConfig().windowClass == DemoClass
  doAssert firefoxDemoState() == (running: false, sized: false)
  doAssert firefoxDemoVideoTarget() == ""
  let
    normal = createBrowser(display, "Navigator", "firefox", "Demo - Mozilla Firefox", NormalPid)
    titled = createBrowser(display, "Navigator", "firefox", DemoClass, NormalPid)
  waitFor("Ordinary browsers were not managed.", proc (): bool =
    managed(normal) and managed(titled))
  doAssert firefoxDemoState() == (running: false, sized: false)
  doAssert firefoxDemoVideoTarget() == ""
  expectDemoError(resizeFirefoxDemo, "not open")
  let demo = createBrowser(display, "Navigator", DemoClass, "Demo page", DemoPid)
  waitFor("Demo browser was not managed.", proc (): bool = managed(demo))
  let
    before = listClientWindows()
    focused = focus(display)
  doAssert firefoxDemoState() == (running: true, sized: false)
  let target = firefoxDemoVideoTarget()
  doAssert target.startsWith($demo.uint64 & "\r\n") and target.endsWith("\r\n" & DemoClass), target
  resizeFirefoxDemo()
  let after = listClientWindows()
  doAssert after.find(demo).width == TargetWidth and after.find(demo).height == TargetHeight
  doAssert after.find(demo).processId == DemoPid
  for id in [normal, titled]:
    doAssert after.find(id).width == before.find(id).width
    doAssert after.find(id).height == before.find(id).height
    doAssert after.find(id).x == before.find(id).x
  doAssert rootSize(display) == (ScreenWidth, ScreenHeight)
  doAssert focus(display) == focused, "resizing never moves focus"
  doAssert firefoxDemoState() == (running: true, sized: true)
  resizeFirefoxDemo()
  waitFor("The sized demo window was not focused.", proc (): bool = focus(display) == demo)
  let second = createBrowser(display, "Navigator", DemoClass, "Second demo", DemoPid)
  waitFor("Second demo browser was not managed.", proc (): bool = managed(second))
  doAssert firefoxDemoState() == (running: true, sized: false)
  expectDemoError(proc () = discard firefoxDemoVideoTarget(), "refusing to guess")
  expectDemoError(resizeFirefoxDemo, "refusing to guess")
  doAssert listClientWindows().find(normal).width == before.find(normal).width
  discard XDestroyWindow(display, second)
  discard XDestroyWindow(display, demo)
  discard XSync(display, 0)
  waitFor("Demo browsers were not removed.", proc (): bool =
    not managed(second) and not managed(demo))
  doAssert firefoxDemoState() == (running: false, sized: false)
  doAssert firefoxDemoVideoTarget() == ""
  doAssert not dirExists(workDir / "demo-profile"), "tests never launch the demo"

proc main() =
  ## Run hardware-free checks, then window checks on a private Xvfb and Openbox.
  checkConfigGuards()
  checkLaunchArguments()
  checkWindowSelection()
  checkAudioIsolation()
  let workDir = createTempDir("knobby_firefox_demo_", "")
  let xvfb = startXvfb(workDir)
  var openbox: Process
  var display: pointer
  defer:
    if display != nil: discard XCloseDisplay(display)
    if openbox != nil: openbox.stop()
    xvfb.process.stop()
    removeDir(workDir)
  putEnv("DISPLAY", xvfb.name)
  putEnv("XDG_CONFIG_HOME", workDir / "config")
  openbox = startOpenbox(workDir, xvfb.name)
  display = XOpenDisplay(xvfb.name.cstring)
  doAssert display != nil, "Cannot open private display " & xvfb.name
  waitForWindowManager(display)
  checkDesktop(workDir, display)

when isMainModule:
  main()

import
  std/[json, math, os, osproc, tables],
  chroma, jsony, pixie,
  silky/atlas,
  knobby/[button_config, button_runtime, ipc, overlay_state, status],
  ../src/[overlay_layout, overlay_x11, smoke_input]

type
  XWindowAttributes = object
    x, y, width, height, borderWidth, depth: cint
    visual: pointer
    root: XId
    class, bitGravity, winGravity, backingStore: cint
    backingPlanes, backingPixel: culong
    saveUnder: cint
    colormap: culong
    mapInstalled, mapState: cint
    allEventMasks, yourEventMask, doNotPropagateMask: clong
    overrideRedirect: cint
    screen: pointer
  XButtonEvent = object
    kind: cint
    serial: culong
    sendEvent: cint
    display: pointer
    window, root, subwindow: XId
    time: culong
    x, y, xRoot, yRoot: cint
  XSizeHints = object
    flags: clong
    x, y, width, height: cint
    padding: array[13, cint]
  Daemon = object
    server: LocalServer
    up, heartbeats: bool
    lastSentMs: int64
  Fixture = object
    window, frame, dock, compositor: XId
    presses: seq[tuple[x, y: int]]

const
  Assets = currentSourcePath().parentDir().parentDir() / "assets"
  ScreenWidth = 3200
  ScreenHeight = 1200
  LeftWidth = 960
  PrimaryWidth = 1280
  DockHeight = 40
  ExpectedX = LeftWidth + (PrimaryWidth - OverlayWidth) div 2
  ExpectedY = ScreenHeight - DockHeight - ScreenMargin - OverlayHeight
  FixtureColor = 0xff00ff'u32
  FixtureRgb = rgbx(255, 0, 255, 255)
  IsViewable = 2
  ButtonPressType = 4
  ButtonPressMask = clong(1 shl 2)
  StructureNotifyMask = clong(1 shl 17)
  USPositionSize = clong(3)
  PropModeReplace = cint(0)
  XaAtom = Atom(4)
  XaCardinal = Atom(6)
  XaWindow = Atom(33)
  PlacementSettleMs = 1200
  StateIntervalMs = 50
  ShowLimitMs = 1500
  HideLimitMs = 700
  MoveLimitMs = 2000
  StaleLimitMs = StatusStaleMs + 1500
  ShortDeadlineMs = 2500
  ExtraScreenshotMargin = 24
  HelpKey = 3
  OtherKey = 5
  WaitStepMs = 10

{.push cdecl, importc, dynlib: "libX11.so(|.6)".}
proc XCreateSimpleWindow(display: XDisplay, parent: XId, x, y: cint, width, height, border: cuint,
  borderPixel, background: culong): XId
proc XMapWindow(display: XDisplay, window: XId): cint
proc XDestroyWindow(display: XDisplay, window: XId): cint
proc XSelectInput(display: XDisplay, window: XId, mask: clong): cint
proc XPending(display: XDisplay): cint
proc XNextEvent(display: XDisplay, event: pointer): cint
proc XStoreName(display: XDisplay, window: XId, name: cstring): cint
proc XFetchName(display: XDisplay, window: XId, name: ptr cstring): cint
proc XFree(data: pointer): cint
proc XGetInputFocus(display: XDisplay, focus: ptr XId, revert: ptr cint): cint
proc XGetWindowAttributes(display: XDisplay, window: XId, attributes: ptr XWindowAttributes): cint
proc XRaiseWindow(display: XDisplay, window: XId): cint
proc XSetSelectionOwner(display: XDisplay, selection: Atom, owner: XId, time: culong): cint
proc XChangeProperty(display: XDisplay, window: XId, property, kind: Atom, format, mode: cint,
  data: pointer, count: cint): cint
proc XSetWMNormalHints(display: XDisplay, window: XId, hints: ptr XSizeHints)
proc XMoveWindow(display: XDisplay, window: XId, x, y: cint): cint
{.pop.}

{.push cdecl, importc, dynlib: "libXrandr.so(|.2)".}
proc XRRAllocateMonitor(display: XDisplay, outputs: cint): ptr XRRMonitorInfo
proc XRRSetMonitor(display: XDisplay, window: XId, monitor: ptr XRRMonitorInfo)
proc XRRDeleteMonitor(display: XDisplay, window: XId, name: Atom)
{.pop.}

proc check(condition: bool, message: string) =
  ## Fail the isolated acceptance run with a specific reason.
  if not condition:
    raise newException(AssertionDefect, message)

proc overlayConfig(): JsonNode =
  ## Describe a realistic mixer menu with long, short, and unassigned slots.
  let help = when declared(MixerOverlayAction): "mixerOverlay" else: "none"
  %*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Main",
      "mixer": [
        {"key": 12, "title": "Grok", "action": {"kind": "grok"}},
        {"key": 9, "title": "Claude", "action": {"kind": "claude"}},
        {"key": 6, "title": "Tools", "action": {"kind": "menu", "menu": "tools", "target": "mixer"}},
        {"key": HelpKey, "title": "Help", "action": {"kind": help}},
        {"key": 11, "title": "Microphones", "action": {"kind": "microphones"}},
        {"key": 8, "title": "Spotify, Firefox and every game volume shortcut on this board",
          "action": {"kind": "command", "command": "true"}},
        {"key": OtherKey, "title": "Echo", "action": {"kind": "command", "command": "true"}},
        {"key": 10, "title": "FFXIV", "action": {"kind": "ffxiv"}},
        {"key": 1, "title": "Discord", "action": {"kind": "discord"}}],
      "deck": []},
    {"id": "tools", "title": "Tools", "mixer": [], "deck": []}]}

proc fakePrepare(config: JsonNode): JsonNode {.gcsafe.} =
  ## Return numbered Deck pages without media tools; the overlay never reads them.
  result = %*{"version": 1, "menus": {}}
  for menu in config["menus"]:
    var keys = newJObject()
    for key in 1..DeckKeyCount:
      keys[$key] = %*{"builtinNumber": key}
    result["menus"][menu["id"].getStr()] = keys

proc fakeImport(source: string): string {.gcsafe.} =
  ## Refuse imports, which this check never requests.
  raise newException(IOError, "Imports are not used by the overlay check.")

proc pressHelp() =
  ## Press the help key, or record its request directly until the action kind exists.
  when declared(MixerOverlayAction):
    routeMixerButton(HelpKey, true)
    routeMixerButton(HelpKey, false)
    discard takeButtonActions()
  else:
    pressMixerOverlay(true)

proc requestHelpEndingIn(milliseconds: int64) =
  ## Record a help request whose deadline is only a short time away.
  pressMixerOverlay(false)
  pressMixerOverlay(true, monotonicMs() - MixerOverlayDurationMs + milliseconds)

proc serve(daemon: var Daemon) =
  ## Answer subscriptions and publish state like the daemon, unless the test paused it.
  if not daemon.up:
    return
  let message = %*{"version": ProtocolVersion, "type": "state", "state": encodeState(readKnobbyState())}
  for request in daemon.server.pollRequests():
    if request.message{"type"}.getStr() == "subscribe":
      request.peer.subscribed = true
      request.peer.queueMessage(message)
    else:
      request.peer.close()
  if daemon.heartbeats and monotonicMs() - daemon.lastSentMs >= StateIntervalMs:
    daemon.server.broadcast(message)
    daemon.lastSentMs = monotonicMs()

proc startDaemon(daemon: var Daemon) =
  ## Listen on the private daemon socket.
  daemon.server = newLocalServer(runtimePath("knobby", "daemon.sock"))
  daemon.up = true
  daemon.heartbeats = true

proc stopDaemon(daemon: var Daemon) =
  ## Close the private daemon socket and every subscriber.
  daemon.server.close()
  daemon.up = false

proc collect(x11: OverlayX11, fixture: var Fixture) =
  ## Record pointer presses delivered to the fixture application.
  var event: array[24, clong]
  while XPending(x11.display) > 0:
    discard XNextEvent(x11.display, event[0].addr)
    let button = cast[ptr XButtonEvent](event[0].addr)
    if button.kind == ButtonPressType and button.window == fixture.window:
      fixture.presses.add((button.xRoot.int, button.yRoot.int))

proc pump(daemon: var Daemon, x11: OverlayX11, fixture: var Fixture, milliseconds: int,
    until: proc (): bool = nil): bool =
  ## Serve the fake daemon until a condition holds or the time runs out.
  let deadline = monotonicMs() + milliseconds
  while monotonicMs() < deadline:
    daemon.serve()
    x11.collect(fixture)
    if not until.isNil and until():
      return true
    sleep(WaitStepMs)
  not until.isNil and until()

proc attributes(x11: OverlayX11, window: XId): XWindowAttributes =
  ## Read a window's server-side attributes.
  check XGetWindowAttributes(x11.display, window, result.addr) != 0, "Window disappeared."

proc windowName(x11: OverlayX11, window: XId): string =
  ## Read WM_NAME, or an empty string.
  var name: cstring
  if XFetchName(x11.display, window, name.addr) != 0 and not name.isNil:
    result = $name
    discard XFree(name)

proc findOverlay(x11: OverlayX11): XId =
  ## Find the renderer's top-level window by title, mapped or not.
  for window in x11.stacking():
    if x11.windowName(window) == "Knobby overlay":
      return window

proc viewable(x11: OverlayX11, window: XId): bool =
  ## Report whether the window is currently mapped and visible.
  window != 0 and x11.attributes(window).mapState == IsViewable

proc focus(x11: OverlayX11): XId =
  ## Return the keyboard focus window.
  var revert: cint
  discard XGetInputFocus(x11.display, result.addr, revert.addr)

proc topLevel(x11: OverlayX11, window: XId): XId =
  ## Return the root child containing a window, which is its frame when managed.
  result = window
  while x11.parentOf(result) != x11.root:
    result = x11.parentOf(result)

proc setMonitor(x11: OverlayX11, name: string, x, width: int, primary: bool) =
  ## Define one RandR monitor on the private screen.
  let monitor = XRRAllocateMonitor(x11.display, 0)
  monitor.name = x11.atom(name)
  monitor.primary = cint(primary)
  monitor.automatic = 0
  monitor.x = x.cint
  monitor.width = width.cint
  monitor.height = ScreenHeight
  monitor.mwidth = cint(width div 4)
  monitor.mheight = cint(ScreenHeight div 4)
  XRRSetMonitor(x11.display, x11.root, monitor)
  discard XFree(monitor)
  x11.sync()

proc setProperty(x11: OverlayX11, window: XId, name: string, kind: Atom, values: openArray[clong]) =
  ## Replace a 32-bit property on a fixture window.
  var data = @values
  discard XChangeProperty(x11.display, window, x11.atom(name), kind, 32, PropModeReplace,
    data[0].addr, data.len.cint)

proc createFixture(x11: OverlayX11): Fixture =
  ## Map a focused full-screen application and a bottom panel on the primary monitor.
  result.window = XCreateSimpleWindow(x11.display, x11.root, 0, 0, ScreenWidth, ScreenHeight, 0, 0,
    FixtureColor)
  discard XStoreName(x11.display, result.window, "Overlay fixture")
  var hints = XSizeHints(flags: USPositionSize, width: ScreenWidth, height: ScreenHeight)
  XSetWMNormalHints(x11.display, result.window, hints.addr)
  discard XSelectInput(x11.display, result.window, ButtonPressMask or StructureNotifyMask)
  discard XMapWindow(x11.display, result.window)
  result.dock = XCreateSimpleWindow(x11.display, x11.root, LeftWidth, ScreenHeight - DockHeight,
    PrimaryWidth, DockHeight, 0, 0, 0x202020)
  var dockHints = XSizeHints(flags: USPositionSize, x: LeftWidth, y: ScreenHeight - DockHeight,
    width: PrimaryWidth, height: DockHeight)
  XSetWMNormalHints(x11.display, result.dock, dockHints.addr)
  x11.setProperty(result.dock, "_NET_WM_WINDOW_TYPE", XaAtom,
    [clong(x11.atom("_NET_WM_WINDOW_TYPE_DOCK"))])
  x11.setProperty(result.dock, "_NET_WM_STRUT_PARTIAL", XaCardinal,
    [0.clong, 0, 0, DockHeight, 0, 0, 0, 0, 0, 0, LeftWidth, LeftWidth + PrimaryWidth - 1])
  discard XMapWindow(x11.display, result.dock)
  x11.sync()

proc checkPixel(image: Image, x, y: int, expected: ColorRGBX, message: string) =
  ## Fail with the actual and expected pixel values at one screenshot position.
  let actual = image[x, y]
  check actual == expected, message & " At (" & $x & ", " & $y & ") expected " & $expected &
    " but found " & $actual & "."

var recordedErrors: int

proc recordError(display: XDisplay, event: ptr XErrorEvent): cint {.cdecl.} =
  ## Count X errors that reach the test's own handler instead of the struts trap.
  inc recordedErrors

proc setClients(x11: OverlayX11, clients: seq[int]) =
  ## Replace the root _NET_CLIENT_LIST and wait for the server to apply it.
  var values: seq[clong]
  for client in clients: values.add(clong(client))
  x11.setProperty(x11.root, "_NET_CLIENT_LIST", XaWindow, values)
  x11.sync()

proc listStaleClient(x11: OverlayX11): tuple[original: seq[int], stale: XId] =
  ## Append a destroyed window id to _NET_CLIENT_LIST, returning the original list.
  result.original = x11.longs(x11.root, x11.atom("_NET_CLIENT_LIST"), XaWindow)
  result.stale = XCreateSimpleWindow(x11.display, x11.root, 0, 0, 1, 1, 0, 0, 0)
  discard XDestroyWindow(x11.display, result.stale)
  x11.setClients(result.original & @[result.stale.int])

proc restoreClients(x11: OverlayX11, original: seq[int]) =
  ## Restore the window manager's client list after a stale-client check.
  x11.setClients(original)
  check x11.longs(x11.root, x11.atom("_NET_CLIENT_LIST"), XaWindow) == original,
    "The client list was not restored."

proc checkStaleClients(x11: OverlayX11, expected: seq[Strut]) =
  ## Put a destroyed window in _NET_CLIENT_LIST and require strut discovery to skip it.
  let (original, stale) = x11.listStaleClient()
  let previous = XSetErrorHandler(recordError)
  check x11.struts() == expected, "A destroyed client changed the discovered struts."
  check recordedErrors == 0, "A vanished client error escaped the struts trap."
  discard XMoveWindow(x11.display, stale, 0, 0)
  check x11.struts() == expected, "A destroyed client changed the discovered struts."
  check recordedErrors == 1, "An error from before discovery must reach the outer handler, not the trap."
  check XSetErrorHandler(previous) == recordError, "Strut discovery did not restore the error handler."
  x11.restoreClients(original)

proc covered(x11: OverlayX11, window: XId, x, y: int): bool =
  ## Report whether a root point lies inside a window's top-level frame.
  let
    frame = x11.attributes(x11.topLevel(window))
  x >= frame.x and y >= frame.y and x < frame.x + frame.width and y < frame.y + frame.height

proc screenshot(x11: OverlayX11, x, y, width, height: int, path: string): Image =
  ## Capture visible root pixels at native resolution and save them as PNG.
  let image = x11.rootImage(x, y, width, height)
  check not image.isNil and image.bitsPerPixel == 32, "Root capture failed."
  defer: freeImage(image)
  result = newImage(width, height)
  for row in 0..<height:
    for column in 0..<width:
      let offset = row * image.bytesPerLine + column * 4
      result[column, row] = rgbx(image.data[offset + 2], image.data[offset + 1], image.data[offset], 255)
  result.writeFile(path)

proc checkGlyph(frame: Image, card: OverlayCard, label: string, font: string,
    atlas: SilkyAtlas, texture: Image, origin: tuple[x, y: int]) =
  ## Require the label's first glyph to match native atlas coverage over the card fill.
  let
    metrics = atlas.fonts[font]
    step = ceil(metrics.lineHeight).int
    top = card.bounds.y + LabelTop + (LabelHeight - step) div 2
    glyph = metrics.entries[$label[0]][0]
    left = origin.x + card.bounds.x + CardPadding + glyph.boundsX.int
    glyphTop = origin.y + round(top.float32 + metrics.ascent + glyph.boundsY).int
    foreground = rgbx(234, 237, 242, 255)
    fill = rgbx(19, 22, 28, 255)
  var ink = 0
  for y in 0..<glyph.boundsHeight.int:
    for x in 0..<glyph.boundsWidth.int:
      let
        alpha = texture[glyph.x + x, glyph.y + y].a.int
        actual = frame[left + x, glyphTop + y]
      if alpha > 0: inc ink
      for (actualChannel, fore, back) in [(actual.r, foreground.r, fill.r),
          (actual.g, foreground.g, fill.g), (actual.b, foreground.b, fill.b)]:
        let expected = (fore.int * alpha + back.int * (255 - alpha) + 127) div 255
        check abs(actualChannel.int - expected) <= 1,
          "Glyph " & label[0] & " was resampled or misplaced at " & $x & ", " & $y
  check ink > 20, "The reference glyph must contain ink."

proc checkFrame(directory: string, atlas: SilkyAtlas, texture: Image) =
  ## Verify the CLI smoke frame: card colors, transparent gaps, and native glyphs.
  let
    frame = readImage(directory / "overlay-frame.png")
    info = parseJson(readFile(directory / "overlay-frame.json"))
    cards = overlayCards(nil)
  check frame.width == OverlayWidth and frame.height == OverlayHeight, "Smoke frame has the wrong size."
  check not info["translucent"].getBool(), "Without a compositor the cards must be opaque."
  let gap = frame[CardWidth + CardGap div 2, CardHeight div 2]
  check gap.r == 0 and gap.g == 0 and gap.b == 0, "Card gaps must be cleared."
  check frame[1, 1] == rgbx(107, 187, 176, 255), "Assigned card border is wrong."
  check frame[CardWidth - 4, CardHeight - 4] == rgbx(19, 22, 28, 255), "Card fill must be opaque."
  frame.checkGlyph(cards[0], "Grok", "Body", atlas, texture, (0, 0))

proc main() =
  ## Run the overlay against a fake daemon on a private Xvfb display with Openbox.
  doAssert getEnv("KNOBBY_GUI_SMOKE") == "1", "Run this only on an isolated smoke display."
  check paramCount() == 2, "Usage: test_overlay RENDERER OUTPUT_DIRECTORY"
  let
    renderer = paramStr(1)
    directory = paramStr(2)
    bytes = readFile(Assets / "atlas.png")
    atlas = extractAtlasJsonFromPng(bytes).fromJson(SilkyAtlas)
    texture = decodeImage(bytes)
  checkFrame(directory, atlas, texture)
  let paths = newButtonPaths(getEnv("XDG_CONFIG_HOME") / "knobby", getEnv("XDG_STATE_HOME") / "knobby")
  createDir(paths.configDir)
  createDir(paths.stateDir)
  writeFileAtomic(paths.configPath(), encodeConfigFile(overlayConfig()))
  initializeButtons(paths, ButtonServices(prepare: fakePrepare, importAsset: fakeImport))
  initializeState("overlay-check")
  check buttonRuntimeStatus()["source"].getStr() == "canonical",
    "Fixture configuration failed: " & buttonRuntimeStatus()["startupError"].getStr()
  let x11 = openOverlayX11()
  defer: x11.close()
  check x11.rootSize() == (ScreenWidth, ScreenHeight), "Unexpected private screen size."
  check not x11.compositorPresent(), "The isolated display must start without a compositor."
  x11.setMonitor("DP-2", 0, LeftWidth, false)
  x11.setMonitor("DP-1", LeftWidth, PrimaryWidth, true)
  x11.setMonitor("HDMI-1", LeftWidth + PrimaryWidth, ScreenWidth - LeftWidth - PrimaryWidth, false)
  check chooseMonitor(x11.monitors()).name == "DP-1", "The private primary monitor is not DP-1."
  var
    fixture = x11.createFixture()
    daemon: Daemon
  daemon.startDaemon()
  defer: daemon.stopDaemon()
  check daemon.pump(x11, fixture, 5000, proc (): bool =
    x11.focus() == fixture.window and x11.struts().len > 0), "The fixture app never received focus."
  fixture.frame = x11.topLevel(fixture.window)
  let dock = x11.attributes(x11.topLevel(fixture.dock))
  check (dock.x.int, dock.y.int) == (LeftWidth, ScreenHeight - DockHeight),
    "The fixture panel is not at the bottom of DP-1."
  var process = startProcess(renderer, options = {poParentStreams})
  defer:
    if process.running: process.terminate()
    discard process.waitForExit()
    process.close()
  var overlay: XId
  check daemon.pump(x11, fixture, 5000, proc (): bool =
    overlay = x11.findOverlay()
    overlay != 0), "The renderer never created its window."
  discard daemon.pump(x11, fixture, 1000)
  check not x11.viewable(overlay), "The overlay must start hidden without a request."

  pressHelp()
  let requestedMs = monotonicMs()
  check daemon.pump(x11, fixture, ShowLimitMs, proc (): bool = x11.viewable(overlay)),
    "The overlay did not appear after a help request."
  let shownMs = monotonicMs() - requestedMs
  check daemon.pump(x11, fixture, ShowLimitMs, proc (): bool =
    x11.longs(overlay, x11.atom(FrameReadyProperty), XaCardinal) == @[1]),
    "The mapped overlay never reported a presented frame."
  check daemon.pump(x11, fixture, MoveLimitMs, proc (): bool =
    let a = x11.attributes(overlay)
    (a.x.int, a.y.int) == (ExpectedX, ExpectedY)), "The overlay is not at the bottom center of DP-1."
  let shown = x11.attributes(overlay)
  check (shown.width.int, shown.height.int) == (OverlayWidth, OverlayHeight), "Overlay size changed."
  check shown.overrideRedirect == 1, "The overlay must be override-redirect."
  check x11.parentOf(overlay) == x11.root, "The window manager must not adopt the overlay."
  for list in ["_NET_CLIENT_LIST", "_NET_CLIENT_LIST_STACKING"]:
    check overlay.int notin x11.longs(x11.root, x11.atom(list)), "The overlay appears in " & list & "."
  check x11.focus() == fixture.window, "Showing the overlay moved keyboard focus."
  check x11.stacking()[^1] == overlay, "The overlay is not above the other windows."
  check x11.shapeRects(overlay, ShapeInput).len == 0, "The overlay must not accept pointer input."
  var expectedShape: seq[PixelRect]
  for card in overlayCards(nil): expectedShape.add(card.bounds)
  check x11.shapeRects(overlay, ShapeBounding) == expectedShape, "The bounding shape must equal the cards."

  let
    shot = x11.screenshot(ExpectedX - ExtraScreenshotMargin, ExpectedY - ExtraScreenshotMargin,
      OverlayWidth + 2 * ExtraScreenshotMargin, OverlayHeight + 2 * ExtraScreenshotMargin,
      directory / "overlay-screen.png")
    origin = (ExtraScreenshotMargin, ExtraScreenshotMargin)
    cards = overlayCards(nil)
  discard x11.screenshot(0, 0, ScreenWidth, ScreenHeight, directory / "overlay-desktop.png")
  shot.checkPixel(origin[0] + CardWidth + CardGap div 2, origin[1] + CardHeight div 2, FixtureRgb,
    "The gap between cards must show the application below.")
  shot.checkPixel(2, 2, FixtureRgb, "The space around the cards must show the application below.")
  shot.checkPixel(origin[0] + 1, origin[1] + 1, rgbx(107, 187, 176, 255), "Card border must be opaque.")
  shot.checkPixel(origin[0] + CardWidth - 4, origin[1] + CardHeight - 4, rgbx(19, 22, 28, 255),
    "Without a compositor the card fill must be opaque.")
  shot.checkGlyph(cards[0], "Grok", "Body", atlas, texture, origin)

  let fixtureStruts = x11.struts()
  x11.checkStaleClients(fixtureStruts)
  let staleClients = x11.listStaleClient()
  discard daemon.pump(x11, fixture, PlacementSettleMs)
  check process.running and x11.viewable(overlay), "A destroyed listed client stopped the renderer."
  x11.restoreClients(staleClients.original)
  check x11.struts() == fixtureStruts, "Restoring the client list changed the fixture struts."

  let
    cardPoint = (ExpectedX + CardWidth div 2, ExpectedY + CardHeight div 2)
    gapPoint = (ExpectedX + CardWidth + CardGap div 2, ExpectedY + CardHeight div 2)
  for point in [cardPoint, gapPoint]:
    check x11.covered(fixture.window, point[0], point[1]), "The fixture does not cover the test point."
    pointerEvent(point[0], point[1], 0)
    pointerEvent(point[0], point[1], 1)
    pointerEvent(point[0], point[1], 2)
  check daemon.pump(x11, fixture, 1000, proc (): bool = fixture.presses.len >= 2),
    "Clicks on and between cards did not reach the application below."
  check fixture.presses == @[cardPoint, gapPoint], "Click-through delivered the wrong points: " & $fixture.presses
  check x11.focus() == fixture.window, "Clicking through the overlay moved focus."
  check x11.viewable(overlay), "Pointer input must not dismiss the overlay."

  discard XRaiseWindow(x11.display, fixture.frame)
  x11.sync()
  check daemon.pump(x11, fixture, 1000, proc (): bool = x11.stacking()[^1] == overlay),
    "The overlay did not return above a raised application."
  routeMixerButton(OtherKey, false)
  routeMixerButton(13, true)
  check daemon.pump(x11, fixture, 300) == false and x11.viewable(overlay),
    "Releases and unknown notes must not dismiss the overlay."

  let refreshAtMs = requestedMs + 3000
  discard daemon.pump(x11, fixture, int(refreshAtMs - monotonicMs()))
  pressHelp()
  let refreshedMs = monotonicMs()
  discard daemon.pump(x11, fixture, int(requestedMs + MixerOverlayDurationMs + 500 - monotonicMs()))
  check x11.viewable(overlay), "Repeated help must refresh the ten-second deadline."
  check daemon.pump(x11, fixture, int(refreshedMs + MixerOverlayDurationMs + HideLimitMs - monotonicMs()),
    proc (): bool = not x11.viewable(overlay)), "The overlay did not hide at its deadline."
  check monotonicMs() >= refreshedMs + MixerOverlayDurationMs - StateIntervalMs,
    "The overlay hid before its refreshed deadline."

  pressHelp()
  check daemon.pump(x11, fixture, ShowLimitMs, proc (): bool = x11.viewable(overlay)), "Help did not reopen."
  discard takeButtonActions()
  routeMixerButton(OtherKey, true)
  routeMixerButton(OtherKey, false)
  check daemon.pump(x11, fixture, HideLimitMs, proc (): bool = not x11.viewable(overlay)),
    "Another button did not dismiss the overlay."
  let actions = takeButtonActions()
  check actions.len == 1 and actions[0]["action"]["kind"].getStr() == "command",
    "The dismissing button must still run its action once."

  pressHelp()
  check daemon.pump(x11, fixture, ShowLimitMs, proc (): bool = x11.viewable(overlay)), "Help did not reopen."
  XRRDeleteMonitor(x11.display, x11.root, x11.atom("DP-1"))
  x11.sync()
  let fallback = x11.overlayPlacement()
  check not fallback.monitor.primary and fallback.monitor.name == x11.monitors()[0].name,
    "Without a primary monitor the first monitor must be used."
  check (fallback.x, fallback.y) != (ExpectedX, ExpectedY), "The fallback placement must differ."
  check daemon.pump(x11, fixture, MoveLimitMs, proc (): bool =
    let a = x11.attributes(overlay)
    (a.x.int, a.y.int) == (fallback.x, fallback.y)), "The overlay did not follow the monitor change."
  x11.setMonitor("DP-1", LeftWidth, PrimaryWidth, true)
  check daemon.pump(x11, fixture, MoveLimitMs, proc (): bool =
    let a = x11.attributes(overlay)
    (a.x.int, a.y.int) == (ExpectedX, ExpectedY)), "The overlay did not return to DP-1."

  daemon.heartbeats = false
  check daemon.pump(x11, fixture, StaleLimitMs, proc (): bool = not x11.viewable(overlay)),
    "A stale daemon snapshot did not hide the overlay."
  daemon.stopDaemon()
  requestHelpEndingIn(ShortDeadlineMs)
  daemon.startDaemon()
  check daemon.pump(x11, fixture, ShowLimitMs + 1500, proc (): bool = x11.viewable(overlay)),
    "The overlay did not reconnect for an active request."
  daemon.stopDaemon()
  check daemon.pump(x11, fixture, HideLimitMs, proc (): bool = not x11.viewable(overlay)),
    "A daemon disconnect did not hide the overlay."
  sleep(ShortDeadlineMs)
  daemon.startDaemon()
  check not daemon.pump(x11, fixture, 2500, proc (): bool = x11.viewable(overlay)),
    "An expired request was replayed after reconnecting."

  requestHelpEndingIn(ShortDeadlineMs)
  check daemon.pump(x11, fixture, ShowLimitMs, proc (): bool = x11.viewable(overlay)), "Help did not reopen."
  process.terminate()
  discard process.waitForExit()
  process.close()
  sleep(ShortDeadlineMs)
  process = startProcess(renderer, options = {poParentStreams})
  check daemon.pump(x11, fixture, 5000, proc (): bool =
    overlay = x11.findOverlay()
    overlay != 0), "The restarted renderer never created its window."
  check not daemon.pump(x11, fixture, 2000, proc (): bool = x11.viewable(overlay)),
    "An expired request was replayed after a renderer restart."
  pressHelp()
  check daemon.pump(x11, fixture, ShowLimitMs, proc (): bool = x11.viewable(overlay)),
    "The restarted renderer did not show a new request."
  check x11.focus() == fixture.window, "The restarted renderer moved focus."

  fixture.compositor = XCreateSimpleWindow(x11.display, x11.root, 0, 0, 1, 1, 0, 0, 0)
  discard XSetSelectionOwner(x11.display, x11.atom("_NET_WM_CM_S" & $x11.screen), fixture.compositor, 0)
  x11.sync()
  check x11.compositorPresent(), "Compositor detection missed a _NET_WM_CM owner."
  discard XDestroyWindow(x11.display, fixture.compositor)
  x11.sync()
  check not x11.compositorPresent(), "Compositor detection kept a vanished owner."
  writeFile(directory / "overlay-check.json", $(%*{"showLatencyMs": shownMs,
    "x": ExpectedX, "y": ExpectedY, "fallback": {"monitor": fallback.monitor.name,
    "x": fallback.x, "y": fallback.y}}))

when isMainModule:
  main()

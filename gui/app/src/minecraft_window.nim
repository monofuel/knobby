import
  std/[locks, monotimes, os, strformat, strutils, times]

type
  MinecraftWindowError* = object of CatchableError
    ## Raised when the Minecraft client window cannot be selected or resized.

  WindowState* = enum
    ## EWMH states that keep a window from taking an exact client size.
    wsFullscreen, wsMaximizedVert, wsMaximizedHorz

  ClientWindow* = object
    ## A window-manager client with its client-area geometry in root coordinates.
    id*: uint64
    instance*, class*, title*: string
    x*, y*, width*, height*, processId*: int
    states*: set[WindowState]

  XWindow = culong
  XAtom = culong

  XErrorEvent = object
    kind: cint
    display: pointer
    resourceId: culong
    serial: culong
    errorCode, requestCode, minorCode: uint8

  XErrorHandler = proc (display: pointer, event: ptr XErrorEvent): cint {.cdecl.}

  XClientMessageEvent = object
    kind: cint
    serial: culong
    sendEvent: cint
    display: pointer
    window: XWindow
    messageType: XAtom
    format: cint
    data: array[5, clong]

  XEvent {.union.} = object
    client: XClientMessageEvent
    pad: array[24, clong]

  XSession = object
    display: pointer
    name: string
    root: XWindow
    previousHandler: XErrorHandler
    clientList, wmState, fullscreen, maximizedVert, maximizedHorz: XAtom
    moveResize, supportingWmCheck, wmClass, netWmName, utf8String: XAtom

const
  TargetWidth* = 1920
  TargetHeight* = 1080
  MinecraftClassPrefix* = "Minecraft"
  ExcludedClassFragment = "launcher"
  LibX11 = "libX11.so(|.6)"
  MaxClientWindows = 4096
  MaxTextBytes = 4096
  ResizeAttempts = 3
  AttemptTimeoutMs = 1000
  StableMs = 250
  PollMs = 25
  XSuccess = 0
  BadWindow = 3
  AnyPropertyType = XAtom(0)
  XaAtom = XAtom(4)
  XaWindow = XAtom(33)
  XaWmName = XAtom(39)
  ClientMessage = cint(33)
  SubstructureNotifyMask = clong(1 shl 19)
  SubstructureRedirectMask = clong(1 shl 20)
  NetWmStateRemove = clong(0)
  SourcePager = clong(2)
  MoveResizeSizeFlags = clong((1 shl 10) or (1 shl 11)) or (SourcePager shl 12)
  BlockingStates = {wsFullscreen, wsMaximizedVert, wsMaximizedHorz}

var
  pendingXError: int
  pendingXRequest: int
  operationLock: Lock

initLock(operationLock)

proc XOpenDisplay(name: cstring): pointer {.cdecl, importc, dynlib: LibX11.}
proc XCloseDisplay(display: pointer): cint {.cdecl, importc, dynlib: LibX11.}
proc XDefaultRootWindow(display: pointer): XWindow {.cdecl, importc, dynlib: LibX11.}
proc XInternAtom(display: pointer, name: cstring, onlyIfExists: cint): XAtom {.cdecl, importc, dynlib: LibX11.}
proc XGetWindowProperty(display: pointer, window: XWindow, property: XAtom,
    offset, length: clong, delete: cint, requiredType: XAtom, actualType: ptr XAtom,
    actualFormat: ptr cint, itemCount, bytesAfter: ptr culong,
    data: ptr pointer): cint {.cdecl, importc, dynlib: LibX11.}
proc XFree(data: pointer): cint {.cdecl, importc, dynlib: LibX11.}
proc XSendEvent(display: pointer, window: XWindow, propagate: cint, mask: clong,
    event: ptr XEvent): cint {.cdecl, importc, dynlib: LibX11.}
proc XSync(display: pointer, discardEvents: cint): cint {.cdecl, importc, dynlib: LibX11.}
proc XGetGeometry(display: pointer, drawable: XWindow, root: ptr XWindow,
    x, y: ptr cint, width, height, border, depth: ptr cuint): cint {.cdecl, importc, dynlib: LibX11.}
proc XTranslateCoordinates(display: pointer, source, destination: XWindow,
    sourceX, sourceY: cint, destinationX, destinationY: ptr cint,
    child: ptr XWindow): cint {.cdecl, importc, dynlib: LibX11.}
proc XSetErrorHandler(handler: XErrorHandler): XErrorHandler {.cdecl, importc, dynlib: LibX11.}
proc XGetErrorText(display: pointer, code: cint, buffer: cstring,
    length: cint): cint {.cdecl, importc, dynlib: LibX11.}

proc windowLabel*(id: uint64): string =
  ## Format an X11 window identifier the way wmctrl and xprop print it.
  "0x" & id.toHex(8).toLowerAscii()

proc parseWmClass*(raw: string): tuple[instance, class: string] =
  ## Split a raw WM_CLASS property into its NUL-separated instance and class names.
  let parts = raw.split('\0')
  if parts.len > 0: result.instance = parts[0]
  if parts.len > 1: result.class = parts[1]

proc isMinecraftClient*(instance, class: string): bool =
  ## Match the game window by WM_CLASS prefix while excluding launcher windows.
  let excluded = ExcludedClassFragment in instance.toLowerAscii() or
    ExcludedClassFragment in class.toLowerAscii()
  not excluded and (instance.startsWith(MinecraftClassPrefix) or
    class.startsWith(MinecraftClassPrefix))

proc describe*(window: ClientWindow): string =
  ## Summarize a client window for diagnostics.
  &"{windowLabel(window.id)} \"{window.title}\" ({window.instance}.{window.class}) " &
    &"{window.width}x{window.height}"

proc selectMinecraftWindow*(windows: openArray[ClientWindow]): ClientWindow =
  ## Choose the single Minecraft client window, raising when none or several match.
  var matches: seq[ClientWindow]
  for window in windows:
    if isMinecraftClient(window.instance, window.class): matches.add(window)
  if matches.len == 0:
    raise newException(MinecraftWindowError,
      &"No Minecraft client window found among {windows.len} managed windows; " &
      &"WM_CLASS must start with \"{MinecraftClassPrefix}\" and launchers are excluded.")
  if matches.len > 1:
    var labels: seq[string]
    for window in matches: labels.add(window.describe())
    raise newException(MinecraftWindowError,
      &"Found {matches.len} Minecraft client windows; refusing to guess between " &
      labels.join(", ") & ".")
  matches[0]

proc recordXError(display: pointer, event: ptr XErrorEvent): cint {.cdecl.} =
  ## Record the first X protocol error so callers raise it instead of Xlib exiting.
  if pendingXError == 0:
    pendingXError = event.errorCode.int
    pendingXRequest = event.requestCode.int

proc takeXError(): int =
  ## Return and clear the pending X protocol error code.
  result = pendingXError
  pendingXError = 0

proc raiseOnXError(session: XSession, action: string) =
  ## Raise a descriptive error if the previous X requests failed.
  discard XSync(session.display, 0)
  let
    request = pendingXRequest
    code = takeXError()
  if code != 0:
    var buffer = newString(128)
    discard XGetErrorText(session.display, code.cint, buffer.cstring, buffer.len.cint)
    raise newException(MinecraftWindowError,
      &"X error while {action} on display {session.name}: {$buffer.cstring} " &
      &"(code {code}, request {request}).")

proc atom(session: XSession, name: string): XAtom =
  ## Intern an EWMH atom on the session display.
  XInternAtom(session.display, name.cstring, 0)

proc readProperty(session: XSession, window: XWindow, property, kind: XAtom,
    maxLongs: int): tuple[format: int, data: string, items: int, truncated: bool] =
  ## Read a bounded window property as raw bytes; missing properties are empty.
  var
    actualType: XAtom
    actualFormat: cint
    itemCount, bytesAfter: culong
    data: pointer
  let status = XGetWindowProperty(session.display, window, property, 0,
    maxLongs.clong, 0, kind, addr actualType, addr actualFormat,
    addr itemCount, addr bytesAfter, addr data)
  if data != nil:
    defer: discard XFree(data)
    if status == XSuccess and actualType != AnyPropertyType:
      let itemSize = case actualFormat
        of 8: 1
        of 16: sizeof(cshort)
        else: sizeof(clong)
      result.format = actualFormat.int
      result.items = itemCount.int
      result.truncated = bytesAfter > 0
      result.data = newString(itemCount.int * itemSize)
      if result.data.len > 0: copyMem(addr result.data[0], data, result.data.len)

proc readLongs(session: XSession, window: XWindow, property, kind: XAtom,
    maxItems: int): tuple[values: seq[culong], truncated: bool] =
  ## Read a format-32 property of atoms or windows as unsigned longs.
  let raw = session.readProperty(window, property, kind, maxItems)
  result.truncated = raw.truncated
  if raw.format == 32:
    result.values = newSeq[culong](raw.items)
    if raw.items > 0: copyMem(addr result.values[0], unsafeAddr raw.data[0], raw.data.len)

proc readStates(session: XSession, window: XWindow): set[WindowState] =
  ## Read the fullscreen and maximized EWMH states of a client window.
  for state in session.readLongs(window, session.wmState, XaAtom, 64).values:
    if state == session.fullscreen: result.incl(wsFullscreen)
    elif state == session.maximizedVert: result.incl(wsMaximizedVert)
    elif state == session.maximizedHorz: result.incl(wsMaximizedHorz)

proc readTitle(session: XSession, window: XWindow): string =
  ## Read the UTF-8 EWMH title, falling back to the legacy WM_NAME.
  let longs = MaxTextBytes div 4
  result = session.readProperty(window, session.netWmName, session.utf8String, longs).data
  if result.len == 0:
    result = session.readProperty(window, XaWmName, AnyPropertyType, longs).data

proc describeWindow(session: XSession, id: XWindow): ClientWindow =
  ## Snapshot a client's identity, client-area geometry, and blocking states.
  result.id = id.uint64
  let pids = session.readLongs(id, session.atom("_NET_WM_PID"), XAtom(6), 1).values
  if pids.len == 1: result.processId = pids[0].int
  let names = parseWmClass(session.readProperty(id, session.wmClass, AnyPropertyType,
    MaxTextBytes div 4).data)
  result.instance = names.instance
  result.class = names.class
  result.title = session.readTitle(id)
  result.states = session.readStates(id)
  var
    root, child: XWindow
    x, y: cint
    width, height, border, depth: cuint
  if XGetGeometry(session.display, id, addr root, addr x, addr y, addr width,
      addr height, addr border, addr depth) != 0:
    result.width = width.int
    result.height = height.int
  if XTranslateCoordinates(session.display, id, session.root, 0, 0, addr x,
      addr y, addr child) != 0:
    result.x = x.int
    result.y = y.int

proc openSession(displayName: string): XSession =
  ## Connect to the X display and install the recording error handler.
  result.name = if displayName.len > 0: displayName else: getEnv("DISPLAY")
  result.display = XOpenDisplay(if displayName.len > 0: displayName.cstring else: nil)
  if result.display == nil:
    raise newException(MinecraftWindowError,
      &"Cannot open X display \"{result.name}\" to resize Minecraft.")
  discard takeXError()
  result.previousHandler = XSetErrorHandler(recordXError)
  result.root = XDefaultRootWindow(result.display)
  result.clientList = result.atom("_NET_CLIENT_LIST")
  result.wmState = result.atom("_NET_WM_STATE")
  result.fullscreen = result.atom("_NET_WM_STATE_FULLSCREEN")
  result.maximizedVert = result.atom("_NET_WM_STATE_MAXIMIZED_VERT")
  result.maximizedHorz = result.atom("_NET_WM_STATE_MAXIMIZED_HORZ")
  result.moveResize = result.atom("_NET_MOVERESIZE_WINDOW")
  result.supportingWmCheck = result.atom("_NET_SUPPORTING_WM_CHECK")
  result.wmClass = result.atom("WM_CLASS")
  result.netWmName = result.atom("_NET_WM_NAME")
  result.utf8String = result.atom("UTF8_STRING")

proc closeSession(session: XSession) =
  ## Restore the previous error handler and close the X connection.
  discard XSync(session.display, 1)
  discard takeXError()
  discard XSetErrorHandler(session.previousHandler)
  discard XCloseDisplay(session.display)

proc clientWindows(session: XSession): seq[ClientWindow] =
  ## List managed client windows, skipping windows destroyed during enumeration.
  let wmCheck = session.readLongs(session.root, session.supportingWmCheck, XaWindow, 1)
  session.raiseOnXError("checking for an EWMH window manager")
  if wmCheck.values.len == 0:
    raise newException(MinecraftWindowError,
      &"No EWMH window manager (such as Openbox) is running on display {session.name}.")
  let list = session.readLongs(session.root, session.clientList, XaWindow, MaxClientWindows)
  session.raiseOnXError("listing client windows")
  if list.truncated:
    raise newException(MinecraftWindowError,
      &"More than {MaxClientWindows} client windows on display {session.name}.")
  for id in list.values:
    let window = session.describeWindow(id)
    discard XSync(session.display, 0)
    if pendingXError == BadWindow:
      discard takeXError()
    else:
      session.raiseOnXError(&"reading window {windowLabel(id.uint64)}")
      result.add(window)

proc refresh(session: XSession, window: ClientWindow): ClientWindow =
  ## Re-read the selected window, raising if it disappeared.
  result = session.describeWindow(XWindow(window.id))
  session.raiseOnXError(&"reading Minecraft window {windowLabel(window.id)}; " &
    "it may have closed")

proc sendRootMessage(session: XSession, window: ClientWindow, messageType: XAtom,
    data: array[5, clong]) =
  ## Ask the window manager to change one client through a root client message.
  var event: XEvent
  event.client = XClientMessageEvent(kind: ClientMessage, window: XWindow(window.id),
    messageType: messageType, format: 32, data: data)
  discard XSendEvent(session.display, session.root, 0,
    SubstructureRedirectMask or SubstructureNotifyMask, addr event)
  session.raiseOnXError(&"sending a window-manager request for {windowLabel(window.id)}")

proc requestNormalState(session: XSession, window: ClientWindow) =
  ## Remove fullscreen and maximized states present on the selected window only.
  if wsFullscreen in window.states:
    session.sendRootMessage(window, session.wmState,
      [NetWmStateRemove, clong(session.fullscreen), 0, SourcePager, 0])
  if window.states * {wsMaximizedVert, wsMaximizedHorz} != {}:
    session.sendRootMessage(window, session.wmState, [NetWmStateRemove,
      clong(session.maximizedVert), clong(session.maximizedHorz), SourcePager, 0])

proc requestTargetSize(session: XSession, window: ClientWindow) =
  ## Ask the window manager for an exact client size, leaving position unchanged.
  session.sendRootMessage(window, session.moveResize,
    [MoveResizeSizeFlags, 0, 0, clong(TargetWidth), clong(TargetHeight)])

proc atTarget(window: ClientWindow): bool =
  ## Check for an unmaximized, non-fullscreen client area of exactly 1920x1080.
  window.width == TargetWidth and window.height == TargetHeight and
    window.states * BlockingStates == {}

proc settle(session: XSession, window: ClientWindow): ClientWindow =
  ## Drive one bounded attempt toward the target, polling until it holds or times out.
  result = window
  let deadline = getMonoTime() + initDuration(milliseconds = AttemptTimeoutMs)
  if result.states * BlockingStates != {}:
    session.requestNormalState(result)
    while result.states * BlockingStates != {} and getMonoTime() < deadline:
      sleep(PollMs)
      result = session.refresh(result)
  if result.states * BlockingStates == {} and not result.atTarget():
    session.requestTargetSize(result)
    while not result.atTarget() and getMonoTime() < deadline:
      sleep(PollMs)
      result = session.refresh(result)
  if result.atTarget():
    sleep(StableMs)
    result = session.refresh(result)

proc listClientWindows*(displayName = ""): seq[ClientWindow] {.gcsafe.} =
  ## Snapshot every managed client window on the display without changing any.
  withLock operationLock:
    let session = openSession(displayName)
    defer: session.closeSession()
    result = session.clientWindows()

proc resizeMinecraft1080*(displayName = ""): ClientWindow {.gcsafe.} =
  ## Make the Minecraft client area exactly 1920x1080 and return its verified state.
  ## Only the selected window is changed: fullscreen and maximized states are
  ## removed, the size is requested through the EWMH window manager, and the
  ## position, focus, stacking, and screen resolution are left alone. It
  ## installs a process-wide Xlib error handler while running, so callers should
  ## not use Xlib concurrently from other threads.
  withLock operationLock:
    let session = openSession(displayName)
    defer: session.closeSession()
    var window = selectMinecraftWindow(session.clientWindows())
    for _ in 1..ResizeAttempts:
      if not window.atTarget():
        window = session.settle(window)
    if not window.atTarget():
      raise newException(MinecraftWindowError,
        &"Minecraft window {window.describe()} did not reach {TargetWidth}x{TargetHeight} " &
        &"after {ResizeAttempts} attempts (states: {window.states}); its size hints or " &
        "the window manager may be preventing the exact size.")
    result = window

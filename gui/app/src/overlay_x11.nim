import
  ./overlay_layout

type
  XDisplay* = pointer
  XId* = culong
  Atom* = culong
  XRectangle* = object
    x*, y*: cshort
    width*, height*: cushort
  XSetWindowAttributes = object
    backgroundPixmap, backgroundPixel, borderPixmap, borderPixel: culong
    bitGravity, winGravity, backingStore: cint
    backingPlanes, backingPixel: culong
    saveUnder: cint
    eventMask, doNotPropagateMask: clong
    overrideRedirect: cint
    colormap, cursor: culong
  XWmHints = object
    flags: clong
    input, initialState: cint
    iconPixmap, iconWindow: culong
    iconX, iconY: cint
    iconMask, windowGroup: culong
  XRRMonitorInfo* = object
    name*: Atom
    primary*, automatic*, noutput*: cint
    x*, y*, width*, height*, mwidth*, mheight*: cint
    outputs*: pointer
  XImage* = object
    width*, height*, xoffset*, format*: cint
    data*: ptr UncheckedArray[uint8]
    byteOrder*, bitmapUnit*, bitmapBitOrder*, bitmapPad*, depth*, bytesPerLine*, bitsPerPixel*: cint
  OverlayX11* = ref object
    ## A private Xlib connection that adjusts the renderer's window by its X id.
    display*: XDisplay
    root*: XId
    screen*: cint

const
  LibX11 = "libX11.so(|.6)"
  LibXext = "libXext.so(|.6)"
  LibXrandr = "libXrandr.so(|.2)"
  CwOverrideRedirect = culong(1 shl 9)
  InputHint = clong(1)
  ShapeBounding* = cint(0)
  ShapeInput* = cint(2)
  ShapeSet = cint(0)
  YXBanded = cint(3)
  PropModeReplace = cint(0)
  XaAtom = Atom(4)
  XaCardinal = Atom(6)
  XaWindow = Atom(33)
  AnyPropertyType = Atom(0)
  Success = cint(0)
  MaxPropertyLongs = clong(4096)
  StrutPartialFields = 12
  StrutFields = 4

{.push cdecl, importc, dynlib: LibX11.}
proc XOpenDisplay(name: cstring): XDisplay
proc XCloseDisplay(display: XDisplay): cint
proc XFlush(display: XDisplay): cint
proc XSync(display: XDisplay, discardEvents: cint): cint
proc XDefaultScreen(display: XDisplay): cint
proc XRootWindow(display: XDisplay, screen: cint): XId
proc XDisplayWidth(display: XDisplay, screen: cint): cint
proc XDisplayHeight(display: XDisplay, screen: cint): cint
proc XInternAtom(display: XDisplay, name: cstring, onlyIfExists: cint): Atom
proc XGetAtomName(display: XDisplay, atom: Atom): cstring
proc XGetSelectionOwner(display: XDisplay, selection: Atom): XId
proc XChangeWindowAttributes(display: XDisplay, window: XId, mask: culong,
  attributes: ptr XSetWindowAttributes): cint
proc XSetWMHints(display: XDisplay, window: XId, hints: ptr XWmHints): cint
proc XChangeProperty(display: XDisplay, window: XId, property, kind: Atom, format, mode: cint,
  data: pointer, count: cint): cint
proc XGetWindowProperty(display: XDisplay, window: XId, property: Atom, offset, length: clong,
  delete: cint, requested: Atom, actualType: ptr Atom, actualFormat: ptr cint,
  count, remaining: ptr culong, data: ptr pointer): cint
proc XFree(data: pointer): cint
proc XMoveWindow(display: XDisplay, window: XId, x, y: cint): cint
proc XRaiseWindow(display: XDisplay, window: XId): cint
proc XQueryTree(display: XDisplay, window: XId, root, parent: ptr XId,
  children: ptr ptr UncheckedArray[XId], count: ptr cuint): cint
proc XGetImage(display: XDisplay, drawable: XId, x, y: cint, width, height: cuint,
  planes: culong, format: cint): ptr XImage
{.pop.}

{.push cdecl, importc, dynlib: LibXext.}
proc XShapeQueryExtension(display: XDisplay, eventBase, errorBase: ptr cint): cint
proc XShapeCombineRectangles(display: XDisplay, window: XId, kind, x, y: cint,
  rectangles: ptr XRectangle, count, operation, ordering: cint)
proc XShapeGetRectangles(display: XDisplay, window: XId, kind: cint, count,
  ordering: ptr cint): ptr UncheckedArray[XRectangle]
{.pop.}

{.push cdecl, importc, dynlib: LibXrandr.}
proc XRRGetMonitors(display: XDisplay, window: XId, active: cint,
  count: ptr cint): ptr UncheckedArray[XRRMonitorInfo]
proc XRRFreeMonitors(monitors: ptr UncheckedArray[XRRMonitorInfo])
{.pop.}

proc openOverlayX11*(): OverlayX11 =
  ## Open a private connection to the current DISPLAY and require the Shape extension.
  let display = XOpenDisplay(nil)
  if display.isNil:
    raise newException(IOError, "Cannot open the X display for the overlay.")
  var eventBase, errorBase: cint
  if XShapeQueryExtension(display, eventBase.addr, errorBase.addr) == 0:
    discard XCloseDisplay(display)
    raise newException(IOError, "The X server lacks the Shape extension the overlay needs.")
  let screen = XDefaultScreen(display)
  OverlayX11(display: display, screen: screen, root: XRootWindow(display, screen))

proc close*(x11: OverlayX11) =
  ## Close the private connection.
  if not x11.display.isNil:
    discard XCloseDisplay(x11.display)
    x11.display = nil

proc sync*(x11: OverlayX11) =
  ## Wait until the server processed this connection's requests.
  discard XSync(x11.display, 0)

proc atom*(x11: OverlayX11, name: string): Atom =
  ## Intern an atom by name.
  XInternAtom(x11.display, name.cstring, 0)

proc rootSize*(x11: OverlayX11): tuple[width, height: int] =
  ## Return the root window size in pixels.
  (XDisplayWidth(x11.display, x11.screen).int, XDisplayHeight(x11.display, x11.screen).int)

proc longs*(x11: OverlayX11, window: XId, property: Atom, kind = AnyPropertyType): seq[int] =
  ## Read a 32-bit format property, which Xlib returns as C longs.
  var
    actualType: Atom
    actualFormat: cint
    count, remaining: culong
    data: pointer
  if XGetWindowProperty(x11.display, window, property, 0, MaxPropertyLongs, 0, kind,
      actualType.addr, actualFormat.addr, count.addr, remaining.addr, data.addr) != Success:
    return
  if not data.isNil:
    if actualFormat == 32:
      let values = cast[ptr UncheckedArray[clong]](data)
      for index in 0..<count.int:
        result.add(values[index].int)
    discard XFree(data)

proc compositorPresent*(x11: OverlayX11): bool =
  ## Report whether a compositing manager owns this screen's _NET_WM_CM selection.
  XGetSelectionOwner(x11.display, x11.atom("_NET_WM_CM_S" & $x11.screen)) != 0

proc monitors*(x11: OverlayX11): seq[Monitor] =
  ## List active RandR monitors with their names and primary flag.
  var count: cint
  let list = XRRGetMonitors(x11.display, x11.root, 1, count.addr)
  if list.isNil:
    return
  defer: XRRFreeMonitors(list)
  for index in 0..<count.int:
    let
      info = list[index]
      name = XGetAtomName(x11.display, info.name)
    result.add(Monitor(name: if name.isNil: "" else: $name, primary: info.primary != 0,
      bounds: PixelRect(x: info.x, y: info.y, width: info.width, height: info.height)))
    if not name.isNil: discard XFree(name)

proc struts*(x11: OverlayX11): seq[Strut] =
  ## Read panel reservations from managed clients, preferring partial struts.
  let
    (width, height) = x11.rootSize()
    partial = x11.atom("_NET_WM_STRUT_PARTIAL")
    full = x11.atom("_NET_WM_STRUT")
  for client in x11.longs(x11.root, x11.atom("_NET_CLIENT_LIST"), XaWindow):
    let values = x11.longs(XId(client), partial, XaCardinal)
    if values.len >= StrutPartialFields:
      result.add(Strut(left: values[0], right: values[1], top: values[2], bottom: values[3],
        leftStartY: values[4], leftEndY: values[5], rightStartY: values[6], rightEndY: values[7],
        topStartX: values[8], topEndX: values[9], bottomStartX: values[10], bottomEndX: values[11]))
    else:
      let legacy = x11.longs(XId(client), full, XaCardinal)
      if legacy.len >= StrutFields:
        result.add(Strut(left: legacy[0], right: legacy[1], top: legacy[2], bottom: legacy[3],
          leftEndY: height - 1, rightEndY: height - 1, topEndX: width - 1, bottomEndX: width - 1))

proc overlayPlacement*(x11: OverlayX11): tuple[monitor: Monitor, x, y: int] =
  ## Place the overlay at the bottom center of the primary monitor's usable area.
  let
    (width, height) = x11.rootSize()
    available = x11.monitors()
    monitor = if available.len > 0: chooseMonitor(available)
      else: Monitor(name: "screen", bounds: PixelRect(width: width, height: height))
    origin = overlayOrigin(usableArea(monitor, width, height, x11.struts()))
  (monitor, origin.x, origin.y)

proc setShape*(x11: OverlayX11, window: XId, kind: cint, rects: openArray[PixelRect]) =
  ## Replace one shape region of a window with exact rectangles; none means empty.
  var shape: seq[XRectangle]
  for rect in rects:
    shape.add(XRectangle(x: rect.x.cshort, y: rect.y.cshort,
      width: rect.width.cushort, height: rect.height.cushort))
  XShapeCombineRectangles(x11.display, window, kind, 0, 0,
    if shape.len > 0: shape[0].addr else: nil, shape.len.cint, ShapeSet, YXBanded)

proc shapeRects*(x11: OverlayX11, window: XId, kind: cint): seq[PixelRect] =
  ## Read one shape region of a window back from the server.
  var count, ordering: cint
  let rects = XShapeGetRectangles(x11.display, window, kind, count.addr, ordering.addr)
  if rects.isNil:
    return
  for index in 0..<count.int:
    result.add(PixelRect(x: rects[index].x.int, y: rects[index].y.int,
      width: rects[index].width.int, height: rects[index].height.int))
  discard XFree(rects)

proc setPassiveOverlay*(x11: OverlayX11, window: XId, cards: openArray[PixelRect]) =
  ## Make an unmapped window unmanaged, unfocusable, click-through, and shaped to its cards.
  ## Override-redirect must be set before the first map so no window manager adopts it.
  var attributes = XSetWindowAttributes(overrideRedirect: 1)
  discard XChangeWindowAttributes(x11.display, window, CwOverrideRedirect, attributes.addr)
  var hints = XWmHints(flags: InputHint, input: 0)
  discard XSetWMHints(x11.display, window, hints.addr)
  var
    windowType = [x11.atom("_NET_WM_WINDOW_TYPE_NOTIFICATION")]
    states = [x11.atom("_NET_WM_STATE_ABOVE"), x11.atom("_NET_WM_STATE_SKIP_TASKBAR"),
      x11.atom("_NET_WM_STATE_SKIP_PAGER")]
  discard XChangeProperty(x11.display, window, x11.atom("_NET_WM_WINDOW_TYPE"), XaAtom, 32,
    PropModeReplace, windowType[0].addr, windowType.len.cint)
  discard XChangeProperty(x11.display, window, x11.atom("_NET_WM_STATE"), XaAtom, 32,
    PropModeReplace, states[0].addr, states.len.cint)
  x11.setShape(window, ShapeBounding, cards)
  x11.setShape(window, ShapeInput, [])
  x11.sync()

proc move*(x11: OverlayX11, window: XId, x, y: int) =
  ## Move an override-redirect window directly.
  discard XMoveWindow(x11.display, window, x.cint, y.cint)
  discard XFlush(x11.display)

proc stacking*(x11: OverlayX11): seq[XId] =
  ## Return the root's children from bottom to top.
  var
    root, parent: XId
    children: ptr UncheckedArray[XId]
    count: cuint
  if XQueryTree(x11.display, x11.root, root.addr, parent.addr, children.addr, count.addr) == 0:
    return
  if not children.isNil:
    for index in 0..<count.int:
      result.add(children[index])
    discard XFree(children)

proc parentOf*(x11: OverlayX11, window: XId): XId =
  ## Return a window's parent, which is the root unless a window manager reparented it.
  var
    root: XId
    children: ptr UncheckedArray[XId]
    count: cuint
  if XQueryTree(x11.display, window, root.addr, result.addr, children.addr, count.addr) != 0 and
      not children.isNil:
    discard XFree(children)

proc keepAbove*(x11: OverlayX11, window: XId) =
  ## Raise the overlay when another top-level window was stacked over it, without focusing it.
  let order = x11.stacking()
  if order.len > 0 and order[^1] != window:
    discard XRaiseWindow(x11.display, window)
    discard XFlush(x11.display)

proc rootImage*(x11: OverlayX11, x, y, width, height: int): ptr XImage =
  ## Capture part of the root window's visible pixels; free the result with freeImage.
  const ZPixmap = cint(2)
  XGetImage(x11.display, x11.root, x.cint, y.cint, width.cuint, height.cuint, not culong(0), ZPixmap)

proc freeImage*(image: ptr XImage) =
  ## Release an image returned by rootImage.
  if not image.isNil:
    discard XFree(image.data)
    discard XFree(image)

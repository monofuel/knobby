import
  std/[os, osproc, strutils],
  windy/platforms/linux/x11/[x, xevent, xlib],
  knobby/[gui_activation, ipc]

const
  WaitMs = 5000
  PollMs = 20

proc queryTree(d: Display, w: x.Window, root, parent: ptr x.Window,
    children: ptr ptr UncheckedArray[x.Window], count: ptr cuint): cint {.cdecl, importc: "XQueryTree", dynlib: libX11.}
  ## Enumerate windows on the isolated smoke display.
proc fetchName(d: Display, w: x.Window, name: ptr cstring): cint {.cdecl, importc: "XFetchName", dynlib: libX11.}
  ## Obtain a window title for locating the viewer beneath Openbox decorations.
proc closeDisplay(d: Display): cint {.cdecl, importc: "XCloseDisplay", dynlib: libX11.}
  ## Close the test controller's separate X11 connection.

proc findViewers(d: Display, parent: x.Window, depth = 0): seq[x.Window] =
  ## Find the viewer without assuming its window-manager reparenting structure.
  if depth > 4: return
  var
    root, parentId: x.Window
    children: ptr UncheckedArray[x.Window]
    count: cuint
  if queryTree(d, parent, addr root, addr parentId, addr children, addr count) == 0: return
  defer:
    if children != nil: XFree(children)
  for index in 0..<count.int:
    let child = children[index]
    var title: cstring
    if fetchName(d, child, addr title) != 0 and title != nil:
      if $title == "Knobby": result.add(child)
      XFree(title)
    result.add(findViewers(d, child, depth + 1))

proc mapped(d: Display, window: x.Window): bool =
  ## Check real X11 visibility instead of relying on application bookkeeping.
  var attributes: XWindowAttributes
  XGetWindowAttributes(d, window, addr attributes)
  attributes.map_state == IsViewable

proc waitFor(condition: proc (): bool, description: string) =
  ## Give an asynchronous desktop transition a bounded time to finish.
  let deadline = monotonicMs() + WaitMs
  while not condition():
    if monotonicMs() >= deadline: raise newException(IOError, description)
    sleep(PollMs)

proc checked(args: seq[string]): string =
  ## Execute a private-session test command and retain useful failure output.
  let (output, code) = execCmdEx(quoteShellCommand(args))
  if code != 0: raise newException(IOError, output)
  output

proc trayService(): string =
  ## Find the SNI interface without relying on optional process-credential metadata.
  for line in checked(@["busctl", "--user", "--no-pager", "--no-legend", "list"]).splitLines():
    let fields = line.splitWhitespace()
    if fields.len >= 1 and fields[0].startsWith(":"):
      let (output, code) = execCmdEx(quoteShellCommand(@["busctl", "--user", "--timeout=1s",
        "get-property", fields[0], "/StatusNotifierItem", "org.kde.StatusNotifierItem", "Id"]))
      if code == 0 and "knobby" in output:
        return fields[0]

proc main() =
  ## Exercise hidden startup, activation, reuse, hiding, clean quit, and recovery.
  doAssert getEnv("KNOBBY_GUI_SMOKE") == "1"
  let
    binary = paramStr(1).absolutePath()
    display = XOpenDisplay(nil)
  doAssert display != nil
  defer: discard closeDisplay(display)
  var process = startProcess(binary, args = @["--background"], options = {poParentStreams})
  defer:
    if process.running(): process.terminate()
    discard process.waitForExit()
    process.close()
  waitFor(proc (): bool = findViewers(display, display.defaultRootWindow()).len == 1,
    "Background viewer did not become ready.")
  let window = findViewers(display, display.defaultRootWindow())[0]
  doAssert not mapped(display, window), "Background startup mapped a window."
  sleep(250)
  doAssert not mapped(display, window), "Missing tray host opened a window."
  activateExisting(runtimePath("knobby-gui", "activate.sock"), WaitMs)
  waitFor(proc (): bool = mapped(display, window), "Initial activation did not show the window.")
  var clients: seq[Process]
  for _ in 0..1: clients.add(startProcess(binary, options = {poParentStreams}))
  for client in clients:
    doAssert client.waitForExit(WaitMs) == 0
    client.close()
  waitFor(proc (): bool = mapped(display, window), "Activation did not show the window.")
  doAssert findViewers(display, display.defaultRootWindow()).len == 1
  var
    focused: x.Window
    revert: RevertTo
  XGetInputFocus(display, addr focused, addr revert)
  doAssert focused == window, "Activation did not focus the viewer."
  var service = ""
  waitFor(proc (): bool =
    service = trayService()
    service.len > 0, "Viewer tray connection was not found.")
  discard checked(@["busctl", "--user", "call", service, "/Menu",
    "com.canonical.dbusmenu", "Event", "isvu", "1", "clicked", "s", "", "0"])
  var event: XEvent
  event.client.kind = xeClientMessage
  event.client.window = window
  event.client.message_type = XInternAtom(display, "WM_PROTOCOLS", 0)
  event.client.format = 32
  event.client.data.l[0] = XInternAtom(display, "WM_DELETE_WINDOW", 0).clong
  XSendEvent(display, window, false, 0, addr event)
  XFlush(display)
  waitFor(proc (): bool = not mapped(display, window), "Close did not hide the viewer.")
  doAssert process.running()
  activateExisting(runtimePath("knobby-gui", "activate.sock"), WaitMs)
  waitFor(proc (): bool = mapped(display, window), "Hidden viewer could not be restored.")
  discard checked(@["busctl", "--user", "call", service, "/Menu",
    "com.canonical.dbusmenu", "Event", "isvu", "2", "clicked", "s", "", "0"])
  doAssert process.waitForExit(WaitMs) == 0, "Quit viewer was not a clean exit."
  waitFor(proc (): bool = findViewers(display, display.defaultRootWindow()).len == 0,
    "The old viewer's window did not disappear after quitting.")
  process.close()
  process = startProcess(binary, args = @["--background"], options = {poParentStreams})
  waitFor(proc (): bool = findViewers(display, display.defaultRootWindow()).len == 1,
    "Viewer could not restart after a clean quit.")
  activateExisting(runtimePath("knobby-gui", "activate.sock"), WaitMs)
  doAssert mapped(display, findViewers(display, display.defaultRootWindow())[0])
  echo "GUI lifecycle checks passed."

when isMainModule:
  main()

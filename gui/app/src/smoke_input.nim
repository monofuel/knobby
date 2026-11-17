import
  std/[dynlib, os]

type
  Motion = proc (display: pointer, screen, x, y: cint, delay: culong): cint {.cdecl.}
  Button = proc (display: pointer, button: cuint, down: cint, delay: culong): cint {.cdecl.}

proc openDisplay(name: cstring): pointer {.cdecl, importc: "XOpenDisplay", dynlib: "libX11.so.6".}
  ## Open the isolated smoke display's input connection.
proc closeDisplay(display: pointer): cint {.cdecl, importc: "XCloseDisplay", dynlib: "libX11.so.6".}
  ## Close the smoke display's input connection.
proc flush(display: pointer): cint {.cdecl, importc: "XFlush", dynlib: "libX11.so.6".}
  ## Flush queued test input to the isolated X server.

proc pointerEvent*(x, y: int, action: int) =
  ## Inject motion, press, or release only into an explicitly enabled smoke display.
  doAssert getEnv("KNOBBY_GUI_SMOKE") == "1"
  let
    library = loadLib("libXtst.so.6")
    display = openDisplay(nil)
  if library.isNil or display.isNil:
    raise newException(OSError, "Smoke input requires XTest and an isolated display.")
  defer:
    discard closeDisplay(display)
    unloadLib(library)
  let
    motion = cast[Motion](library.symAddr("XTestFakeMotionEvent"))
    button = cast[Button](library.symAddr("XTestFakeButtonEvent"))
  doAssert not motion.isNil and not button.isNil
  if action == 0:
    doAssert motion(display, -1, x.cint, y.cint, 0) != 0
  else:
    doAssert button(display, 1, cint(action == 1), 0) != 0
  discard flush(display)

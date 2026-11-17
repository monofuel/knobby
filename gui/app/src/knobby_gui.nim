import
  std/[atomics, json, math, os, strutils, tables],
  chroma, jsony, opengl, pixie, silky, vmath, windy,
  silky/[atlas, widgets],
  knobby/[audio_status, bindings, gui_activation, ipc, status],
  ./[observers, smoke_input]

type
  DevicePage = enum
    MixerPage, DeckPage, MousepadPage
  Viewer = ref object
    page: DevicePage
    selected: int
    scroll, contentHeight: float32
    state: ViewerState

const
  Assets = currentSourcePath().parentDir().parentDir() / "assets"
  AtlasBytes = staticRead(Assets / "atlas.png")
  WindowWidth = 1280
  WindowHeight = 820
  SidebarWidth = 190'f32
  DetailWidth = 300'f32
  Margin = 24'f32
  Background = rgbx(19, 22, 28, 255)
  Panel = rgbx(28, 32, 40, 255)
  Tile = rgbx(39, 44, 54, 255)
  Foreground = rgbx(234, 237, 242, 255)
  Muted = rgbx(153, 163, 179, 255)
  Accent = rgbx(107, 187, 176, 255)
  Active = rgbx(182, 225, 211, 255)
  Names = ["Arduino mixer", "Stream Deck", "Mousepad"]
  DarkValue = parseInt(DarkGrey).uint8
  LightValue = parseInt(LightGrey).uint8
  DarkHex = "#" & repeat(toHex(DarkValue, 2), 3)
  LightHex = "#" & repeat(toHex(LightValue, 2), 3)

var interrupted: Atomic[bool]

proc requestStop() {.noconv.} =
  ## Ask the event loop to exit without doing GUI work in a signal handler.
  interrupted.store(true)

proc label(sk: Silky, value: string, x, y: float32, width: float32,
    font = "Body", color = Foreground): float32 =
  ## Draw native-size text on pixel-aligned rows, including the last line's descent.
  let
    metrics = sk.atlas.fonts[font]
    extent = sk.drawText(font, value, vec2(round(x), round(y)), color,
      maxWidth = floor(width), wordWrap = true)
  ceil(extent.y - metrics.ascent + metrics.lineHeight)

proc tile(sk: Silky, bounds: Rect, selected, lit: bool): bool =
  ## Draw an inspection target; selecting it never dispatches a device action.
  sk.drawRect(bounds.xy, bounds.wh, if selected: Accent else: Panel)
  sk.drawRect(bounds.xy + vec2(2, 2), bounds.wh - vec2(4, 4), if lit: Active else: Tile)
  result = sk.interact(bounds, true) == Released

proc deviceStatus(viewer: Viewer): string =
  ## Describe only connection state the corresponding observer can establish.
  case viewer.page
  of MixerPage:
    if viewer.state.mixerError.len > 0: viewer.state.mixerError
    elif viewer.state.snapshot.mixer.port.len == 0: "Controller disconnected"
    else: "Connected / " & viewer.state.snapshot.mixer.port
  of DeckPage:
    if viewer.state.deckConnected: "Connected / listening to key presses"
    else: viewer.state.deckError
  of MousepadPage:
    if viewer.state.mousepadPresent: "Connected / Razer Goliathus Chroma"
    else: "Mousepad disconnected"

proc catalog(viewer: Viewer): JsonNode =
  ## Prefer the running daemon's binding descriptions over offline defaults.
  if viewer.state.mixerError.len == 0: viewer.state.snapshot.catalog
  else: bindingCatalog()

proc drawMixer(sk: Silky, viewer: Viewer, x, width: float32) =
  ## Draw faders and buttons in their documented physical order.
  let
    column = floor((width - 30) / 4)
    state = viewer.state.snapshot.mixer
    connected = viewer.state.mixerError.len == 0 and state.port.len > 0
    definitions = viewer.catalog()
  for index in 0..3:
    let
      left = x + index.float32 * (column + 10)
      bounds = rect(left, 160, column, 175)
      value = viewer.state.faderPosition(index)
    if sk.tile(bounds, viewer.selected == index + 16, false):
      viewer.selected = index + 16
      viewer.scroll = 0
    discard sk.label(definitions["faders"][index]["label"].getStr(), left + 10, 170, column - 20)
    sk.drawRect(vec2(left + floor(column / 2) - 3, 207), vec2(6, 81), Background)
    if value >= 0:
      sk.drawRect(vec2(left + floor(column / 2) - 21,
        round(279 - value.float32 / 127 * 72)), vec2(42, 9), Accent)
    let caption = viewer.state.faderCaption(index)
    discard sk.label(caption, left + 10, 303, column - 20, "Small", Muted)
  for row in 0..2:
    for col in 0..3:
      let
        note = ButtonGrid[row][col]
        left = x + col.float32 * (column + 10)
        top = 365'f32 + row.float32 * 91
        lit = connected and buttonLit(state.held[note - 1], state.lastPressMs[note - 1], nowMs())
      if sk.tile(rect(left, top, column, 80), viewer.selected == note, lit):
        viewer.selected = note
        viewer.scroll = 0
      let color = if lit: Background else: Foreground
      discard sk.label("NOTE " & $note, left + 10, top + 10, column - 20, "Small", if lit: Background else: Muted)
      discard sk.label(definitions["buttons"][note - 1]["label"].getStr(), left + 10, top + 34, column - 20, color = color)

proc drawDeck(sk: Silky, viewer: Viewer, x, width: float32) =
  ## Preview the known numbered demo while independently highlighting input.
  let size = floor(min((width - 40) / 5, 104'f32))
  for index in 0..14:
    let
      left = x + (index mod 5).float32 * (size + 10)
      top = 185'f32 + (index div 5).float32 * (size + 10)
      lit = viewer.state.deckConnected and buttonLit(viewer.state.deckHeld[index],
        viewer.state.deckPressedMs[index], nowMs())
    if sk.tile(rect(left, top, size, size), viewer.selected == index, lit):
      viewer.selected = index
      viewer.scroll = 0
    discard sk.drawText("Key", $(index + 1), vec2(left, top),
      if lit: Background else: Foreground, maxWidth = size, maxHeight = size,
      hAlign = CenterAlign, vAlign = MiddleAlign)

proc drawMousepad(sk: Silky, x, width: float32) =
  ## Represent the intended breathing palette without claiming a live RGB readout.
  sk.drawRect(vec2(x + 25, 205), vec2(width - 50, 260), rgbx(LightValue, LightValue, LightValue, 255))
  sk.drawRect(vec2(x + 30, 210), vec2(width - 60, 250), Background)
  discard sk.label("GOLIATHUS CHROMA", x + 55, 315, width - 110, "Title", Muted)
  for index, color in [rgbx(DarkValue, DarkValue, DarkValue, 255), rgbx(LightValue, LightValue, LightValue, 255)]:
    sk.drawRect(vec2(x + 25 + index.float32 * 145, 500), vec2(120, 50), color)
  discard sk.label(DarkHex, x + 25, 560, 120, "Small", Muted)
  discard sk.label(LightHex, x + 170, 560, 120, "Small", Muted)

proc drawDetails(sk: Silky, viewer: Viewer, x, height: float32) =
  ## Explain the selected mapping and show independently observed audio state.
  let
    width = DetailWidth - 36
    top = 159'f32
  var y = top - round(viewer.scroll)
  sk.pushClipRect(rect(x, top, width, height - top - 35))
  defer: sk.popClipRect()
  template text(value: string, font = "Body", color = Foreground) =
    y += sk.label(value, x, y, width, font, color) + 12
  template audioLevel(level: AudioLevel) =
    text(level.name, "Small", Muted)
    text(level.levelText(), "Small")
  case viewer.page
  of MixerPage:
    let definitions = viewer.catalog()
    if viewer.selected >= 16:
      let index = viewer.selected - 16
      text(definitions["faders"][index]["label"].getStr(), "Title")
      text("Control change " & $viewer.selected, "Small", Accent)
      text(definitions["faders"][index]["description"].getStr())
      text("Actual audio", "Body", Accent)
      if viewer.state.audioError.len > 0:
        text("Audio unavailable", "Body", Muted)
        text(viewer.state.audioError, "Small", Muted)
      elif nowMs() - viewer.state.audioUpdatedMs > 4000:
        text("Audio observation is stale", "Small", Muted)
      elif index == 0:
        audioLevel(viewer.state.audio.master)
      elif viewer.state.faderStreams[index - 1].len == 0:
        text("No active matching streams", "Body", Muted)
      else:
        for stream in viewer.state.faderStreams[index - 1]:
          text(stream.appName)
          text(stream.levelText(), "Small", Muted)
    else:
      let binding = definitions["buttons"][viewer.selected - 1]
      text(binding["label"].getStr(), "Title")
      text("Note " & $viewer.selected, "Small", Accent)
      text(binding["description"].getStr())
      if viewer.selected == 11:
        text("Microphone inputs", "Body", Accent)
        if viewer.state.audioError.len > 0:
          text("Audio unavailable", "Body", Muted)
        elif nowMs() - viewer.state.audioUpdatedMs > 4000:
          text("Audio observation is stale", "Body", Muted)
        elif viewer.state.audio.microphones.len == 0:
          text("No microphone inputs", "Body", Muted)
        else:
          for microphone in viewer.state.audio.microphones:
            text(microphone.name, "Small", Muted)
            text(if microphone.muted: "Muted" else: "Unmuted")
  of DeckPage:
    text("Key " & $(viewer.selected + 1), "Title")
    text("Stream Deck MK.2", "Small", Accent)
    text("No desktop action assigned.")
    text("Numbered demo preview", "Body", Accent)
    text("White number on black. Holding a key shows black text on light grey.")
    text("Demo brightness: " & $StreamDeckDemoBrightness & "%", "Small", Muted)
  of MousepadPage:
    text("Grey breathing", "Title")
    text("Intended preset", "Small", Accent)
    text("Dark grey " & DarkHex & " to light grey " & LightHex & ".")
    text("Brightness: " & GreyBrightness & "%")
    text("The hardware breathing cycle fades through black.", "Small", Muted)
    text("OpenRazer lighting preset", "Small", Muted)
  viewer.contentHeight = max(0'f32, y + viewer.scroll - top - (height - top - 35))

proc render(sk: Silky, window: Window, viewer: Viewer) =
  ## Reflow the browser in framebuffer pixels without resampling its font atlas.
  sk.uiScale = 1
  sk.beginUi(window, window.size)
  sk.clearScreen(Background)
  let
    width = sk.size.x
    height = sk.size.y
    left = SidebarWidth + Margin
    boardWidth = width - SidebarWidth - DetailWidth - Margin * 3
    detailsX = width - DetailWidth + 18
  sk.drawRect(vec2(0, 0), vec2(SidebarWidth, height), Panel)
  discard sk.label("KNOBBY", 22, 30, 160, "Title")
  discard sk.label("Devices", 22, 96, 150, "Small", Muted)
  for page in DevicePage:
    let top = 127'f32 + page.ord.float32 * 68
    if sk.tile(rect(12, top, SidebarWidth - 24, 54), viewer.page == page, false):
      viewer.page = page
      viewer.selected = if page == MixerPage: 16 else: 0
      viewer.scroll = 0
    discard sk.label(Names[page.ord], 25, top + 16, SidebarWidth - 45)
  discard sk.label("Read-only", 22, height - 42, 150, "Small", Muted)
  discard sk.label(Names[viewer.page.ord], left, 30, boardWidth, "Title")
  discard sk.label(viewer.deviceStatus(), left, 77, boardWidth, "Small", Muted)
  discard sk.label("CONTROL DETAILS", detailsX, 114, DetailWidth - 36, "Small", Muted)
  sk.drawRect(vec2(width - DetailWidth, 114), vec2(1, height - 138), Tile)
  case viewer.page
  of MixerPage: sk.drawMixer(viewer, left, boardWidth)
  of DeckPage: sk.drawDeck(viewer, left, boardWidth)
  of MousepadPage: sk.drawMousepad(left, boardWidth)
  if sk.mousePos.x >= width - DetailWidth:
    viewer.scroll = clamp(viewer.scroll - window.scrollDelta.y * 30, 0'f32, viewer.contentHeight)
  sk.drawDetails(viewer, detailsX, height)
  sk.endUi()

proc trayImage(): Image =
  ## Draw a compact fader symbol that also serves as the application icon.
  result = newImage(32, 32)
  let ctx = result.newContext()
  ctx.fillStyle = "#6BBBB0"
  for (x, y) in [(8, 8), (16, 20), (24, 13)]:
    ctx.fillRect(rect((x - 1).float32, 4, 2, 24))
    ctx.fillRect(rect((x - 4).float32, y.float32, 8, 5))

proc capture(window: Window, filename: string) =
  ## Save the actual OpenGL frame for isolated rendering verification.
  let size = window.size
  var image = newImage(size.x, size.y)
  glReadPixels(0, 0, size.x, size.y, GL_RGBA, GL_UNSIGNED_BYTE, addr image.data[0])
  image.flipVertical()
  image.writeFile(filename)

proc main() =
  ## Open the viewer; smoke mode renders fixtures on an explicitly isolated display.
  var smokeDirectory = ""
  if paramCount() == 1 and paramStr(1) == "--help":
    echo "Usage: knobby-gui [--background | --smoke OUTPUT_DIRECTORY]"
    return
  if paramCount() == 0:
    activateViewer()
    return
  if paramCount() > 0:
    if paramCount() == 1 and paramStr(1) == "--background":
      discard
    elif paramCount() != 2 or paramStr(1) != "--smoke" or getEnv("KNOBBY_GUI_SMOKE") != "1":
      raise newException(ValueError, "Smoke mode requires KNOBBY_GUI_SMOKE=1 on an isolated X display.")
    else:
      smokeDirectory = paramStr(2)
      createDir(smokeDirectory)
  let activationServer = newLocalServer(runtimePath("knobby-gui", "activate.sock"))
  defer: activationServer.close()
  let
    window = newWindow("Knobby", ivec2(WindowWidth, WindowHeight), visible = smokeDirectory.len > 0, vsync = true)
    viewer = Viewer(selected: 16)
  defer: window.close()
  window.makeContextCurrent()
  loadExtensions()
  let
    metadata = extractAtlasJsonFromPng(AtlasBytes).fromJson(SilkyAtlas)
    image = decodeImage(AtlasBytes)
  metadata.rebuildGlyphLookups()
  let sk = newSilky(window, image, metadata)
  var
    quitting = false
    frame = 0
  proc openViewer() =
    ## Restore and focus the existing window without starting another viewer.
    window.visible = true
    window.minimized = false
    window.focus()
  proc quitViewer() =
    ## Exit only this viewer and its input observers.
    quitting = true
  if smokeDirectory.len == 0:
    startObservers()
  defer:
    if smokeDirectory.len == 0:
      stopObservers()
    hideTrayIcon()
  try:
    showTrayIcon(trayImage(), "Knobby", openViewer, @[
      TrayMenuEntry(kind: TrayMenuOption, text: "Open Knobby", onClick: openViewer),
      TrayMenuEntry(kind: TrayMenuOption, text: "Quit viewer", onClick: quitViewer)])
  except WindyError as error:
    stderr.writeLine("Tray unavailable: " & error.msg)
  window.onCloseRequest = proc () =
    ## Hide without ending the service, including when a tray host is unavailable.
    window.closeRequested = false
    window.visible = false
  window.onFrame = proc () =
    ## Refresh from observer snapshots without blocking on hardware or subprocesses.
    viewer.state = if smokeDirectory.len > 0: previewState() else: readState()
    if not window.visible:
      return
    if smokeDirectory.len > 0 and frame == 40:
      window.size = ivec2(960, 640)
    if smokeDirectory.len > 0 and frame == 44:
      window.size = ivec2(1183, 761)
    if smokeDirectory.len > 0 and frame == 48:
      window.size = ivec2(1600, 1000)
    sk.render(window, viewer)
    if smokeDirectory.len > 0:
      if frame == 0:
        doAssert viewer.state.faderCaption(0) == "MIDI 100"
        doAssert viewer.state.faderCaption(1) == "Not observed"
        doAssert viewer.state.faderCaption(2) == "Last known 50"
      if frame < 40:
        let
          step = frame div 8
          points = [vec2(80, 222), vec2(380, 351), vec2(80, 290), vec2(80, 154), vec2(288, 496)]
          point = points[step] * sk.uiScale + window.pos.vec2
        if frame mod 8 in [0, 2, 4]:
          pointerEvent(point.x.int, point.y.int, (frame mod 8) div 2)
        if frame mod 8 == 7:
          case step
          of 0: doAssert viewer.page == DeckPage
          of 1: doAssert viewer.page == DeckPage and viewer.selected == 6
          of 2: doAssert viewer.page == MousepadPage
          of 3: doAssert viewer.page == MixerPage
          of 4: doAssert viewer.page == MixerPage and viewer.selected == 11
          else: discard
      if frame in [0, 15, 23, 39, 42, 46, 50]:
        window.capture(smokeDirectory / ($frame & ".png"))
    window.swapBuffers()
    inc frame
    if smokeDirectory.len > 0 and frame >= 53:
      quitting = true
  setControlCHook(requestStop)
  while not quitting and not interrupted.load():
    for request in activationServer.pollRequests():
      if request.message{"type"}.getStr() == "activate":
        openViewer()
        request.peer.queueMessage(%*{"version": ProtocolVersion, "type": "activated"})
      else: request.peer.close()
    pollEvents()
    sleep(if window.visible: 10 else: 100)

when isMainModule:
  main()

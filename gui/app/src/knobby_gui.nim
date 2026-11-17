import
  std/[atomics, json, math, os, strutils, tables, unicode],
  chroma, jsony, opengl, pixie, silky, vmath, windy,
  silky/[atlas, widgets],
  knobby/[audio_status, bindings, button_config, gui_activation, ipc, status],
  ./[button_editor, button_editor_model, observers, smoke_input]

type
  DevicePage = enum
    MixerPage, DeckPage, MousepadPage, EditorPage
  Viewer = ref object
    page: DevicePage
    selected: int
    scroll, contentHeight: float32
    state: ViewerState
    editor: ButtonEditor
  SmokeStep = object
    name: string
    run: proc (frame: int): bool

const
  Assets = currentSourcePath().parentDir().parentDir() / "assets"
  AtlasBytes = staticRead(Assets / "atlas.png")
  WindowWidth = 1280
  WindowHeight = 820
  Names = ["Arduino mixer", "Stream Deck", "Mousepad", "Button editor"]
  SmokeStepFrames = 1500
  SubmittedTitle = "Submitted ✓"
  LateTitle = "Late ✓"
  LateCommand = "notify-send late"
  DarkValue = parseInt(DarkGrey).uint8
  LightValue = parseInt(LightGrey).uint8
  DarkHex = "#" & repeat(toHex(DarkValue, 2), 3)
  LightHex = "#" & repeat(toHex(LightValue, 2), 3)

var interrupted: Atomic[bool]

proc requestStop() {.noconv.} =
  ## Ask the event loop to exit without doing GUI work in a signal handler.
  interrupted.store(true)

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
  of EditorPage: ""

proc userLabel(sk: Silky, viewer: Viewer, value: string, x, y, width: float32,
    font = "Body", color = Foreground): float32 =
  ## Draw daemon- or user-provided text after requesting glyphs missing from the atlas.
  viewer.editor.requestGlyphs(sk, value)
  sk.label(value, x, y, width, font, color)

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
    discard sk.userLabel(viewer, definitions["faders"][index]["label"].getStr(), left + 10, 170, column - 20)
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
      discard sk.userLabel(viewer, definitions["buttons"][note - 1]["label"].getStr(), left + 10, top + 34, column - 20, color = color)

proc liveDeckMenu(viewer: Viewer): string =
  ## Return the daemon's active Deck menu once the applied configuration is loaded, else "".
  let
    model = viewer.editor.model
    menu = viewer.state.buttons{"deckMenu"}.getStr()
  if model.loaded and menu.len > 0 and not model.live.findMenu(menu).isNil: menu else: ""

proc drawDeck(sk: Silky, viewer: Viewer, x, width: float32) =
  ## Show the daemon's active Deck page with its prepared key images while highlighting input.
  let
    editor = viewer.editor
    size = floor(min((width - 40) / 5, 104'f32))
    model = editor.model
    menu = viewer.liveDeckMenu()
    artwork = editor.liveDeckReady() and size >= PreviewSize + 8
  for index in 0..14:
    let
      left = x + (index mod 5).float32 * (size + 10)
      top = 185'f32 + (index div 5).float32 * (size + 10)
      lit = viewer.state.deckConnected and buttonLit(viewer.state.deckHeld[index],
        viewer.state.deckPressedMs[index], nowMs())
      bounds = rect(left, top, size, size)
    editor.record("live:" & $(index + 1), bounds)
    if sk.tile(bounds, viewer.selected == index, lit):
      viewer.selected = index
      viewer.scroll = 0
    if artwork:
      let position = vec2(round(left + (size - PreviewSize) / 2), round(top + (size - PreviewSize) / 2))
      sk.drawPreview(editor, index, position)
      editor.record("liveArt:" & $(index + 1), rect(position, vec2(PreviewSize, PreviewSize)))
    elif menu.len > 0:
      let title = model.live.entryAt(menu, DeckDevice, index + 1){"title"}.getStr()
      editor.requestGlyphs(sk, title)
      discard sk.drawText("Small", title, vec2(left + 6, top), if lit: Background else: Foreground,
        maxWidth = size - 12, maxHeight = size, hAlign = CenterAlign, vAlign = MiddleAlign)
    else:
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
    y += sk.userLabel(viewer, value, x, y, width, font, color) + 12
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
    let
      editor = viewer.editor
      menu = viewer.liveDeckMenu()
    text("Key " & $(viewer.selected + 1), "Title")
    text("Stream Deck MK.2", "Small", Accent)
    if editor.liveDeckReady():
      for (slot, caption, offset) in [(viewer.selected, "Normal", 0'f32), (PressedSlot, "Pressed", 90'f32)]:
        let position = vec2(x + offset, y)
        sk.drawPreview(editor, slot, position)
        editor.record("liveDetail:" & caption, rect(position, vec2(PreviewSize, PreviewSize)))
        discard sk.label(caption, x + offset, y + PreviewSize + 4, 80, "Small", Muted)
      y += PreviewSize + 32
      let failure =
        if editor.liveArtError.len > 0: editor.liveArtError
        elif editor.previewCurrent(viewer.selected): slotDecodeError(viewer.selected)
        else: ""
      if failure.len > 0: text(failure, "Small", Danger)
    if menu.len > 0:
      let
        live = editor.model.live
        entry = live.entryAt(menu, DeckDevice, viewer.selected + 1)
        title = entry{"title"}.getStr()
      text(if title.len > 0: title else: "Untitled", "Body", if title.len > 0: Foreground else: Muted)
      text(live.describeAction(entry), "Small", Muted)
      text("Menu: " & live.menuTitle(menu), "Small", Muted)
    elif not viewer.state.buttons.isNil:
      if editor.model.error.len > 0: text(editor.model.error, "Small", Danger)
      else: text("Loading configuration...", "Small", Muted)
    text("Brightness: " & $StreamDeckDemoBrightness & "%", "Small", Muted)
  of MousepadPage:
    text("Grey breathing", "Title")
    text("Intended preset", "Small", Accent)
    text("Dark grey " & DarkHex & " to light grey " & LightHex & ".")
    text("Brightness: " & GreyBrightness & "%")
    text("The hardware breathing cycle fades through black.", "Small", Muted)
    text("OpenRazer lighting preset", "Small", Muted)
  of EditorPage: discard
  viewer.contentHeight = max(0'f32, y + viewer.scroll - top - (height - top - 35))

proc previewView(viewer: Viewer, window: Window): PreviewView =
  ## Choose the preview source: the active Deck page in the viewer, the draft in the editor.
  if not window.visible: NoPreview
  else:
    case viewer.page
    of DeckPage: LivePreview
    of EditorPage: DraftPreview
    else: NoPreview

proc render(sk: Silky, window: Window, viewer: Viewer) =
  ## Reflow the browser in framebuffer pixels without resampling its font atlas.
  sk.uiScale = 1
  if viewer.editor.recordRects: viewer.editor.rects.clear()
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
    let
      top = 127'f32 + page.ord.float32 * 68
      bounds = rect(12, top, SidebarWidth - 24, 54)
    if viewer.editor.recordRects: viewer.editor.rects["page:" & $page] = bounds
    if sk.tile(bounds, viewer.page == page, false):
      viewer.page = page
      viewer.selected = if page == MixerPage: 16 else: 0
      viewer.scroll = 0
    discard sk.label(Names[page.ord], 25, top + 16, SidebarWidth - 45)
  sk.drawRect(vec2(width - DetailWidth, 114), vec2(1, height - 138), Tile)
  if viewer.page == EditorPage:
    sk.drawMenus(window, viewer.editor, height)
    sk.drawEditor(window, viewer.editor, left, boardWidth, detailsX, height)
  else:
    discard sk.label("Read-only", 22, height - 42, 150, "Small", Muted)
    discard sk.label(Names[viewer.page.ord], left, 30, boardWidth, "Title")
    discard sk.label(viewer.deviceStatus(), left, 77, boardWidth, "Small", Muted)
    discard sk.label("CONTROL DETAILS", detailsX, 114, DetailWidth - 36, "Small", Muted)
    case viewer.page
    of MixerPage: sk.drawMixer(viewer, left, boardWidth)
    of DeckPage: sk.drawDeck(viewer, left, boardWidth)
    of MousepadPage: sk.drawMousepad(left, boardWidth)
    of EditorPage: discard
    if sk.mousePos.x >= width - DetailWidth:
      viewer.scroll = clamp(viewer.scroll - window.scrollDelta.y * 30, 0'f32, viewer.contentHeight)
    sk.drawDetails(viewer, detailsX, height)
  viewer.editor.releaseUndrawnFields()
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

proc writeRects(editor: ButtonEditor, filename: string) =
  ## Save control bounds next to a fixture capture for pixel checks.
  var rects = newJObject()
  for name, bounds in editor.rects:
    rects[name] = %*[bounds.x, bounds.y, bounds.w, bounds.h]
  writeFile(filename, $rects)

proc editorScript(phase, directory, fixtureImage: string, window: Window, sk: Silky,
    viewer: Viewer): seq[SmokeStep] =
  ## Drive the editor through isolated fixture interactions; nothing here touches devices.
  let editor = viewer.editor
  proc model(): EditorModel = editor.model
  proc click(name: string): SmokeStep =
    ## Move, press, and release the pointer at a recorded control's center.
    var
      phase = 0
      point: Vec2
    SmokeStep(name: "click " & name, run: proc (frame: int): bool =
      if phase == 0:
        if name notin editor.rects: return false
        let bounds = editor.rects[name]
        point = bounds.xy + vec2(floor(bounds.w / 2), floor(bounds.h / 2)) + window.pos.vec2
      if phase mod 2 == 0: pointerEvent(point.x.int, point.y.int, phase div 2)
      inc phase
      phase >= 7)
  proc typeText(value: string): SmokeStep =
    ## Commit Unicode text through the same rune callback Windy uses for keyboard and IME input.
    SmokeStep(name: "type " & value, run: proc (frame: int): bool =
      if frame == 0:
        for rune in value.runes: window.onRune(rune)
      frame >= 2)
  proc key(button: Button, count = 1): SmokeStep =
    ## Press and release a key through the window's input callbacks.
    SmokeStep(name: "key " & $button, run: proc (frame: int): bool =
      if frame mod 2 == 0 and frame div 2 < count: window.onButtonPress(button)
      elif frame mod 2 == 1: window.onButtonRelease(button)
      frame >= count * 2 + 1)
  proc waitFor(name: string, condition: proc (): bool): SmokeStep =
    ## Wait for an asynchronous editor outcome.
    SmokeStep(name: name, run: proc (frame: int): bool = condition())
  proc settle(frames: int): SmokeStep =
    ## Allow animation, decoding, and layout to reach a stable frame.
    SmokeStep(name: "settle", run: proc (frame: int): bool = frame >= frames)
  proc capture(name: string): SmokeStep =
    ## Save the current frame and its control bounds.
    SmokeStep(name: "capture " & name, run: proc (frame: int): bool =
      window.capture(directory / (name & ".png"))
      editor.writeRects(directory / (name & ".json"))
      true)
  proc resize(width, height: int): SmokeStep =
    ## Resize the isolated window and let the layout reflow.
    SmokeStep(name: "resize", run: proc (frame: int): bool =
      if frame == 0: window.size = ivec2(width.int32, height.int32)
      frame >= 4)
  proc replaceField(name, value: string): seq[SmokeStep] =
    ## Focus a field, clear it, and type replacement text.
    @[click(name), key(KeyEnd), key(KeyBackspace, 24), typeText(value)]
  proc selectedTitle(): string = model().selected(){"title"}.getStr()
  proc createFile(path: string): SmokeStep =
    ## Create a fixture control file.
    SmokeStep(name: "create " & path.extractFilename(), run: proc (frame: int): bool =
      writeFile(path, "")
      true)
  proc deleteFile(path: string): SmokeStep =
    ## Remove a fixture control file.
    SmokeStep(name: "remove " & path.extractFilename(), run: proc (frame: int): bool =
      removeFile(path)
      true)
  proc mixerSlot(config: JsonNode, key: int): JsonNode =
    ## Read one root-menu mixer slot.
    config.entryAt(config.rootMenu(), MixerDevice, key)
  proc applying(): bool = editor.busy and editor.busyKind == ApplyJob
  let openEditor = @[click("page:EditorPage"),
    waitFor("configuration loaded", proc (): bool = model().loaded and not editor.busy)]
  case phase
  of "edit":
    result = openEditor & @[
      click("device:deck"),
      waitFor("deck preview", proc (): bool = not editor.manifest.isNil),
      settle(20),
      capture("deck"),
      click("key:7"),
      waitFor("key selected", proc (): bool = model().key == 7)] &
      replaceField("title", "Música 日本 ✓ 🎵") & @[
      waitFor("unicode title", proc (): bool = selectedTitle() == "Música 日本 ✓ 🎵"),
      waitFor("dynamic glyphs", proc (): bool =
        proc replaced(font, glyph: string): bool =
          ## Report whether a glyph renders as the visible replacement character.
          let entries = sk.atlas.fonts[font].entries
          glyph in entries and "\uFFFD" in entries and entries[glyph][0].x == entries["\uFFFD"][0].x
        result = true
        for font in ["Small", "Body", "Title"]:
          for glyph in ["ú", "✓"]:
            result = result and sk.hasGlyph(font, glyph.runeAt(0)) and not replaced(font, glyph)
          for glyph in ["日", "本", "🎵"]:
            result = result and replaced(font, glyph)),
      click("action:command")] &
      replaceField("command", "true") & @[
      waitFor("command edited", proc (): bool =
        model().selected()["action"]{"command"}.getStr() == "true" and model().dirty),
      waitFor("draft autosaved", proc (): bool =
        fileExists(draftPath()) and "Música" in readFile(draftPath())),
      settle(10),
      capture("edited"),
      click("device:mixer"),
      click("key:12"),
      waitFor("mixer key", proc (): bool = model().device == MixerDevice and model().key == 12),
      capture("mixer")]
  of "recover":
    result = openEditor & @[
      waitFor("draft recovered as stale", proc (): bool =
        model().notice.startsWith("Recovered") and model().conflict == StaleRevision),
      settle(4),
      capture("conflict"),
      click("keepDraft"),
      waitFor("draft rebased", proc (): bool = model().conflict == NoConflict and model().canApply()),
      click("newMenu"),
      typeText("Spiele 🎮"),
      key(KeyEnter),
      waitFor("menu created", proc (): bool = model().menu == "spiele"),
      click("device:deck"),
      click("key:1"),
      waitFor("locked back", proc (): bool = model().selectedLocked() and "title" notin editor.rects),
      settle(4),
      capture("locked"),
      click("key:2"),
      waitFor("key 2", proc (): bool = model().key == 2),
      waitFor("key 2 editable", proc (): bool = "importPath" in editor.rects)] &
      replaceField("importPath", fixtureImage) & @[
      click("import"),
      waitFor("image imported", proc (): bool = model().selected().hasImage()),
      waitFor("image preview", proc (): bool =
        editor.previewEdits == model().edits and not editor.busy and
          not editor.manifest{"menus"}{"spiele"}{"2"}.isNil),
      settle(20),
      capture("image"),
      click("menu:root"),
      waitFor("root", proc (): bool = model().menu == RootMenuId),
      click("key:5"),
      click("action:menu"),
      waitFor("menu action", proc (): bool =
        model().selected()["action"]{"menu"}.getStr() == "spiele"),
      click("on:deck"),
      waitFor("deck target", proc (): bool = model().selected().menuTarget() == TargetDeck),
      click("key:3")] &
      replaceField("title", "FAIL") & @[
      waitFor("failing title", proc (): bool = selectedTitle() == "FAIL"),
      click("save"),
      waitFor("apply failed", proc (): bool =
        not editor.busy and model().error.len > 0 and model().dirty),
      settle(4),
      capture("failed")] &
      replaceField("title", "OK ✓") & @[
      waitFor("fixed title", proc (): bool = selectedTitle() == "OK ✓"),
      click("save"),
      waitFor("applied", proc (): bool =
        editor.applied == 1 and not editor.busy and not model().dirty and
          not fileExists(draftPath())),
      settle(20),
      capture("applied"),
      resize(960, 640),
      capture("applied-small"),
      resize(1183, 761),
      capture("applied-odd"),
      resize(1600, 1000),
      capture("applied-large")]
  of "live":
    proc dynamicGlyphs(glyphs: varargs[string]): bool =
      ## Report whether every font renders the glyphs natively, none of which the base atlas has.
      result = true
      for font in ["Small", "Body", "Title"]:
        for glyph in glyphs:
          result = result and sk.hasGlyph(font, glyph.runeAt(0))
    proc liveArt(): bool =
      ## Report whether the live grid and selected key show frames of the published active page.
      editor.liveDeckReady() and editor.previewCurrent(viewer.selected) and
        editor.previewCurrent(PressedSlot)
    result = @[
      waitFor("readonly mixer glyphs", proc (): bool =
        not editor.opened and dynamicGlyphs("ú", "É")),
      settle(4),
      capture("live-mixer"),
      click("page:DeckPage"),
      waitFor("live configuration", proc (): bool = model().loaded and not editor.opened),
      click("live:3"),
      waitFor("live unicode title", proc (): bool = viewer.selected == 2 and dynamicGlyphs("ß")),
      click("live:2"),
      waitFor("live artwork", proc (): bool = viewer.selected == 1 and liveArt()),
      settle(20),
      capture("live-deck")] &
      openEditor & @[
      click("menu:spiele"),
      waitFor("spiele", proc (): bool = model().menu == "spiele"),
      click("device:deck"),
      click("key:2"),
      waitFor("draft key", proc (): bool = model().device == DeckDevice and model().key == 2),
      click("clearImage"),
      waitFor("draft without image", proc (): bool =
        not model().selected().hasImage() and model().dirty),
      waitFor("draft preview", proc (): bool =
        editor.previewEdits == model().edits and not editor.busy and
          editor.manifest{"menus"}{"spiele"}{"2"}.isNil and editor.previewCurrent(1)),
      waitFor("draft autosaved", proc (): bool = fileExists(draftPath())),
      settle(4),
      capture("live-draft"),
      click("page:DeckPage"),
      waitFor("live artwork again", proc (): bool = viewer.selected == 0 and liveArt()),
      click("live:2"),
      waitFor("live key 2 again", proc (): bool = viewer.selected == 1 and liveArt()),
      settle(20),
      capture("live-after-draft")]
  of "pending":
    result = openEditor & @[
      waitFor("clean root mixer", proc (): bool =
        not model().dirty and model().device == MixerDevice and model().menu == model().draft.rootMenu()),
      click("key:2"),
      waitFor("key 2", proc (): bool = model().key == 2)] &
      replaceField("title", SubmittedTitle) & @[
      waitFor("submitted title", proc (): bool = selectedTitle() == SubmittedTitle and not editor.busy),
      createFile(smokeControlPath(ApplyGateName)),
      click("save"),
      waitFor("apply held by the daemon", proc (): bool =
        applying() and fileExists(smokeControlPath(ApplyBlockedName)))] &
      replaceField("title", LateTitle) & @[
      waitFor("late title", proc (): bool = selectedTitle() == LateTitle),
      click("key:3"),
      waitFor("key 3", proc (): bool = model().key == 3),
      click("action:command")] &
      replaceField("command", LateCommand) & @[
      waitFor("late edits autosaved while applying", proc (): bool =
        applying() and fileExists(draftPath()) and LateCommand in readFile(draftPath()) and
          LateTitle in readFile(draftPath())),
      settle(4),
      capture("pending"),
      deleteFile(smokeControlPath(ApplyGateName)),
      waitFor("applied with late edits kept", proc (): bool =
        editor.applied == 1 and not editor.busy and model().dirty and
          model().conflict == NoConflict and model().error == "" and
          model().live.mixerSlot(2)["title"].getStr() == SubmittedTitle and
          model().draft.mixerSlot(2)["title"].getStr() == LateTitle and
          model().draft.mixerSlot(3)["action"]{"command"}.getStr() == LateCommand),
      waitFor("late draft autosaved against the applied revision", proc (): bool =
        let draft = readDraft(draftPath())
        not draft.isNil and draft["baseRevision"].getStr() == model().liveRevision and
          draft["config"] == model().draft),
      settle(10),
      capture("pending-applied")]
  of "reload":
    result = openEditor & @[
      waitFor("late draft recovered", proc (): bool =
        model().notice.startsWith("Recovered") and model().conflict == NoConflict and
          model().canApply() and model().draft.mixerSlot(2)["title"].getStr() == LateTitle),
      createFile(smokeControlPath(FailReloadName)),
      click("save"),
      waitFor("applied with a failed reload", proc (): bool =
        editor.applied == 1 and not editor.busy and not fileExists(smokeControlPath(FailReloadName))),
      settle(30),
      waitFor("reported as applied", proc (): bool =
        not model().dirty and model().conflict == NoConflict and model().error == "" and
          model().notice.startsWith("Applied revision") and
          model().liveRevision == editor.status{"revision"}.getStr() and
          model().live.mixerSlot(2)["title"].getStr() == LateTitle and not fileExists(draftPath())),
      capture("reload-failed")]
  else:
    raise newException(ValueError, "Unknown editor smoke phase: " & phase)

proc main() =
  ## Open the viewer; smoke modes render fixtures on an explicitly isolated display.
  var
    smokeDirectory = ""
    editorPhase = ""
    fixtureImage = ""
  if paramCount() == 1 and paramStr(1) == "--help":
    echo "Usage: knobby-gui [--background | --smoke OUTPUT_DIRECTORY]"
    return
  if paramCount() == 0:
    activateViewer()
    return
  if paramCount() > 0:
    if paramCount() == 1 and paramStr(1) == "--background":
      discard
    elif getEnv("KNOBBY_GUI_SMOKE") != "1":
      raise newException(ValueError, "Smoke mode requires KNOBBY_GUI_SMOKE=1 on an isolated X display.")
    elif paramCount() == 2 and paramStr(1) == "--smoke":
      smokeDirectory = paramStr(2)
    elif paramCount() == 4 and paramStr(1) == "--editor-smoke":
      editorPhase = paramStr(2)
      smokeDirectory = paramStr(3)
      fixtureImage = paramStr(4)
    else:
      raise newException(ValueError, "Unknown smoke arguments.")
    if smokeDirectory.len > 0: createDir(smokeDirectory)
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
  viewer.editor = newButtonEditor(sk)
  viewer.editor.recordRects = editorPhase.len > 0
  startEditorWorkers()
  var
    quitting = false
    frame = 0
    steps: seq[SmokeStep]
    stepIndex, stepFrame = 0
  if editorPhase.len > 0:
    steps = editorScript(editorPhase, smokeDirectory, fixtureImage, window, sk, viewer)
  proc openViewer() =
    ## Restore and focus the existing window without starting another viewer.
    window.visible = true
    window.minimized = false
    window.focus()
  proc quitViewer() =
    ## Exit only this viewer and its input observers.
    quitting = true
  let fixtureStatus = smokeDirectory.len > 0 and editorPhase.len == 0
  if not fixtureStatus:
    startObservers()
  defer:
    viewer.editor.flushDraft()
    if not fixtureStatus:
      stopObservers()
    stopEditorWorkers()
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
    viewer.state = if fixtureStatus: previewState() else: readState()
    viewer.editor.liveKey = viewer.selected + 1
    sk.updateEditor(viewer.editor, viewer.state.buttons, viewer.previewView(window))
    if not window.visible:
      return
    if fixtureStatus and frame == 40:
      window.size = ivec2(960, 640)
    if fixtureStatus and frame == 44:
      window.size = ivec2(1183, 761)
    if fixtureStatus and frame == 48:
      window.size = ivec2(1600, 1000)
    sk.render(window, viewer)
    if editorPhase.len > 0:
      if stepIndex >= steps.len:
        quitting = true
      elif steps[stepIndex].run(stepFrame):
        inc stepIndex
        stepFrame = 0
      else:
        inc stepFrame
        if stepFrame > SmokeStepFrames:
          raise newException(AssertionDefect, "Editor smoke step timed out: " &
            steps[stepIndex].name & " / " & viewer.editor.model.problem())
    elif fixtureStatus:
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
    if fixtureStatus and frame >= 53:
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

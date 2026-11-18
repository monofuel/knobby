import
  std/[atomics, importutils, json, math, os, posix],
  chroma, jsony, opengl, pixie, silky, vmath, windy,
  silky/atlas,
  knobby/[bindings, ipc],
  ./[observers, overlay_layout, overlay_x11]

type
  Overlay = ref object
    window: Window
    sk: Silky
    x11: OverlayX11
    id: XId
    argb, translucent, shown, frameReady: bool
    placed: tuple[x, y: int]
    nextPlacementMs, nextStackingMs, nextCompositorMs: int64

const
  Assets = currentSourcePath().parentDir().parentDir() / "assets"
  AtlasBytes = staticRead(Assets / "atlas.png")
  WindowTitle = "Knobby overlay"
  VisiblePollMs = 20
  HiddenPollMs = 100
  PlacementIntervalMs = 500
  StackingIntervalMs = 250
  CompositorIntervalMs = 1000
  BorderWidth = 2
  TranslucentAlpha = 0.86'f32
  CardFill = rgbx(19, 22, 28, 255)
  CardBorder = rgbx(107, 187, 176, 255)
  UnassignedBorder = rgbx(62, 70, 84, 255)
  LabelColor = rgbx(234, 237, 242, 255)
  MutedColor = rgbx(153, 163, 179, 255)
  Transparent = rgbx(0, 0, 0, 0)
  BodyLines = 2
  SmallLines = 3
  SmokeFrames = 12
  SmokeLongLabel = "Spotify, Firefox and every game volume shortcut on this board"
  SmokeLongNote = 8

var interrupted: Atomic[bool]

proc requestStop() {.noconv.} =
  ## Ask the event loop to exit without doing GUI work in a signal handler.
  interrupted.store(true)

proc windowId(window: Window): XId =
  ## Read Windy's native X window id, which its pinned API keeps private.
  privateAccess(Window)
  XId(window.handle)

proc cardRects(): seq[PixelRect] =
  ## Return the card rectangles that form the visible and bounding region.
  for card in overlayCards(nil):
    result.add(card.bounds)

proc withAlpha(color: ColorRGBX, alpha: float32): ColorRGBX =
  ## Premultiply a color by an opacity, matching Silky's blend mode.
  rgbx(uint8(round(color.r.float32 * alpha)), uint8(round(color.g.float32 * alpha)),
    uint8(round(color.b.float32 * alpha)), uint8(round(color.a.float32 * alpha)))

proc measure(sk: Silky, font: string): Measure =
  ## Measure rendered text width in whole pixels for one atlas font.
  result = proc (text: string): int = ceil(sk.getTextSize(font, text).x).int

proc layoutLabel(sk: Silky, label: string): LabelLines =
  ## Fit a label in two Body lines, else three Small lines, at native glyph size.
  fitLabel(label, [LabelFont(name: "Body", maxLines: BodyLines, measure: sk.measure("Body")),
    LabelFont(name: "Small", maxLines: SmallLines, measure: sk.measure("Small"))])

proc lineStep(sk: Silky, font: string): int =
  ## Return a whole-pixel line spacing so every baseline stays on a pixel row.
  ceil(sk.atlas.fonts[font].lineHeight).int

proc labelTop(sk: Silky, card: OverlayCard, lines: LabelLines): int =
  ## Center the label block vertically in the card's label area.
  card.bounds.y + LabelTop + (LabelHeight - lines.lines.len * sk.lineStep(lines.font)) div 2

proc render(sk: Silky, window: Window, catalog: JsonNode, translucent: bool) =
  ## Draw the twelve cards on a transparent canvas at native pixel size.
  let alpha = if translucent: TranslucentAlpha else: 1'f32
  sk.uiScale = 1
  sk.beginUi(window, window.size)
  sk.clearScreen(Transparent)
  for card in overlayCards(catalog):
    let
      bounds = card.bounds
      position = vec2(bounds.x.float32, bounds.y.float32)
      size = vec2(bounds.width.float32, bounds.height.float32)
      border = if card.unassigned: UnassignedBorder else: CardBorder
      lines = sk.layoutLabel(card.label)
      top = sk.labelTop(card, lines)
      step = sk.lineStep(lines.font)
    sk.drawRect(position, size, border.withAlpha(alpha))
    sk.drawRect(position + vec2(BorderWidth, BorderWidth),
      size - vec2(2 * BorderWidth, 2 * BorderWidth), CardFill.withAlpha(alpha))
    discard sk.drawText("Small", $card.note,
      vec2(float32(bounds.x + CardPadding), float32(bounds.y + NoteTop)), MutedColor)
    for index, line in lines.lines:
      discard sk.drawText(lines.font, line,
        vec2(float32(bounds.x + CardPadding), float32(top + index * step)),
        if card.unassigned: MutedColor else: LabelColor)
  sk.endUi()

proc capture(window: Window, filename: string) =
  ## Save the renderer's own OpenGL frame for isolated verification.
  let size = window.size
  var image = newImage(size.x, size.y)
  glReadPixels(0, 0, size.x, size.y, GL_RGBA, GL_UNSIGNED_BYTE, addr image.data[0])
  image.flipVertical()
  image.writeFile(filename)

proc newOverlay(): Overlay =
  ## Create the hidden, unmanaged, click-through overlay window and its renderer.
  result = Overlay(x11: openOverlayX11())
  let size = ivec2(OverlayWidth, OverlayHeight)
  if result.x11.compositorPresent():
    try:
      result.window = newWindow(WindowTitle, size, style = WindowStyle.Transparent,
        visible = false, vsync = true)
      result.argb = true
    except WindyError as error:
      stderr.writeLine("Overlay translucency unavailable: " & error.msg)
  if result.window.isNil:
    result.window = newWindow(WindowTitle, size, style = Undecorated, visible = false, vsync = true)
  result.id = result.window.windowId()
  result.x11.setPassiveOverlay(result.id, cardRects())
  result.window.makeContextCurrent()
  loadExtensions()
  let metadata = extractAtlasJsonFromPng(AtlasBytes).fromJson(SilkyAtlas)
  metadata.rebuildGlyphLookups()
  result.sk = newSilky(result.window, decodeImage(AtlasBytes), metadata)

proc close(overlay: Overlay) =
  ## Destroy the window and the private X connection.
  overlay.window.close()
  overlay.x11.close()

proc place(overlay: Overlay) =
  ## Follow the current primary monitor and panel struts.
  let placement = overlay.x11.overlayPlacement()
  if not overlay.shown or (placement.x, placement.y) != overlay.placed:
    overlay.x11.move(overlay.id, placement.x, placement.y)
    overlay.placed = (placement.x, placement.y)

proc show(overlay: Overlay, nowMs: int64) =
  ## Map the overlay above other windows without focusing or activating it.
  overlay.place()
  overlay.translucent = overlay.argb and overlay.x11.compositorPresent()
  overlay.x11.clearFrameReady(overlay.id)
  overlay.frameReady = false
  overlay.window.visible = true
  overlay.shown = true
  overlay.x11.keepAbove(overlay.id)
  overlay.nextPlacementMs = nowMs + PlacementIntervalMs
  overlay.nextStackingMs = nowMs + StackingIntervalMs
  overlay.nextCompositorMs = nowMs + CompositorIntervalMs

proc hide(overlay: Overlay) =
  ## Unmap the overlay; the process stays running for the next request.
  overlay.window.visible = false
  overlay.shown = false

proc tick(overlay: Overlay, catalog: JsonNode, nowMs: int64) =
  ## Keep a shown overlay placed, stacked, and drawn for the current compositor state.
  if nowMs >= overlay.nextPlacementMs:
    overlay.place()
    overlay.nextPlacementMs = nowMs + PlacementIntervalMs
  if nowMs >= overlay.nextStackingMs:
    overlay.x11.keepAbove(overlay.id)
    overlay.nextStackingMs = nowMs + StackingIntervalMs
  if nowMs >= overlay.nextCompositorMs:
    overlay.translucent = overlay.argb and overlay.x11.compositorPresent()
    overlay.nextCompositorMs = nowMs + CompositorIntervalMs
  overlay.sk.render(overlay.window, catalog, overlay.translucent)
  overlay.window.swapBuffers()
  if not overlay.frameReady:
    overlay.x11.markFrameReady(overlay.id)
    overlay.frameReady = true

proc smokeCatalog(): JsonNode =
  ## Describe the compiled bindings plus a long label and an unassigned slot for isolated checks.
  result = bindingCatalog()
  result["buttons"][SmokeLongNote - 1]["label"] = %SmokeLongLabel
  result["buttons"][3]["label"] = %UnassignedLabel

proc runSmoke(directory: string) =
  ## Render the fixture overlay on an isolated display and save its frame.
  createDir(directory)
  let overlay = newOverlay()
  defer: overlay.close()
  overlay.show(monotonicMs())
  for frame in 0..<SmokeFrames:
    pollEvents()
    overlay.tick(smokeCatalog(), monotonicMs())
    if frame == SmokeFrames - 1:
      overlay.window.capture(directory / "overlay-frame.png")
  writeFile(directory / "overlay-frame.json", $(%*{"translucent": overlay.translucent,
    "argb": overlay.argb, "x": overlay.placed.x, "y": overlay.placed.y,
    "window": overlay.id.int}))

proc runRenderer() =
  ## Observe daemon status and show the overlay only while a fresh request is active.
  let ownership = acquireOwnership(runtimePath("knobby-overlay", "renderer.lock"))
  defer: discard posix.close(ownership)
  let overlay = newOverlay()
  defer: overlay.close()
  startObservers()
  defer: stopObservers()
  setControlCHook(requestStop)
  while not interrupted.load():
    pollEvents()
    let
      nowMs = monotonicMs()
      state = readState()
      wanted = overlayShowing(state.buttons, nowMs)
    if wanted and not overlay.shown:
      overlay.show(nowMs)
    elif not wanted and overlay.shown:
      overlay.hide()
    if overlay.shown:
      overlay.tick(state.snapshot.catalog, nowMs)
    sleep(if overlay.shown: VisiblePollMs else: HiddenPollMs)

proc main() =
  ## Run the overlay renderer, or an explicitly isolated smoke render.
  let args = commandLineParams()
  if args == @["--help"]:
    echo "Usage: knobby-overlay [--smoke OUTPUT_DIRECTORY]"
  elif args.len == 0:
    runRenderer()
  elif args.len == 2 and args[0] == "--smoke":
    if getEnv("KNOBBY_GUI_SMOKE") != "1":
      raise newException(ValueError, "Smoke mode requires KNOBBY_GUI_SMOKE=1 on an isolated X display.")
    runSmoke(args[1])
  else:
    raise newException(ValueError, "Usage: knobby-overlay [--smoke OUTPUT_DIRECTORY]")

when isMainModule:
  main()

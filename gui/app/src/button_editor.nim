import
  std/[atomics, json, locks, math, os, sets, strutils, tables, unicode],
  chroma, opengl, pixie, silky, vmath, windy,
  silky/[allocator, atlas, contexts, textboxes, widgets],
  silky/internal/inputs,
  silky/drawers/ogl,
  knobby/[bindings, button_client, button_config, controls_state, ipc, obs_state],
  ./button_editor_model

type
  JobKind* = enum
    LoadJob, ApplyJob, PreviewJob, ImportJob, BrowseJob
  PreviewView* = enum
    ## Which preview source the player shows: none, the daemon's active page, or the draft.
    NoPreview, LivePreview, DraftPreview
  ConfigJob = object
    kind: JobKind
    payload: string
  ConfigReply = object
    kind: JobKind
    ok: bool
    payload, error, code, field: string
  PreviewSource = object
    frames: seq[tuple[path: string, durationMs: int]]
  PreviewPage = object
    sources: array[16, PreviewSource]
    manifestPath, menu, drawer: string
    indicators: string
    pressedKey, menuKey: int
  SlotPixels = object
    generation, page: int
    pixels: seq[ColorRGBX]
    error: string
  EditorField = ref object
    state: TextBoxState
    binding, original: string
    focused, drawn: bool
  ImportTarget = object
    menu: string
    key: int
    state: string
  ButtonEditor* = ref object
    ## GUI state for the button editor; config I/O runs on a bounded background worker.
    model*: EditorModel
    fields: Table[string, EditorField]
    busy*: bool
    busyKind*: JobKind
    queued: set[JobKind]
    queuedImport: string
    importTarget: ImportTarget
    manifest*: JsonNode
    previewEdits*, previewRequestedEdits: int
    previewError*: string
    previewRetryMs: int64
    saver: DraftSaver
    status*: JsonNode
    obsStatus*: JsonNode
    controlStatus*: JsonNode
    statusRevision: string
    opened*, recovered: bool
    importPath, newMenuTitle: string
    scroll, contentHeight: float32
    slotUploaded, slotPage: array[16, int]
    pageKey: string
    publishedPage: int
    liveKey*: int
    liveArtError*: string
    glyphs: GlyphCache
    recordRects*: bool
    rects*: Table[string, Rect]
    replies*: seq[JobKind]
    applied*: int
  GlyphCache = object
    typeface: Typeface
    pending: seq[Rune]
    checked: HashSet[Rune]
    added: int

const
  Background* = rgbx(19, 22, 28, 255)
  Panel* = rgbx(28, 32, 40, 255)
  Tile* = rgbx(39, 44, 54, 255)
  TileHover = rgbx(50, 57, 69, 255)
  Foreground* = rgbx(234, 237, 242, 255)
  Muted* = rgbx(153, 163, 179, 255)
  Accent* = rgbx(107, 187, 176, 255)
  Active* = rgbx(182, 225, 211, 255)
  Danger* = rgbx(236, 118, 108, 255)
  Black = rgbx(0, 0, 0, 255)
  SidebarWidth* = 190'f32
  DetailWidth* = 300'f32
  Margin* = 24'f32
  EditorPageTop = 127'f32 + 3 * 68
  PreviewSize* = 72
  PreviewSlotCount = 16
  PressedSlot* = 15
  FieldHeight = 34'f32
  ChipHeight = 30'f32
  MenuRowHeight = 32'f32
  Gap = 8'f32
  PreviewDebounceMs = 600
  PreviewBusyRetryMs = 1000
  PlayerPollMs = 8
  PlayerIdleMs = 50
  MaxDynamicGlyphs = 512
  MaxAtlasSize = 4096
  PreviewCacheBytes = 48 * 1024 * 1024
  DynamicFonts = ["Small", "Body", "Title"]
  ReplacementRune = Rune(0xFFFD)
  ReplacementKey = "�"
  BuiltinPrefix = "builtin:"
  FontBytes = staticRead(currentSourcePath().parentDir().parentDir() / "assets" / "DejaVuSans.ttf")
  DeckAssetDirectory = currentSourcePath().parentDir().parentDir().parentDir().parentDir() /
    "assets" / "stream_deck"
  BuiltinNormal = static:
    var images: array[15, string]
    for index in 0..14:
      images[index] = staticRead(DeckAssetDirectory / ($(index + 1) & "-normal.jpg"))
    images
  BuiltinPressed = static:
    var images: array[15, string]
    for index in 0..14:
      images[index] = staticRead(DeckAssetDirectory / ($(index + 1) & "-pressed.jpg"))
    images
  ImageFilters = @[FileDialogFilter(name: "Images", extensions: "*.png;*.jpg;*.jpeg;*.gif")]
  ImageExtensions = [".png", ".jpg", ".jpeg", ".gif"]

var
  jobs: Channel[ConfigJob]
  replies: Channel[ConfigReply]
  workerThread: Thread[void]
  playerThread: Thread[void]
  playerLock: Lock
  playerPage: PreviewPage
  playerGeneration: int
  playerPageError: string
  playerSlots: array[PreviewSlotCount, SlotPixels]
  playerStopping: Atomic[bool]
  workerBusy: Atomic[bool]
  workersStarted: bool

initLock(playerLock)

proc nowMs(): int64 =
  ## Return a monotonic timestamp for debouncing and animation.
  monotonicMs()

proc label*(sk: Silky, value: string, x, y: float32, width: float32,
    font = "Body", color = Foreground): float32 =
  ## Draw native-size text on pixel-aligned rows, including the last line's descent.
  let
    metrics = sk.atlas.fonts[font]
    extent = sk.drawText(font, value, vec2(round(x), round(y)), color,
      maxWidth = floor(width), wordWrap = true)
  ceil(extent.y - metrics.ascent + metrics.lineHeight)

proc tile*(sk: Silky, bounds: Rect, selected, lit: bool): bool =
  ## Draw an inspection target; selecting it never dispatches a device action.
  sk.drawRect(bounds.xy, bounds.wh, if selected: Accent else: Panel)
  sk.drawRect(bounds.xy + vec2(2, 2), bounds.wh - vec2(4, 4), if lit: Active else: Tile)
  result = sk.interact(bounds, true) == Released

proc rotateUpright(image: Image) =
  ## Undo the 180-degree rotation prepared for the physically mounted Deck.
  image.flipHorizontal()
  image.flipVertical()

proc decodePreview(path: string): seq[ColorRGBX] =
  ## Decode one exact prepared or built-in JPEG into upright display pixels.
  let data =
    if path.startsWith(BuiltinPrefix):
      let parts = path[BuiltinPrefix.len..^1].split(':')
      let index = parseInt(parts[0]) - 1
      if parts[1] == "pressed": BuiltinPressed[index] else: BuiltinNormal[index]
    else:
      readPreparedFrame(path)
  let image = decodeImage(data)
  if image.width != PreviewSize or image.height != PreviewSize:
    raise newException(ValueError, "Prepared key image is " & $image.width & "x" &
      $image.height & ", expected " & $PreviewSize & "x" & $PreviewSize & ".")
  image.rotateUpright()
  image.data

proc blankPixels(): seq[ColorRGBX] =
  ## Return the black key face shown for absent slots.
  result = newSeq[ColorRGBX](PreviewSize * PreviewSize)
  for pixel in result.mitems: pixel = Black

proc draftVariant(entry: JsonNode, state: string): JsonNode =
  ## Return the prepared variant the editor's chosen state shows, or the base entry.
  result = entry
  if not entry.isNil and state in entry.manifestStates():
    let variant = entry{"states"}{state}
    if not variant.isNil and variant.kind == JObject: result = variant

proc menuPage(manifest: JsonNode, menu: string, selectedKey: int, state = NormalState,
    status: JsonNode = nil, drawer = "", menuKey = LegacyMenuKey): PreviewPage =
  ## Translate one manifest menu into player sources, choosing status variants by live indicators or draft state.
  ## An open drawer menu covers the same keys as on the physical Deck.
  let keys = manifest{"menus"}{menu}
  proc shown(entry: JsonNode): JsonNode =
    ## Resolve live keys exactly as the Deck player does; draft keys follow the editor's state.
    if status.isNil: draftVariant(entry, state) else: selectKeyVisual(entry, status)
  proc source(entry: JsonNode, pressed: bool): PreviewSource =
    ## Convert one manifest key into frames, using compiled art for built-in numbers.
    if entry.isNil: return
    if entry.hasKey("builtinNumber"):
      let number = entry["builtinNumber"].getInt()
      result.frames.add((BuiltinPrefix & $number & (if pressed: ":pressed" else: ":normal"), 0))
    elif pressed:
      if entry{"pressed"}.getStr().len > 0:
        result.frames.add((entry["pressed"].getStr(), 0))
    else:
      for frame in entry{"normal"}.getElems():
        result.frames.add((frame{"path"}.getStr(), frame{"durationMs"}.getInt(100)))
  if keys.isNil: return
  proc keyEntry(key: int): JsonNode =
    ## Return the manifest entry the effective page shows on one key.
    manifest{"menus"}{effectiveDeckMenu(menu, drawer, key, menuKey)}{$key}
  for key in 1..DeckKeyCount:
    result.sources[key - 1] = source(shown(keyEntry(key)), false)
  if selectedKey in 1..DeckKeyCount:
    result.sources[PressedSlot] = source(shown(keyEntry(selectedKey)), true)

proc resolveLivePage(page: var PreviewPage, cachedPath: var string, cached: var JsonNode): string =
  ## Fill a live page from the daemon's active manifest file, returning a failure message or "".
  if page.manifestPath.len == 0: return
  try:
    if page.manifestPath != cachedPath:
      cached = parseFile(page.manifestPath)
      cachedPath = page.manifestPath
    for menu in [page.menu, page.drawer]:
      if menu.len > 0 and cached{"menus"}{menu}.isNil:
        raise newException(ValueError, "Active manifest has no menu " & menu & ".")
    let status = if page.indicators.len == 0: %*{"obs": unavailableObsStatus(),
      "controls": unavailableControlStatus()} else: parseJson(page.indicators)
    page.sources = cached.menuPage(page.menu, page.pressedKey, status = status,
      drawer = page.drawer, menuKey = page.menuKey).sources
  except CatchableError as failure:
    cachedPath = ""
    cached = nil
    result = "Live key images unavailable: " & failure.msg

proc playerLoop() {.thread.} =
  ## Decode only the frame due on each visible key, publishing changed pixels to the render thread.
  var
    page: PreviewPage
    generation = -1
    started = nowMs()
    shown: array[PreviewSlotCount, string]
    cache: Table[string, seq[ColorRGBX]]
    cacheBytes = 0
    manifestPath: string
    manifest: JsonNode
  while not playerStopping.load():
    var changed = false
    {.cast(gcsafe).}:
      withLock playerLock:
        if generation != playerGeneration:
          page = playerPage
          generation = playerGeneration
          changed = true
    if changed:
      # Manifests are revision-addressed and immutable, so the last parsed one is reused.
      let pageError = page.resolveLivePage(manifestPath, manifest)
      {.cast(gcsafe).}:
        withLock playerLock:
          if generation == playerGeneration: playerPageError = pageError
      started = nowMs()
      for slot in shown.mitems: slot = "\0"
    let elapsed = nowMs() - started
    var animated = false
    for slot in 0..<PreviewSlotCount:
      template source: untyped = page.sources[slot]
      var path = ""
      if source.frames.len > 0:
        animated = animated or source.frames.len > 1
        var total = 0
        for frame in source.frames: total += max(frame.durationMs, 1)
        var offset = if source.frames.len > 1: int(elapsed mod total) else: 0
        for frame in source.frames:
          path = frame.path
          offset -= max(frame.durationMs, 1)
          if offset < 0: break
      if path == shown[slot]: continue
      shown[slot] = path
      var
        pixels: seq[ColorRGBX]
        error = ""
      if path.len == 0:
        pixels = blankPixels()
      elif path in cache:
        pixels = cache[path]
      else:
        try:
          pixels = decodePreview(path)
          if cacheBytes > PreviewCacheBytes:
            cache.clear()
            cacheBytes = 0
          cache[path] = pixels
          cacheBytes += pixels.len * 4
        except CatchableError as failure:
          pixels = blankPixels()
          error = failure.msg
      {.cast(gcsafe).}:
        withLock playerLock:
          playerSlots[slot].pixels = move(pixels)
          playerSlots[slot].error = error
          playerSlots[slot].page = generation
          inc playerSlots[slot].generation
    sleep(if animated: PlayerPollMs else: PlayerIdleMs)

proc requestFailure(kind: JobKind, error: ref CatchableError): ConfigReply =
  ## Turn a client failure into a reply the editor can show beside the draft.
  result = ConfigReply(kind: kind, error: error.msg)
  if error of ConfigRequestError:
    let failure = (ref ConfigRequestError)(error)
    result.code = failure.code
    result.field = failure.field
    if failure.code == "version":
      result.error = "The running daemon speaks a different protocol. Install and restart Knobby to edit buttons."
  elif error of IOError or error of OSError:
    result.code = "unavailable"
    result.error = "Daemon unavailable: " & error.msg &
      " Start or update the Knobby daemon; edits stay in the draft."

proc importSource(source: string): JsonNode =
  ## Copy an absolute image path into the daemon's managed asset directory.
  let path = source.strip().expandTilde()
  if not path.isAbsolute():
    raise newException(ValueError, "Choose an absolute image path.")
  if not fileExists(path):
    raise newException(ValueError, "Image file not found: " & path)
  if path.splitFile().ext.toLowerAscii() notin ImageExtensions:
    raise newException(ValueError, "Images must be PNG, JPEG, or GIF files.")
  let record = runConfigOperation("config.importAsset", %*{"source": path})
  %*{"path": record["path"].getStr(), "source": path}

proc runJob(job: ConfigJob): ConfigReply =
  ## Perform one blocking config request; only the worker thread calls this.
  result = ConfigReply(kind: job.kind, ok: true)
  try:
    case job.kind
    of LoadJob:
      let reply = requireConfigResult(requestConfig("config.get"))
      var payload = %*{"envelope": reply["envelope"],
        "startupError": reply{"startupError"}.getStr()}
      try:
        let draft = readDraft(draftPath())
        if not draft.isNil: payload["draft"] = draft
      except CatchableError as failure:
        payload["draftError"] = %failure.msg
      result.payload = $payload
    of ApplyJob:
      let record = runConfigOperation("config.apply", %*{"envelope": parseJson(job.payload)})
      var payload = %*{"record": record}
      try:
        payload["envelope"] = requireConfigResult(requestConfig("config.get"))["envelope"]
      except CatchableError as failure:
        # The apply already succeeded, so the editor adopts the submitted configuration instead.
        stderr.writeLine("Reloading the applied button configuration failed: " & failure.msg)
      result.payload = $payload
    of PreviewJob:
      let record = runConfigOperation("config.preview", %*{"config": parseJson(job.payload)})
      result.payload = $parseFile(record["manifestPath"].getStr())
    of ImportJob:
      result.payload = $importSource(job.payload)
    of BrowseJob:
      if findExe("zenity").len == 0:
        raise newException(ValueError,
          "The file dialog needs zenity. Paste an absolute image path and choose Import.")
      let chosen = openFileDialog("Choose a key image", ImageFilters, getHomeDir())
      result.payload = if chosen.len == 0: $(%*{"cancelled": true}) else: $importSource(chosen)
  except CatchableError as error:
    result = requestFailure(job.kind, error)

proc workerLoop() {.thread.} =
  ## Serve config jobs one at a time; the editor submits at most one outstanding job.
  while true:
    let job = jobs.recv()
    if job.payload == "\0stop": break
    workerBusy.store(true)
    var reply: ConfigReply
    {.cast(gcsafe).}:
      reply = runJob(job)
    replies.send(reply)
    workerBusy.store(false)

proc startEditorWorkers*() =
  ## Start the config worker and preview player once per process.
  if workersStarted: return
  workersStarted = true
  jobs.open(1)
  replies.open()
  createThread(workerThread, workerLoop)
  createThread(playerThread, playerLoop)

proc stopEditorWorkers*() =
  ## Stop the preview player and an idle worker; a running daemon request ends with the process.
  if not workersStarted: return
  playerStopping.store(true)
  joinThread(playerThread)
  # The daemon finishes an accepted operation on its own, so quitting the viewer
  # never waits for a media preparation that may take minutes.
  if not workerBusy.load() and jobs.trySend(ConfigJob(payload: "\0stop")):
    joinThread(workerThread)
  workersStarted = false

proc reservePreviewSlots(sk: Silky) =
  ## Reserve fixed atlas regions once; animation later rewrites only these pixels.
  let blank = newImage(PreviewSize, PreviewSize)
  blank.fill(Black)
  for slot in 0..<PreviewSlotCount:
    if not sk.builder.addImage("preview." & $slot, blank):
      raise newException(SilkyAtlasError, "No atlas space for Stream Deck previews.")
  sk.image = sk.builder.atlasImage
  sk.atlas = sk.builder.atlas
  sk.uploadAtlas()

proc newButtonEditor*(sk: Silky): ButtonEditor =
  ## Create the editor, reserving its bounded preview atlas slots.
  sk.reservePreviewSlots()
  result = ButtonEditor(model: newEditorModel(), saver: newDraftSaver(draftPath()),
    glyphs: GlyphCache(typeface: parseTtf(FontBytes)))
  for slot in result.slotUploaded.mitems: slot = -1
  for slot in result.slotPage.mitems: slot = -1

proc submit(editor: ButtonEditor, kind: JobKind, payload: string): bool =
  ## Start one background job when the worker is idle.
  if editor.busy: return false
  if not jobs.trySend(ConfigJob(kind: kind, payload: payload)):
    return false
  editor.busy = true
  editor.busyKind = kind
  true

proc request*(editor: ButtonEditor, kind: JobKind) =
  ## Ask for a job, keeping at most one pending request of each kind.
  editor.queued.incl(kind)

proc requestImport*(editor: ButtonEditor, source: string) =
  ## Import an image into the selected Deck slot without touching the draft until it succeeds.
  if editor.model.device != DeckDevice or editor.model.selectedLocked():
    editor.model.setError("Select an editable Stream Deck key before importing an image.")
    return
  editor.queuedImport = source
  editor.importTarget = ImportTarget(menu: editor.model.menu, key: editor.model.key,
    state: editor.model.visualState)
  editor.queued.incl(ImportJob)

proc liveDeckSource*(editor: ButtonEditor): tuple[manifestPath, menu, drawer: string, menuKey: int] =
  ## Return the daemon's active Deck manifest, underlying menu, open drawer, and Menu key, never
  ## the draft. A daemon that predates the key 5 Menu reports no key and uses the key 1 drawer.
  if editor.status.isNil or editor.status.kind != JObject: return
  (editor.status{"manifestPath"}.getStr(), editor.status{"deckMenu"}.getStr(),
    editor.status{"deckDrawer"}.getStr(), editor.status{"deckMenuKey"}.getInt(LegacyMenuKey))

proc indicators*(editor: ButtonEditor): JsonNode =
  ## Combine the daemon's OBS and control status exactly as the Deck player reads them.
  %*{"obs": if editor.obsStatus.isNil: newJNull() else: editor.obsStatus,
    "controls": if editor.controlStatus.isNil: newJNull() else: editor.controlStatus}

proc liveStatusSignature(editor: ButtonEditor): string =
  ## Summarize the visual state of every status action, so heartbeats alone never republish the page.
  let indicators = editor.indicators()
  for operation in ObsOperations:
    result.add(operation & "=" & actionVisualState("obs", operation, indicators) & ";")
  for kind in ControlActionKinds:
    result.add(kind & "=" & actionVisualState(kind, "", indicators) & ";")

proc publishPreviewPage(editor: ButtonEditor, view: PreviewView) =
  ## Send the visible view's frames to the player, or an empty page so hidden views stay idle.
  let
    live = editor.liveDeckSource()
    key =
      case view
      of NoPreview: ""
      of LivePreview:
        if live.manifestPath.len == 0 or live.menu.len == 0: ""
        else: "live/" & live.manifestPath & "/" & live.menu & "/" & live.drawer & "/" & $live.menuKey & "/" &
          $editor.liveKey & "/" & editor.liveStatusSignature()
      of DraftPreview:
        if editor.manifest.isNil or editor.model.device != DeckDevice: ""
        else: "draft/" & editor.model.menu & "/" & $editor.model.key & "/" & $editor.previewEdits &
          "/" & editor.model.visualState
  if key == editor.pageKey: return
  editor.pageKey = key
  var page = PreviewPage()
  if key.len > 0 and view == LivePreview:
    page = PreviewPage(manifestPath: live.manifestPath, menu: live.menu, drawer: live.drawer,
      menuKey: live.menuKey,
      pressedKey: editor.liveKey, indicators: $editor.indicators())
  elif key.len > 0:
    page = editor.manifest.menuPage(editor.model.menu, editor.model.key, editor.model.visualState)
  withLock playerLock:
    playerPage = page
    playerPageError = ""
    inc playerGeneration
    editor.publishedPage = playerGeneration

proc syncPreviewSlots*(sk: Silky, editor: ButtonEditor) =
  ## Copy decoded frames into their reserved atlas regions with partial texture uploads.
  var bound = false
  withLock playerLock:
    editor.liveArtError = playerPageError
    for slot in 0..<PreviewSlotCount:
      let pixels = playerSlots[slot]
      if pixels.generation == editor.slotUploaded[slot] or pixels.pixels.len == 0: continue
      editor.slotUploaded[slot] = pixels.generation
      editor.slotPage[slot] = pixels.page
      let entry = sk.atlas.entries["preview." & $slot]
      for y in 0..<PreviewSize:
        copyMem(addr sk.image.data[sk.image.dataIndex(entry.x, entry.y + y)],
          unsafeAddr pixels.pixels[y * PreviewSize], PreviewSize * 4)
      if not bound:
        glActiveTexture(GL_TEXTURE0)
        glBindTexture(GL_TEXTURE_2D, sk.drawer.atlasTextureId)
        bound = true
      glTexSubImage2D(GL_TEXTURE_2D, 0, entry.x.GLint, entry.y.GLint,
        PreviewSize.GLsizei, PreviewSize.GLsizei, GL_RGBA, GL_UNSIGNED_BYTE,
        unsafeAddr pixels.pixels[0])

proc previewCurrent*(editor: ButtonEditor, slot: int): bool =
  ## Report whether a reserved slot holds pixels for the page currently published.
  editor.pageKey.len > 0 and editor.slotPage[slot] == editor.publishedPage

proc drawPreview*(sk: Silky, editor: ButtonEditor, slot: int, position: Vec2) =
  ## Draw a preview slot, showing black until it holds frames of the current page.
  if editor.previewCurrent(slot):
    sk.drawImage("preview." & $slot, position)
  else:
    sk.drawRect(position, vec2(PreviewSize, PreviewSize), Black)

proc hasLiveStatus*(entry: JsonNode): bool =
  ## Report whether a configured slot's action has observed status.
  entry.actionKind() == ObsAction or entry{"action"}{"kind"}.getStr().isControlAction()

proc liveKeyState*(editor: ButtonEditor, entry: JsonNode): string =
  ## Return the visual state the live Deck shows for a status key, from the daemon's actual status.
  actionVisualState(entry{"action"}{"kind"}.getStr(), entry.obsOperation(), editor.indicators())

proc liveKeyDescription*(editor: ButtonEditor, entry: JsonNode): string =
  ## Explain a live OBS, Minecraft, microphone, or Discord key using the daemon's authoritative status.
  actionStatusDescription(entry{"action"}{"kind"}.getStr(), entry.obsOperation(), editor.indicators())

proc liveDeckReady*(editor: ButtonEditor): bool =
  ## Report whether the daemon published an active Deck manifest the live view can show.
  let live = editor.liveDeckSource()
  live.manifestPath.len > 0 and live.menu.len > 0

proc slotDecodeError*(slot: int): string =
  ## Return the decode failure for one preview slot.
  withLock playerLock: result = playerSlots[slot].error

proc rasterize(builder: AtlasBuilder, typeface: Typeface, font: FontAtlas,
    rune: Rune): seq[LetterEntry] =
  ## Rasterize one glyph like Silky's atlas builder, including fractional-position variants.
  let
    pixelScale = font.size / typeface.scale
    path = typeface.getGlyphPath(rune)
    matrix = scale(vec2(pixelScale))
    advance = typeface.getAdvance(rune) * pixelScale
  var bounds = path.computeBounds(matrix).snapToPixels()
  for value in [bounds.x, bounds.y, bounds.w, bounds.h]:
    if value.classify notin {fcNormal, fcSubnormal, fcZero, fcNegZero}:
      bounds = rect(0, 0, 0, 0)
  for variant in 0..<max(font.subpixelSteps, 1):
    let
      offset = if font.subpixelSteps > 0: variant.float32 / font.subpixelSteps.float32 else: 0'f32
      width = (bounds.w + (if offset > 0: 1'f32 else: 0'f32)).ceil.int
      height = bounds.h.ceil.int
    if width <= 0 or height <= 0:
      result.add(LetterEntry(boundsX: bounds.x, boundsY: bounds.y,
        boundsWidth: bounds.w, boundsHeight: bounds.h, advance: advance))
      continue
    let image = newImage(width, height)
    image.fillPath(path, color(1, 1, 1, 1),
      translate(vec2(-bounds.x + offset, -bounds.y)) * matrix)
    var allocation = builder.allocator.allocate(width, height)
    if not allocation.success and builder.size < MaxAtlasSize:
      builder.growAtlas(builder.size * 2)
      allocation = builder.allocator.allocate(width, height)
    if not allocation.success:
      raise newException(SilkyAtlasError, "Glyph atlas is full.")
    builder.atlasImage.draw(image, translate(vec2(allocation.x.float32,
      allocation.y.float32)), OverwriteBlend)
    result.add(LetterEntry(x: allocation.x, y: allocation.y, boundsX: bounds.x,
      boundsY: bounds.y, boundsWidth: width.float32, boundsHeight: height.float32,
      advance: advance))

proc requestGlyphs*(editor: ButtonEditor, sk: Silky, text: string) =
  ## Queue user-entered characters missing from the native-size atlas.
  let body = sk.atlas.fonts["Body"]
  for rune in text.runes:
    if rune.int32 < 0x20 or rune in body.lookup.entries or rune in editor.glyphs.checked:
      continue
    editor.glyphs.checked.incl(rune)
    editor.glyphs.pending.add(rune)

proc addGlyph(sk: Silky, editor: ButtonEditor, rune: Rune) =
  ## Add one font glyph to every user-text font, or alias it to the visible replacement glyph.
  let
    typeface = editor.glyphs.typeface
    key = $rune
  for name in DynamicFonts:
    let font = sk.atlas.fonts[name]
    if not typeface.hasGlyph(rune):
      if ReplacementKey notin font.entries:
        font.entries[ReplacementKey] = sk.builder.rasterize(typeface, font, ReplacementRune)
      font.entries[key] = font.entries[ReplacementKey]
      continue
    let pixelScale = font.size / typeface.scale
    var entries = sk.builder.rasterize(typeface, font, rune)
    for other, variants in font.entries.mpairs:
      if other.len == 0 or variants.len == 0: continue
      let otherRune = other.runeAt(0)
      let before = typeface.getKerningAdjustment(otherRune, rune)
      if before != 0: variants[0].kerning[key] = before * pixelScale
      let after = typeface.getKerningAdjustment(rune, otherRune)
      if after != 0: entries[0].kerning[other] = after * pixelScale
    font.entries[key] = entries

proc flushGlyphs*(sk: Silky, editor: ButtonEditor) =
  ## Add queued glyphs and upload the atlas once; overflow keeps Silky's visible fallback.
  if editor.glyphs.pending.len == 0: return
  var changed = false
  for rune in editor.glyphs.pending:
    if editor.glyphs.added >= MaxDynamicGlyphs: break
    try:
      sk.addGlyph(editor, rune)
      inc editor.glyphs.added
      changed = true
    except SilkyAtlasError:
      editor.glyphs.added = MaxDynamicGlyphs
  editor.glyphs.pending.setLen(0)
  if changed:
    for name in DynamicFonts: sk.atlas.fonts[name].rebuildGlyphLookups()
    sk.image = sk.builder.atlasImage
    sk.atlas = sk.builder.atlas
    sk.uploadAtlas()

proc hasGlyph*(sk: Silky, font: string, rune: Rune): bool =
  ## Report whether a font currently renders a rune from its own atlas entry.
  rune in sk.atlas.fonts[font].lookup.entries

proc record*(editor: ButtonEditor, name: string, bounds: Rect) =
  ## Remember a control's bounds for the isolated interaction fixture.
  if editor.recordRects: editor.rects[name] = bounds

proc text(sk: Silky, editor: ButtonEditor, value: string, x, y, width: float32,
    font = "Body", color = Foreground): float32 =
  ## Draw user-provided text after requesting any glyphs it needs.
  editor.requestGlyphs(sk, value)
  sk.label(value, x, y, width, font, color)

proc line(sk: Silky, editor: ButtonEditor, value: string, x, y, width: float32,
    font = "Body", color = Foreground) =
  ## Draw one clipped line of user text without wrapping into neighbouring controls.
  editor.requestGlyphs(sk, value)
  discard sk.drawText(font, value, vec2(round(x), round(y)), color,
    maxWidth = floor(width), maxHeight = sk.atlas.fonts[font].lineHeight.ceil)

proc chip(sk: Silky, editor: ButtonEditor, name: string, bounds: Rect, value: string,
    active = false, enabled = true, danger = false): bool =
  ## Draw a selectable control; it reports clicks only when enabled.
  editor.record(name, bounds)
  let
    interaction = sk.interact(bounds, enabled)
    hover = interaction in {Hovered, Held, Pressed, Released}
    fill =
      if not enabled: Panel
      elif active: Accent
      elif hover: TileHover
      else: Tile
    color =
      if not enabled: Muted
      elif active: Background
      elif danger: Danger
      else: Foreground
  sk.drawRect(bounds.xy, bounds.wh, fill)
  editor.requestGlyphs(sk, value)
  discard sk.drawText("Small", value, bounds.xy + vec2(6, 0), color,
    maxWidth = bounds.w - 12, maxHeight = bounds.h, hAlign = CenterAlign, vAlign = MiddleAlign)
  enabled and interaction == Released

proc checkbox(sk: Silky, editor: ButtonEditor, name: string, x, y, width: float32,
    caption: string, value: bool, enabled = true): bool =
  ## Draw a labeled checkbox and report a toggle click.
  let bounds = rect(x, y, width, 24)
  editor.record(name, bounds)
  let interaction = sk.interact(bounds, enabled)
  sk.drawRect(vec2(x, y + 3), vec2(18, 18), if enabled: Muted else: Tile)
  sk.drawRect(vec2(x + 2, y + 5), vec2(14, 14), if value: Accent else: Background)
  discard sk.label(caption, x + 28, y + 2, width - 28, "Body", if enabled: Foreground else: Muted)
  enabled and interaction == Released

proc field(editor: ButtonEditor, name: string): EditorField =
  ## Return the persistent text state for one editor input.
  if name notin editor.fields:
    editor.fields[name] = EditorField(state: TextBoxState(dirty: true, singleLine: true))
  editor.fields[name]

proc unfocus(editor: ButtonEditor) =
  ## End text entry in every editor field.
  for field in editor.fields.values: field.focused = false

proc focusedField*(editor: ButtonEditor): string =
  ## Return the focused field name, or "" when keyboard input is not captured.
  for name, field in editor.fields:
    if field.focused: return name

proc focusField*(editor: ButtonEditor, name: string) =
  ## Focus an input for scripted fixtures and keyboard-first workflows.
  editor.unfocus()
  let field = editor.field(name)
  field.focused = true
  field.original = field.state.getText()
  field.state.cursor = field.state.runes.len
  field.state.selector = 0

proc textField(sk: Silky, window: Window, editor: ButtonEditor, name, binding: string,
    bounds: Rect, value: string, enabled = true, error = false,
    placeholder = ""): tuple[changed, submitted: bool, text: string] =
  ## Edit one line of Unicode text with native-size glyphs, selection, clipboard, and undo.
  editor.record(name, bounds)
  let
    field = editor.field(name)
    state = field.state
    fontData = sk.atlas.fonts["Body"]
    inner = rect(bounds.x + 8, bounds.y, bounds.w - 16, bounds.h)
  field.drawn = true
  state.enabled = enabled
  if field.binding != binding:
    field.binding = binding
    field.focused = false
    state.setText(value)
    state.scrollPos = vec2(0, 0)
  if not field.focused and state.getText() != value:
    state.setText(value)
  if not enabled: field.focused = false
  let mouseInside = sk.mousePos.overlaps(bounds) and sk.mousePos.overlaps(sk.clipRect)
  state.boxSize = vec2(inner.w, fontData.lineHeight)
  if state.dirty: state.computeLayout(fontData, float32.high)
  let textTop = round(bounds.y + (bounds.h - fontData.lineHeight) / 2)
  if sk.buttonPressed[MouseLeft]:
    if mouseInside and enabled:
      if not field.focused:
        editor.unfocus()
        field.focused = true
        field.original = state.getText()
      state.mouseAction(sk.mousePos - vec2(inner.x, textTop) + state.scrollPos, click = true)
      state.resetBlink()
    elif field.focused:
      field.focused = false
  elif field.focused and sk.buttonDown[MouseLeft] and mouseInside:
    state.mouseAction(sk.mousePos - vec2(inner.x, textTop) + state.scrollPos, click = false, shift = true)
  sk.textInputs.submitInput(window, name, field.focused, enabled)
  result.text = state.getText()
  if field.focused:
    let before = state.getText()
    for event in sk.textInputs.takeInput():
      case event.kind
      of TextInput:
        state.typeCharacter(event.rune)
      of InputKind.KeyDown:
        let control = event.control and not event.alt
        case event.button
        of KeyBackspace: state.backspace()
        of KeyDelete: state.delete()
        of KeyLeft:
          if control: state.leftWord(event.shift) else: state.left(event.shift)
        of KeyRight:
          if control: state.rightWord(event.shift) else: state.right(event.shift)
        of KeyHome: state.startOfLine(event.shift)
        of KeyEnd: state.endOfLine(event.shift)
        of KeyEnter, KeyTab:
          field.focused = false
          result.submitted = event.button == KeyEnter
        of KeyEscape:
          state.setText(field.original)
          field.focused = false
        of KeyA:
          if control: state.selectAll()
        of KeyC:
          if control and state.copyText().len > 0: setClipboardString(state.copyText())
        of KeyX:
          if control:
            let cut = state.cutText()
            if cut.len > 0: setClipboardString(cut)
        of KeyV:
          if control: state.pasteText(getClipboardString())
        of KeyZ:
          if control:
            if event.shift: state.redo() else: state.undo()
        of KeyY:
          if control: state.redo()
        else: discard
      of InputKind.KeyUp: discard
    result.text = state.getText()
    if result.text != before:
      result.changed = true
      editor.requestGlyphs(sk, result.text)
      sk.flushGlyphs(editor)
      state.dirty = true
    if state.dirty: state.computeLayout(fontData, float32.high)
    state.scrollToCursor()
    if not field.focused:
      sk.textInputs.submitInput(window, name, false, enabled)
  state.scrollPos.x = max(0'f32, state.scrollPos.x)
  let border =
    if error: Danger
    elif field.focused: Accent
    else: Tile
  sk.drawRect(bounds.xy, bounds.wh, border)
  sk.drawRect(bounds.xy + vec2(1, 1), bounds.wh - vec2(2, 2), if enabled: Background else: Panel)
  sk.pushClipRect(inner)
  let origin = vec2(inner.x - round(state.scrollPos.x), textTop)
  if field.focused and state.cursor != state.selector:
    let selection = state.selection
    for area in getSelectionRects(state.layout, selection.a, selection.b):
      sk.drawRect(origin + area.xy, area.wh, rgbx(48, 92, 120, 255))
  if result.text.len == 0 and not field.focused and placeholder.len > 0:
    discard sk.drawText("Body", placeholder, origin, Muted, clip = false)
  else:
    editor.requestGlyphs(sk, result.text)
    discard sk.drawText("Body", result.text, origin, if enabled: Foreground else: Muted, clip = false)
  if field.focused and state.cursorVisible:
    let caret = state.locationRect(state.cursor)
    sk.drawRect(vec2(round(origin.x + caret.x), origin.y), vec2(CursorWidth, fontData.lineHeight.ceil), Foreground)
  sk.popClipRect()

proc releaseUndrawnFields*(editor: ButtonEditor) =
  ## Drop focus from inputs that disappeared, so keyboard capture never outlives its field.
  for field in editor.fields.values:
    if not field.drawn: field.focused = false
    field.drawn = false

proc shortRevision(revision: string): string =
  ## Show a compact, recognizable revision prefix.
  if revision.len > 8: revision[0..<8] else: revision

proc liveSummary(editor: ButtonEditor): string =
  ## Describe the daemon's active menus independently of the menu being edited.
  let status = editor.status
  if status.isNil or status.kind != JObject or status{"revision"}.getStr().len == 0:
    return "Daemon status unavailable; edits stay in the draft."
  let config = if editor.model.loaded: editor.model.live else: nil
  proc title(id: string): string =
    ## Resolve a live menu title when the live configuration is loaded.
    if config.isNil: id else: config.menuTitle(id)
  "Live: mixer on " & title(status{"mixerMenu"}.getStr()) & " / Deck on " &
    title(status{"deckMenu"}.getStr()) & " / revision " & shortRevision(status["revision"].getStr())

proc keyName(device: ButtonDevice, key: int): string =
  ## Name a physical slot the way the hardware documentation does.
  case device
  of MixerDevice: "Mixer note " & $key
  of DeckDevice: "Deck key " & $key

proc drawSlot(sk: Silky, editor: ButtonEditor, bounds: Rect, key: int, showPreview: bool) =
  ## Draw one grid slot; clicking only selects it for editing.
  let
    model = editor.model
    entry = model.draft.entryAt(model.menu, model.device, key)
    selected = model.key == key
    locked = model.draft.isLockedBack(model.menu, key)
    problem = model.slotHasProblem(model.menu, model.device, key)
    name = "key:" & $key
  editor.record(name, bounds)
  if sk.tile(bounds, selected, false):
    editor.model.selectKey(key)
    editor.scroll = 0
  if problem:
    sk.drawRect(bounds.xy, vec2(bounds.w, 3), Danger)
  let
    title = entry{"title"}.getStr()
    inner = bounds.w - 20
  var y = bounds.y + 8
  let caption = (if model.device == MixerDevice: "NOTE " else: "KEY ") & $key &
    (if locked: " / BACK" else: "")
  discard sk.drawText("Small", caption, vec2(bounds.x + 10, y), Muted,
    maxWidth = inner, maxHeight = 18)
  y += 20
  if showPreview:
    let previewPos = vec2(round(bounds.x + (bounds.w - PreviewSize) / 2), y)
    sk.drawPreview(editor, key - 1, previewPos)
    editor.record("preview:" & $key, rect(previewPos, vec2(PreviewSize, PreviewSize)))
  else:
    sk.line(editor, if title.len > 0: title else: "Untitled", bounds.x + 10, y,
      inner, "Body", if title.len > 0: Foreground else: Muted)
    y += 24
    sk.line(editor, model.draft.describeAction(entry), bounds.x + 10, y, inner, "Small", Muted)

proc drawGrid(sk: Silky, editor: ButtonEditor, x, y, width: float32) =
  ## Lay out the mixer's physical note grid or the Deck's 5x3 key grid.
  case editor.model.device
  of MixerDevice:
    let column = floor(min((width - 3 * Gap) / 4, 170'f32))
    for row in 0..2:
      for col in 0..3:
        let bounds = rect(x + col.float32 * (column + Gap), y + row.float32 * (82 + Gap), column, 82)
        sk.drawSlot(editor, bounds, ButtonGrid[row][col], false)
  of DeckDevice:
    let
      size = floor(min((width - 4 * Gap) / 5, 112'f32))
      showPreview = size >= PreviewSize + 20 and not editor.manifest.isNil
      height = if showPreview: PreviewSize.float32 + 40 else: 82'f32
    for index in 0..<DeckKeyCount:
      let bounds = rect(x + (index mod 5).float32 * (size + Gap),
        y + (index div 5).float32 * (height + Gap), size, height)
      sk.drawSlot(editor, bounds, index + 1, showPreview)

template applyEdit(editor: ButtonEditor, body: untyped) =
  ## Run a model edit, showing rejected edits inline instead of losing the draft.
  try:
    body
  except ValueError as error:
    editor.model.setError(error.msg)

proc drawMenus*(sk: Silky, window: Window, editor: ButtonEditor, height: float32) =
  ## Draw the sidebar menu browser and the create-menu control.
  let
    model = editor.model
    top = EditorPageTop + 72
    bottom = height - 96
  discard sk.label("Menus", 22, top, 150, "Small", Muted)
  if not model.loaded: return
  let mixerLive = editor.status{"mixerMenu"}.getStr()
  let deckLive = editor.status{"deckMenu"}.getStr()
  var y = top + 26
  sk.pushClipRect(rect(0, y, SidebarWidth, max(0'f32, bottom - y)))
  for id in model.draft.menuIds():
    let bounds = rect(12, y, SidebarWidth - 24, MenuRowHeight)
    editor.record("menu:" & id, bounds)
    let
      selected = id == model.menu
      interaction = sk.interact(bounds, true)
    sk.drawRect(bounds.xy, bounds.wh,
      if selected: Accent elif interaction in {Hovered, Held, Pressed, Released}: TileHover else: Panel)
    if model.menuHasProblem(id):
      sk.drawRect(bounds.xy, vec2(3, bounds.h), Danger)
    let live =
      if id == mixerLive and id == deckLive: "both"
      elif id == mixerLive: "mixer"
      elif id == deckLive: "deck"
      else: ""
    let liveWidth = if live.len > 0: sk.getTextSize("Small", live).x.ceil + 8 else: 0'f32
    sk.line(editor, model.draft.menuTitle(id), bounds.x + 10, y + 7,
      bounds.w - 20 - liveWidth, "Body", if selected: Background else: Foreground)
    if live.len > 0:
      discard sk.drawText("Small", live, vec2(bounds.x + bounds.w - liveWidth - 2, y + 9),
        if selected: Background else: Accent)
    if interaction == Released and not selected:
      editor.applyEdit: editor.model.selectMenu(id)
      editor.scroll = 0
    y += MenuRowHeight + 4
  sk.popClipRect()
  let
    fieldTop = height - 84
    fieldBounds = rect(12, fieldTop, SidebarWidth - 24 - 52, FieldHeight)
    edited = sk.textField(window, editor, "newMenu", "newMenu", fieldBounds,
      editor.newMenuTitle, placeholder = "New menu")
  editor.newMenuTitle = edited.text
  let add = sk.chip(editor, "addMenu", rect(SidebarWidth - 12 - 46, fieldTop, 46, FieldHeight),
    "Add", enabled = editor.newMenuTitle.strip().len > 0)
  if add or (edited.submitted and editor.newMenuTitle.strip().len > 0):
    editor.applyEdit:
      discard editor.model.createMenu(editor.newMenuTitle)
      editor.newMenuTitle = ""

proc drawToolbar(sk: Silky, window: Window, editor: ButtonEditor, x, width: float32) =
  ## Draw device selection and the selected menu's rename and delete controls.
  for device in ButtonDevice:
    let bounds = rect(x + device.ord.float32 * 158, 110, 150, ChipHeight)
    if sk.chip(editor, "device:" & $device, bounds, DeviceLabels[device],
        active = editor.model.device == device):
      editor.model.selectDevice(device)
      editor.scroll = 0
  let
    model = editor.model
    isRoot = model.menu == model.draft.rootMenu()
    top = 156'f32
  discard sk.label("Menu title", x, top + 9, 80, "Small", Muted)
  let
    fieldWidth = max(120'f32, min(280'f32, width - 88 - 130))
    renamed = sk.textField(window, editor, "menuTitle", "menuTitle:" & model.menu,
      rect(x + 88, top, fieldWidth, FieldHeight), model.draft.menuTitle(model.menu),
      error = model.menuHasProblem(model.menu) and model.problemField().endsWith(".title"))
  if renamed.changed:
    editor.applyEdit: editor.model.renameMenu(model.menu, renamed.text)
  let deleteBounds = rect(x + 88 + fieldWidth + Gap, top, 120, FieldHeight)
  if sk.chip(editor, "deleteMenu", deleteBounds, "Delete menu", enabled = not isRoot, danger = true):
    editor.applyEdit: editor.model.deleteMenu(model.menu)

proc drawDetails(sk: Silky, window: Window, editor: ButtonEditor, x, height: float32) =
  ## Edit the selected slot: title, action, targets, image, overlay, and exact preview.
  let
    width = DetailWidth - 36
    top = 159'f32
    model = editor.model
    entry = model.selected()
    locked = model.selectedLocked()
    kind = entry.actionKind()
    binding = model.menu & ":" & $model.device & ":" & $model.key
    slotProblem = model.slotHasProblem(model.menu, model.device, model.key)
  var y = top - round(editor.scroll)
  sk.pushClipRect(rect(x - 6, top, width + 12, height - top - 35))
  defer: sk.popClipRect()
  template heading(value: string) =
    discard sk.label(value, x, y, width, "Small", Muted)
    y += 22
  y += sk.label(keyName(model.device, model.key), x, y, width, "Title") + 4
  y += sk.text(editor, "Menu: " & model.draft.menuTitle(model.menu), x, y, width, "Small", Accent) + 14
  if model.device == DeckDevice:
    let manifestEntry = editor.manifest{"menus"}{model.menu}{$model.key}
    if editor.manifest.isNil:
      y += sk.label(if editor.previewError.len > 0: editor.previewError else: "Preparing preview...",
        x, y, width, "Small", if editor.previewError.len > 0: Danger else: Muted) + 8
    else:
      for (slot, caption, offset) in [(model.key - 1, "Normal", 0'f32), (PressedSlot, "Pressed", 90'f32)]:
        let position = vec2(x + offset, y)
        if manifestEntry.isNil:
          sk.drawRect(position, vec2(PreviewSize, PreviewSize), Black)
        else:
          sk.drawPreview(editor, slot, position)
        editor.record("detailPreview:" & caption, rect(position, vec2(PreviewSize, PreviewSize)))
        discard sk.label(caption, x + offset, y + PreviewSize + 4, 80, "Small", Muted)
      y += PreviewSize + 24
      let
        decodeError = slotDecodeError(model.key - 1)
        message =
          if decodeError.len > 0: decodeError
          elif editor.previewError.len > 0: editor.previewError
          elif editor.previewEdits == model.edits:
            if model.visualState == NormalState or manifestEntry.isNil or
                not manifestEntry{"states"}{model.visualState}.isNil: ""
            else: "No " & stateLabel(model.visualState).toLowerAscii() & " image; the normal face is shown."
          elif model.validation.len > 0: "Preview resumes once the draft is valid."
          else: "Updating preview..."
        statusHeight = sk.atlas.fonts["Small"].lineHeight.ceil + 10
      y += max(statusHeight, sk.label(message, x, y, width, "Small",
        if decodeError.len > 0 or editor.previewError.len > 0: Danger else: Muted) + 10)
    let states = entry.entryStates()
    if states.len > 0:
      heading("Preview state")
      let chipWidth = floor((width - Gap) / 2)
      for index, state in @[NormalState] & states:
        let bounds = rect(x + (index mod 2).float32 * (chipWidth + Gap),
          y + (index div 2).float32 * (ChipHeight + 6), chipWidth, ChipHeight)
        if sk.chip(editor, "state:" & (if state.len == 0: "normal" else: state), bounds,
            stateLabel(state), active = model.visualState == state):
          editor.applyEdit: editor.model.selectVisualState(state)
      y += ((states.len + 2) div 2).float32 * (ChipHeight + 6) + 2
      y += sk.label("Previews the draft only; OBS and controls are not changed.", x, y, width,
        "Small", Muted) + 12
  if locked:
    y += sk.label(if kind == MenuAction: "Home returns the Deck directly to the main menu."
      else: "Back returns linked devices to their previous menu.",
      x, y, width, "Body", Muted) + 14
  else:
    heading("Title")
    let titled = sk.textField(window, editor, "title", binding, rect(x, y, width, FieldHeight),
      entry{"title"}.getStr(), error = slotProblem and model.problemField().endsWith(".title"),
      placeholder = "Untitled")
    if titled.changed:
      editor.applyEdit: editor.model.setTitle(titled.text)
    y += FieldHeight + 14
    heading("Action")
    let chipWidth = floor((width - Gap) / 2)
    var actions: seq[ConfigActionKind]
    for action in ConfigActionKind:
      let allowed =
        if action == BackAction: model.menu != model.draft.rootMenu()
        elif action == DeckMenuAction: model.device == DeckDevice and model.key in MenuKeys
        else: true
      if allowed: actions.add(action)
    for index, action in actions:
      let bounds = rect(x + (index mod 2).float32 * (chipWidth + Gap),
        y + (index div 2).float32 * (ChipHeight + 6), chipWidth, ChipHeight)
      if sk.chip(editor, "action:" & $action, bounds, ActionLabels[action], active = kind == action):
        editor.applyEdit: editor.model.setActionKind(action)
    y += ((actions.len + 1) div 2).float32 * (ChipHeight + 6) + 10
    let current = editor.model.selected()
    case current.actionKind()
    of CommandAction:
      heading("Command")
      let commanded = sk.textField(window, editor, "command", binding, rect(x, y, width, FieldHeight),
        current["action"]{"command"}.getStr(),
        error = slotProblem and model.problemField().endsWith(".command"),
        placeholder = "Shell command")
      if commanded.changed:
        editor.applyEdit: editor.model.setCommand(commanded.text)
      y += FieldHeight + 6
      y += sk.label("Runs through the shell when the key is pressed.", x, y, width, "Small", Muted) + 12
    of MenuAction:
      heading("Opens menu")
      let target = current["action"]{"menu"}.getStr()
      var listed = 0
      for id in model.draft.menuIds():
        if id == model.menu: continue
        if sk.chip(editor, "target:" & id, rect(x, y, width, ChipHeight),
            model.draft.menuTitle(id), active = id == target):
          editor.applyEdit: editor.model.setMenuTarget(id)
        y += ChipHeight + 6
        inc listed
      if listed == 0:
        y += sk.label("Create another menu in the sidebar first.", x, y, width, "Small", Danger) + 8
      y += 4
      heading("Opens on")
      let third = floor((width - 2 * Gap) / 3)
      for device in ButtonTarget:
        if sk.chip(editor, "on:" & $device, rect(x + device.ord.float32 * (third + Gap), y, third, ChipHeight),
            TargetLabels[device], active = current.menuTarget() == device):
          editor.applyEdit: editor.model.setTargetDevice(device)
      y += ChipHeight + 14
    of DeckMenuAction:
      heading("Drawer menu")
      let target = current["action"]{"menu"}.getStr()
      for id in model.draft.menuIds():
        if sk.chip(editor, "drawer:" & id, rect(x, y, width, ChipHeight),
            model.draft.menuTitle(id), active = id == target):
          editor.applyEdit: editor.model.setMenuTarget(id)
        y += ChipHeight + 6
      y += sk.label("Keys 1 to 5 of this menu cover the top row until Menu or a destination is pressed.",
        x, y, width, "Small", Muted) + 12
    of ObsAction:
      heading("OBS operation")
      let
        operation = current.obsOperation()
        half = floor((width - Gap) / 2)
      for index, choice in ObsOperations:
        let bounds = rect(x + (index mod 2).float32 * (half + Gap),
          y + (index div 2).float32 * (ChipHeight + 6), half, ChipHeight)
        if sk.chip(editor, "obsOp:" & choice, bounds, obsOperationLabel(choice), active = operation == choice):
          editor.applyEdit: editor.model.setObsOperation(choice)
      y += ((ObsOperations.len + 1) div 2).float32 * (ChipHeight + 6) + 2
      y += sk.label(obsOperationDescription(operation), x, y, width, "Small", Muted) + 12
    else: discard
    if model.device == DeckDevice:
      let state = editor.model.visualState
      heading(if state == NormalState: "Image" else: stateLabel(state) & " image")
      let image = current.stateImage(state)
      y += sk.text(editor, if image.len > 0: image else: "No image", x, y, width, "Small",
        if image.len > 0: Foreground else: Muted) + 8
      let half = floor((width - Gap) / 2)
      if sk.chip(editor, "browse", rect(x, y, half, ChipHeight), "Browse...", enabled = not editor.busy or editor.busyKind != BrowseJob):
        editor.importTarget = ImportTarget(menu: model.menu, key: model.key, state: state)
        editor.request(BrowseJob)
      if sk.chip(editor, "clearImage", rect(x + half + Gap, y, half, ChipHeight), "Remove image", enabled = image.len > 0):
        editor.applyEdit: editor.model.clearImage(state)
      y += ChipHeight + 8
      let imported = sk.textField(window, editor, "importPath", "importPath",
        rect(x, y, width - 70, FieldHeight), editor.importPath, placeholder = "/path/to/image.png")
      editor.importPath = imported.text
      let importNow = sk.chip(editor, "import", rect(x + width - 62, y, 62, FieldHeight), "Import",
        enabled = editor.importPath.strip().len > 0)
      if importNow or (imported.submitted and editor.importPath.strip().len > 0):
        editor.requestImport(editor.importPath)
      y += FieldHeight + 10
      if sk.checkbox(editor, "showTitle", x, y, width, "Show title on key", current.showsTitle()):
        editor.applyEdit: editor.model.setShowTitle(not editor.model.selected().showsTitle())
      y += 34
  if slotProblem:
    y += sk.text(editor, model.problem(), x, y, width, "Small", Danger) + 8
  editor.contentHeight = max(0'f32, y + editor.scroll - top - (height - top - 35))

proc busyText(kind: JobKind): string =
  ## Describe the background request currently running.
  case kind
  of LoadJob: "Loading configuration..."
  of ApplyJob: "Preparing and applying..."
  of PreviewJob: "Preparing preview..."
  of ImportJob: "Importing image..."
  of BrowseJob: "Choosing image..."

proc drawFooter(sk: Silky, editor: ButtonEditor, x, width, height: float32) =
  ## Draw Save & Apply, discard, conflicts, and the current outcome.
  let model = editor.model
  var top = height - 64
  if model.conflict == StaleRevision:
    let bannerTop = top - 50
    sk.drawRect(vec2(x, bannerTop), vec2(width, 42), rgbx(70, 46, 40, 255))
    let buttonsWidth = 2 * 130'f32 + Gap
    discard sk.label("The live configuration changed after this draft started. Keeping the draft replaces those changes when saved.",
      x + 12, bannerTop + 6, width - buttonsWidth - 24, "Small", Foreground)
    if sk.chip(editor, "keepDraft", rect(x + width - buttonsWidth - 6, bannerTop + 6, 130, ChipHeight),
        "Keep my draft", enabled = not editor.busy):
      editor.model.rebaseDraft()
    if sk.chip(editor, "discardDraft", rect(x + width - 136, bannerTop + 6, 130, ChipHeight),
        "Use live version", enabled = not editor.busy, danger = true):
      editor.model.discardDraft()
  let applying = editor.busy and editor.busyKind == ApplyJob or ApplyJob in editor.queued
  if sk.chip(editor, "save", rect(x, top, 140, 36), "Save & Apply",
      active = model.canApply(), enabled = model.canApply() and not applying):
    editor.request(ApplyJob)
  if sk.chip(editor, "revert", rect(x + 148, top, 130, 36), "Discard changes",
      enabled = model.dirty and not applying, danger = true):
    editor.model.discardDraft()
  let
    messageX = x + 290
    messageWidth = max(40'f32, width - 290)
  var message = ""
  var color = Muted
  if editor.busy:
    message = busyText(editor.busyKind)
  elif model.error.len > 0:
    message = model.error
    color = Danger
  elif model.validation.len > 0 and model.dirty:
    message = model.validation
    color = Danger
  elif model.notice.len > 0:
    message = model.notice & (if model.dirty: " Unsaved changes are kept as a draft." else: "")
    color = Accent
  elif not model.loaded:
    message = "Waiting for the daemon configuration."
  elif model.dirty:
    message = "Unsaved changes. The draft is saved automatically."
  else:
    message = "No unsaved changes."
  sk.pushClipRect(rect(messageX, top - 4, messageWidth, 60))
  discard sk.text(editor, message, messageX, top, messageWidth, "Small", color)
  sk.popClipRect()

proc drawEditor*(sk: Silky, window: Window, editor: ButtonEditor, left, boardWidth,
    detailsX, height: float32) =
  ## Draw the editor's board, details, and footer; the caller draws the sidebar.
  editor.opened = true
  discard sk.label("Button editor", left, 30, boardWidth, "Title")
  discard sk.text(editor, editor.liveSummary(), left, 77, boardWidth, "Small", Muted)
  discard sk.label("SELECTED KEY", detailsX, 114, DetailWidth - 36, "Small", Muted)
  if not editor.model.loaded:
    discard sk.label(if editor.model.error.len > 0: editor.model.error else: "Loading configuration...",
      left, 160, boardWidth, "Body", if editor.model.error.len > 0: Danger else: Muted)
    if editor.model.error.len > 0 and not editor.busy:
      if sk.chip(editor, "retry", rect(left, 200, 120, ChipHeight), "Retry"):
        editor.model.error = ""
        editor.request(LoadJob)
    return
  sk.drawToolbar(window, editor, left, boardWidth)
  sk.drawGrid(editor, left, 206, boardWidth)
  if sk.mousePos.x >= sk.size.x - DetailWidth:
    editor.scroll = clamp(editor.scroll + window.scrollDelta.y * 30, 0'f32, editor.contentHeight)
  sk.drawDetails(window, editor, detailsX, height)
  sk.drawFooter(editor, left, boardWidth, height)

proc handleReply(editor: ButtonEditor, reply: ConfigReply) =
  ## Fold a finished background job into the model; failures never discard the draft.
  editor.busy = false
  editor.replies.add(reply.kind)
  let model = addr editor.model
  case reply.kind
  of LoadJob:
    if not reply.ok:
      if model.loaded: model[].setError(reply.error, reply.field)
      else: model[].error = reply.error
      return
    let payload = parseJson(reply.payload)
    model[].loadLive(payload["envelope"])
    if not editor.recovered:
      editor.recovered = true
      if payload.hasKey("draft"):
        try:
          model[].recoverDraft(payload["draft"])
        except ValueError as error:
          model[].setError("Draft could not be recovered: " & error.msg)
        editor.saver.markDraftSaved(model[])
      elif payload.hasKey("draftError"):
        model[].setError("Draft could not be read: " & payload["draftError"].getStr())
    if payload{"startupError"}.getStr().len > 0 and model.error.len == 0:
      model[].notice = "Daemon started from a fallback: " & payload["startupError"].getStr()
    editor.statusRevision = model.liveRevision
  of ApplyJob:
    if not reply.ok:
      model[].applyFailed(reply.error, reply.code, reply.field)
      if reply.code == StaleCode: editor.request(LoadJob)
      return
    let
      payload = parseJson(reply.payload)
      revision = payload["record"]{"revision"}.getStr()
    model[].applySucceeded(revision)
    if payload.hasKey("envelope"):
      model[].loadLive(payload["envelope"])
    model[].notice = "Applied revision " & shortRevision(revision) & "."
    editor.statusRevision = model.liveRevision
    inc editor.applied
    editor.saver.markDraftStale()
    editor.saver.autosaveDraft(model[], nowMs(), force = true)
  of PreviewJob:
    if not reply.ok:
      if reply.code == "busy":
        editor.previewRequestedEdits = -1
        editor.previewRetryMs = nowMs() + PreviewBusyRetryMs
      else:
        editor.previewError = "Preview failed: " & reply.error
      return
    editor.previewError = ""
    editor.manifest = parseJson(reply.payload)
    editor.previewEdits = editor.previewRequestedEdits
    editor.pageKey = "\0refresh"
  of ImportJob, BrowseJob:
    if not reply.ok:
      model[].setError(reply.error)
      return
    let payload = parseJson(reply.payload)
    if payload{"cancelled"}.getBool(): return
    let
      previousMenu = model.menu
      previousDevice = model.device
      previousKey = model.key
      previousState = model.visualState
      target = editor.importTarget
    try:
      model[].selectMenu(target.menu)
      model[].selectDevice(DeckDevice)
      model[].selectKey(target.key)
      model[].setImage(payload["path"].getStr(), target.state)
      editor.importPath = ""
    except ValueError as error:
      model[].setError("Imported image could not be assigned: " & error.msg)
    model[].selectMenu(if model.draft.findMenu(previousMenu).isNil: target.menu else: previousMenu)
    model[].selectDevice(previousDevice)
    model[].selectKey(previousKey)
    if previousState in model[].selected().entryStates():
      model[].selectVisualState(previousState)

proc schedule(editor: ButtonEditor, view: PreviewView) =
  ## Start the highest-priority queued job, then a debounced preview while the draft Deck grid is visible.
  let statusRevision = editor.status{"revision"}.getStr()
  if statusRevision.len == 0:
    editor.statusRevision = ""
  elif statusRevision != editor.statusRevision and statusRevision != editor.model.liveRevision and
      (editor.opened or view == LivePreview):
    editor.statusRevision = statusRevision
    if not editor.model.loaded: editor.model.error = ""
    editor.queued.incl(LoadJob)
  if editor.busy: return
  for kind in [LoadJob, ApplyJob, ImportJob, BrowseJob]:
    if kind notin editor.queued: continue
    if kind != LoadJob and not editor.model.loaded: continue
    if kind == ApplyJob and not editor.model.canApply():
      editor.queued.excl(kind)
      continue
    let payload =
      case kind
      of ApplyJob: $editor.model.draftEnvelope()
      of ImportJob: editor.queuedImport
      else: ""
    if editor.submit(kind, payload):
      editor.queued.excl(kind)
      if kind == ApplyJob: editor.model.applySubmitted()
      return
  let model = editor.model
  if view != DraftPreview or not model.loaded or model.device != DeckDevice or
      model.validation.len > 0 or nowMs() < editor.previewRetryMs:
    return
  let wanted = editor.previewRequestedEdits != model.edits or
    editor.manifest.isNil and editor.previewError.len == 0
  if wanted and (editor.manifest.isNil or nowMs() - editor.saver.changedMs >= PreviewDebounceMs):
    let edits = model.edits
    if editor.submit(PreviewJob, $model.draft):
      editor.previewRequestedEdits = edits

proc updateEditor*(sk: Silky, editor: ButtonEditor, status: JsonNode, obsStatus: JsonNode,
    controlStatus: JsonNode, view: PreviewView) =
  ## Process finished jobs, autosave, schedule work, and refresh the visible view's preview pixels.
  editor.status = status
  editor.obsStatus = obsStatus
  editor.controlStatus = controlStatus
  if view == DraftPreview and not editor.model.loaded and not editor.busy and
      LoadJob notin editor.queued and editor.model.error.len == 0:
    editor.request(LoadJob)
  while true:
    let (available, reply) = replies.tryRecv()
    if not available: break
    editor.handleReply(reply)
  editor.saver.autosaveDraft(editor.model, nowMs())
  editor.schedule(view)
  editor.publishPreviewPage(view)
  if view != NoPreview:
    sk.syncPreviewSlots(editor)
  sk.flushGlyphs(editor)

proc flushDraft*(editor: ButtonEditor) =
  ## Write pending draft edits immediately, including after a failed write, for clean viewer shutdown.
  editor.saver.autosaveDraft(editor.model, nowMs(), force = true)

import
  std/[algorithm, json, monotimes, os, strutils, tables],
  ./[bindings, controls_state, obs_state, stream_deck, stream_deck_page]

type
  PlayerClock* = proc (): int64
  PlayerOptions* = object
    clock*: PlayerClock
    idlePollMs*: int
    busyRetryMs*: int
    busyLimitMs*: int
    brightness*: int
    onDiagnostic*: proc (message: string)
    readIndicators*: proc (): JsonNode
  ImageSource = object
    path: string
    loaded: bool
    failure: string
  KeyVisual = object
    normal: seq[int]
    ends: seq[int]
    pressed: int
  KeyPlan = object
    # visuals[0] is the base; later visuals are status variants named by states.
    visuals: seq[KeyVisual]
    states: seq[string]
    actionKind: string
    operation: string
    diagnostic: string
  DeckPage = object
    generation: int64
    menu: string
    sources: seq[ImageSource]
    images: seq[string]
    sourceIndex: Table[string, int]
    keys: array[StreamDeckKeyCount, KeyPlan]
    loadCursor: int
    loadedBytes: int
    diagnostics: seq[string]
  Player = object
    deck: StreamDeck
    onKey: proc (event: StreamDeckKeyEvent)
    options: PlayerOptions
    held: StreamDeckKeys
    active: DeckPage
    hasActive: bool
    pending: DeckPage
    hasPending: bool
    anchorMs: int64
    shown: array[StreamDeckKeyCount, int]
    selected: array[StreamDeckKeyCount, int]
    shownVisual: array[StreamDeckKeyCount, int]
    indicators: JsonNode
    shownHeld: StreamDeckKeys
    uploaded: array[StreamDeckKeyCount, bool]
    uploadedCount: int
    ready: bool
    roundRobin: int

const
  MaxPreparedJpegBytes* = 64 * 1024
  MaxFramesPerKey* = 900
  MaxFrameDurationMs* = 60_000
  MaxPageImageBytes* = 128 * 1024 * 1024
  DefaultIdlePollMs = 20
  DefaultBusyRetryMs = 2
  DefaultBusyLimitMs = 2000
  MaxReportsPerPoll = 16
  BlankSource = 0
  MissingSource = 1
  BuiltinPrefix = "builtin:"
  JpegStart = "\xff\xd8"
  NoImage = -1

proc monotonicMs*(): int64 =
  ## Return a monotonic millisecond clock reading for animation scheduling.
  getMonoTime().ticks div 1_000_000

proc writeDiagnostic(message: string) =
  ## Report a per-key media problem without interrupting the session.
  stderr.writeLine("Stream Deck: " & message)

proc defaultPlayerOptions*(): PlayerOptions =
  ## Return the production clock, polling bounds, diagnostic sink, and status indicator reader.
  PlayerOptions(clock: monotonicMs, idlePollMs: DefaultIdlePollMs,
    busyRetryMs: DefaultBusyRetryMs, busyLimitMs: DefaultBusyLimitMs,
    brightness: StreamDeckDemoBrightness, onDiagnostic: writeDiagnostic,
    readIndicators: readIndicators)

proc builtinDeckPage*(generation: int64 = 1, menu = "root"): JsonNode =
  ## Build a page that shows the embedded numbered images on every key.
  var keys = newJObject()
  for number in 1..StreamDeckKeyCount:
    keys[$number] = %*{"builtinNumber": number}
  result = %*{"generation": generation, "menu": menu, "keys": keys}

proc builtinPageReader*(): proc (previousGeneration: int64): JsonNode =
  ## Return a page reader that supplies the numbered page once per session.
  result = proc (previousGeneration: int64): JsonNode =
    ## Supply generation one until the player already holds it.
    if previousGeneration != 1:
      result = builtinDeckPage()

proc frameEnds*(durations: openArray[int]): seq[int] =
  ## Convert frame durations into cumulative end offsets in milliseconds.
  if durations.len == 0:
    raise newException(ValueError, "An animation needs at least one frame.")
  var total = 0
  for duration in durations:
    if duration notin 1..MaxFrameDurationMs:
      raise newException(ValueError, "Frame durations must be between 1 and " &
        $MaxFrameDurationMs & " ms.")
    total += duration
    result.add(total)

proc framePhase(ends: openArray[int], elapsedMs: int64): int64 =
  ## Return the position inside the looping animation for an elapsed time.
  max(elapsedMs, 0) mod ends[^1].int64

proc frameIndexAt*(ends: openArray[int], elapsedMs: int64): int =
  ## Select the frame due at an elapsed time, skipping any frames already missed.
  if ends.len > 1:
    result = upperBound(ends, framePhase(ends, elapsedMs).int)

proc msUntilNextFrame*(ends: openArray[int], elapsedMs: int64): int64 =
  ## Return the time until the displayed frame changes, or high(int64) when static.
  result = high(int64)
  if ends.len > 1:
    let phase = framePhase(ends, elapsedMs)
    result = ends[upperBound(ends, phase.int)].int64 - phase

proc addEmbedded(page: var DeckPage, name, jpeg: string): int =
  ## Register an embedded image once per page and return its image index.
  result = page.sourceIndex.getOrDefault(name, NoImage)
  if result == NoImage:
    result = page.sources.len
    page.sources.add(ImageSource(path: name, loaded: true))
    page.images.add(jpeg)
    page.sourceIndex[name] = result

proc addFile(page: var DeckPage, previous: DeckPage, path: string): int =
  ## Register a prepared JPEG path, reusing bytes already loaded by the previous page.
  result = page.sourceIndex.getOrDefault(path, NoImage)
  if result == NoImage:
    result = page.sources.len
    var source = ImageSource(path: path)
    var image = ""
    let index = previous.sourceIndex.getOrDefault(path, NoImage)
    if index != NoImage and previous.sources[index].loaded and
        previous.sources[index].failure.len == 0:
      image = previous.images[index]
      source.loaded = true
      page.loadedBytes += image.len
    page.sources.add(source)
    page.images.add(image)
    page.sourceIndex[path] = result

proc staticVisual(source: int): KeyVisual =
  ## Show one image regardless of time or key state.
  KeyVisual(normal: @[source], ends: @[1], pressed: source)

proc staticPlan(source: int): KeyPlan =
  ## Show one image regardless of time, key state, or OBS status.
  KeyPlan(visuals: @[staticVisual(source)], states: @[""])

proc framePath(node: JsonNode, field: string): string =
  ## Read an absolute prepared JPEG path or raise ValueError naming the field.
  if node.isNil or node.kind != JString or not node.getStr().isAbsolute():
    raise newException(ValueError, field & " must be an absolute JPEG path")
  result = node.getStr()

proc frameVisual(page: var DeckPage, previous: DeckPage, entry: JsonNode,
    prefix: string): KeyVisual =
  ## Convert a {normal, pressed} object into image indices, raising ValueError when malformed.
  if entry.kind != JObject:
    raise newException(ValueError, prefix & "entry must be an object")
  let frames = entry{"normal"}
  if frames.isNil or frames.kind != JArray or frames.len == 0:
    raise newException(ValueError, prefix & "normal must be a nonempty frame list")
  if frames.len > MaxFramesPerKey:
    raise newException(ValueError, prefix & "normal has more than " & $MaxFramesPerKey & " frames")
  var durations: seq[int]
  for frame in frames:
    if frame.kind != JObject:
      raise newException(ValueError, prefix & "normal frames must be objects")
    let duration = frame{"durationMs"}
    if duration.isNil or duration.kind != JInt:
      raise newException(ValueError, prefix & "durationMs must be an integer")
    durations.add(duration.getInt())
    result.normal.add(page.addFile(previous, framePath(frame{"path"}, prefix & "path")))
  result.ends = if durations.len == 1 and durations[0] == 0: @[1]
    else: frameEnds(durations)
  result.pressed =
    if entry.hasKey("pressed"): page.addFile(previous, framePath(entry["pressed"], prefix & "pressed"))
    else: result.normal[0]

proc entryPlan(page: var DeckPage, previous: DeckPage, entry: JsonNode): KeyPlan =
  ## Convert one manifest key entry and its status variants into image
  ## indices, raising ValueError when malformed.
  if entry.kind != JObject:
    raise newException(ValueError, "entry must be an object")
  if entry.hasKey("builtinNumber"):
    let number = entry["builtinNumber"]
    if number.kind != JInt or number.getInt() notin 1..StreamDeckKeyCount:
      raise newException(ValueError, "builtinNumber must be between 1 and 15")
    let n = number.getInt()
    result.visuals.add(KeyVisual(
      normal: @[page.addEmbedded(BuiltinPrefix & $n, builtinNormalImage(n))],
      ends: @[1],
      pressed: page.addEmbedded(BuiltinPrefix & $n & ":pressed", builtinPressedImage(n))))
  else:
    result.visuals.add(page.frameVisual(previous, entry, ""))
  result.states.add("")
  if entry.hasKey("obsOperation"):
    if entry["obsOperation"].kind != JString:
      raise newException(ValueError, "obsOperation must be a string")
    result.operation = entry["obsOperation"].getStr()
    result.actionKind = "obs"
  elif entry.hasKey("controlAction"):
    let control = entry["controlAction"]
    if control.kind != JString or not control.getStr().isControlAction():
      raise newException(ValueError, "controlAction must name a control action")
    result.actionKind = control.getStr()
  if entry.hasKey("states"):
    let states = entry["states"]
    if states.kind != JObject:
      raise newException(ValueError, "states must be an object")
    for state, variant in states:
      if state notin VisualStates:
        raise newException(ValueError, "unknown visual state " & state.escape())
      result.visuals.add(page.frameVisual(previous, variant, "states." & state & "."))
      result.states.add(state)

proc parseDeckPage(node: JsonNode, previous: DeckPage): DeckPage =
  ## Parse a runtime page, isolating malformed key entries behind the missing image.
  if node.kind != JObject or node{"generation"}.isNil or node["generation"].kind != JInt or
      node{"menu"}.isNil or node["menu"].kind != JString or
      node{"keys"}.isNil or node["keys"].kind != JObject:
    raise newException(ValueError,
      "Stream Deck pages need an integer generation, a menu string and a keys object.")
  result.generation = node["generation"].getBiggestInt().int64
  result.menu = node["menu"].getStr()
  doAssert result.addEmbedded("blank", blankKeyImage()) == BlankSource
  doAssert result.addEmbedded("missing", missingKeyImage()) == MissingSource
  for name, _ in node["keys"]:
    let valid = name.len in 1..2 and name.allCharsInSet(Digits) and
      name.parseInt() in 1..StreamDeckKeyCount and name[0] != '0'
    if not valid:
      result.diagnostics.add("menu " & result.menu & " has unknown key " & name.escape())
  for index in 0..<StreamDeckKeyCount:
    let entry = node["keys"]{$(index + 1)}
    if entry.isNil:
      result.keys[index] = staticPlan(BlankSource)
    else:
      try:
        result.keys[index] = result.entryPlan(previous, entry)
      except ValueError as error:
        result.keys[index] = KeyPlan(diagnostic: error.msg)

proc readPreparedJpeg(path: string, remainingBytes: int): string =
  ## Read a prepared key JPEG, raising when it is absent, oversized or not a JPEG.
  let file = open(path)
  defer: file.close()
  result = newString(MaxPreparedJpegBytes + 1)
  result.setLen(file.readBuffer(addr result[0], result.len))
  if result.len == 0 or result.len > MaxPreparedJpegBytes:
    raise newException(ValueError, "prepared image " & path & " must have 1 to " &
      $MaxPreparedJpegBytes & " bytes")
  if result.len > remainingBytes:
    raise newException(ValueError, "prepared images for this page exceed " &
      $MaxPageImageBytes & " bytes")
  if not result.startsWith(JpegStart):
    raise newException(ValueError, "prepared image " & path & " is not a JPEG")

proc loadSource(page: var DeckPage, index: int) =
  ## Read one prepared JPEG, recording a problem for its keys instead of raising.
  template source: untyped = page.sources[index]
  source.loaded = true
  # Prepared media is shared with other processes; a vanished, unreadable or
  # corrupt file must only replace its own keys with the missing image.
  try:
    page.images[index] = readPreparedJpeg(source.path, MaxPageImageBytes - page.loadedBytes)
    page.loadedBytes += page.images[index].len
  except CatchableError as error:
    source.failure = error.msg

proc loadNextSource(page: var DeckPage) =
  ## Load at most one pending file so input polling continues between reads.
  while page.loadCursor < page.sources.len and page.sources[page.loadCursor].loaded:
    inc page.loadCursor
  if page.loadCursor < page.sources.len:
    page.loadSource(page.loadCursor)
    inc page.loadCursor

proc fullyLoaded(page: DeckPage): bool =
  ## Report whether every image source of the page has been read or rejected.
  result = true
  for index in page.loadCursor..<page.sources.len:
    result = result and page.sources[index].loaded

proc finishLoading(page: var DeckPage) =
  ## Replace malformed keys, and each visual whose sources failed, with the missing image.
  for index in 0..<StreamDeckKeyCount:
    template plan: untyped = page.keys[index]
    let prefix = "menu " & page.menu & " key " & $(index + 1)
    if plan.diagnostic.len > 0:
      page.diagnostics.add(prefix & ": " & plan.diagnostic & "; showing the missing image")
      plan = staticPlan(MissingSource)
    for visual in 0..plan.visuals.high:
      var failure = ""
      for source in plan.visuals[visual].normal & @[plan.visuals[visual].pressed]:
        if failure.len == 0:
          failure = page.sources[source].failure
      if failure.len > 0:
        let state = if visual == 0: "" else: " state " & plan.states[visual]
        page.diagnostics.add(prefix & state & ": " & failure & "; showing the missing image")
        plan.visuals[visual] = staticVisual(MissingSource)

proc pollInput(player: var Player, timeoutMs: int) =
  ## Deliver key edges from one bounded wait and any reports already queued.
  var
    events = player.deck.pollKeys(timeoutMs)
    reads = 1
  while true:
    for event in events:
      player.held[event.keyIndex] = event.pressed
      player.onKey(event)
    if events.len == 0 or reads >= MaxReportsPerPoll:
      break
    events = player.deck.pollKeys(0)
    inc reads

proc newestGeneration(player: Player): int64 =
  ## Return the newest page generation the player has received.
  if player.hasPending: player.pending.generation
  elif player.hasActive: player.active.generation
  else: 0

proc receivePage(player: var Player, node: JsonNode) =
  ## Stage a newer page; the previous page sends nothing further.
  player.pending = parseDeckPage(node, player.active)
  player.hasPending = true
  player.ready = false

proc visualIndex(plan: KeyPlan, indicators: JsonNode): int =
  ## Return the visual matching the indicators, falling back to the base.
  if plan.actionKind.len > 0:
    let state = actionVisualState(plan.actionKind, plan.operation, indicators)
    if state.len > 0:
      result = max(0, plan.states.find(state))

proc selectVisuals(player: var Player) =
  ## Choose each active key's visual from the newest status snapshot.
  for key in 0..<StreamDeckKeyCount:
    player.selected[key] = player.active.keys[key].visualIndex(player.indicators)

proc activatePending(player: var Player) =
  ## Make the loaded page current and restart its animation clock.
  player.pending.finishLoading()
  player.active = move(player.pending)
  player.pending = DeckPage()
  player.hasPending = false
  player.hasActive = true
  player.anchorMs = player.options.clock()
  player.ready = false
  player.uploadedCount = 0
  player.roundRobin = 0
  for index in 0..<StreamDeckKeyCount:
    player.shown[index] = NoImage
    player.uploaded[index] = false
  for message in player.active.diagnostics:
    player.options.onDiagnostic(message)
  player.selectVisuals()

proc desiredImage(player: Player, key: int, nowMs: int64): int =
  ## Select the pressed image while held, otherwise the frame due now.
  template plan: untyped = player.active.keys[key].visuals[player.selected[key]]
  if player.held[key]:
    result = plan.pressed
  else:
    result = plan.normal[frameIndexAt(plan.ends, nowMs - player.anchorMs)]

proc nextUpload(player: var Player, nowMs: int64): int =
  ## Choose the next stale key: unstaged keys, then press or OBS state changes,
  ## then round robin.
  result = NoImage
  for key in 0..<StreamDeckKeyCount:
    if result == NoImage and not player.uploaded[key]:
      result = key
  for key in 0..<StreamDeckKeyCount:
    let changed = player.held[key] != player.shownHeld[key] or
      player.selected[key] != player.shownVisual[key]
    if result == NoImage and changed and
        player.shown[key] != player.desiredImage(key, nowMs):
      result = key
  for offset in 0..<StreamDeckKeyCount:
    let key = (player.roundRobin + offset) mod StreamDeckKeyCount
    if result == NoImage and player.shown[key] != player.desiredImage(key, nowMs):
      result = key
      player.roundRobin = (key + 1) mod StreamDeckKeyCount

proc idleWait(player: Player, nowMs: int64): int =
  ## Bound the input wait by the earliest animation frame change.
  result = player.options.idlePollMs
  for key in 0..<StreamDeckKeyCount:
    if not player.held[key]:
      let wait = msUntilNextFrame(
        player.active.keys[key].visuals[player.selected[key]].ends, nowMs - player.anchorMs)
      result = min(result.int64, wait).int
  result = max(result, 0)

proc sendReport(player: var Player, report: string) =
  ## Retry a deferred report itself, polling input, until accepted or the busy limit passes.
  var deferredSince = NoImage.int64
  while player.deck.trySendReport(report) == ReportDeferred:
    let nowMs = player.options.clock()
    if deferredSince < 0:
      deferredSince = nowMs
    elif nowMs - deferredSince >= player.options.busyLimitMs:
      raise newException(IOError, "Stream Deck output stayed busy for " &
        $player.options.busyLimitMs & " ms.")
    player.pollInput(player.options.busyRetryMs)

proc uploadImage(player: var Player, key, image: int) =
  ## Send one complete image, polling input between its reports.
  let reports = encodeKeyImageReports(key, player.active.images[image])
  for report in reports:
    player.sendReport(report)
    player.pollInput(0)
  player.shown[key] = image
  player.shownHeld[key] = player.held[key]
  player.shownVisual[key] = player.selected[key]
  if not player.uploaded[key]:
    player.uploaded[key] = true
    inc player.uploadedCount

proc runPlayer(player: var Player, shouldStop: proc (): bool,
    readPage: proc (previousGeneration: int64): JsonNode, onReady: proc ()) =
  ## Stage pages, animate the active page, and deliver input until stopped.
  player.deck.setBrightness(player.options.brightness)
  let initial = readPage(0)
  if initial.isNil:
    raise newException(ValueError, "The Stream Deck page reader returned no initial page.")
  player.receivePage(initial)
  while not shouldStop():
    player.pollInput(0)
    let page = readPage(player.newestGeneration())
    if not page.isNil:
      player.receivePage(page)
    player.indicators = player.options.readIndicators()
    if player.hasPending:
      if player.pending.fullyLoaded():
        player.activatePending()
      else:
        player.pending.loadNextSource()
    else:
      player.selectVisuals()
      let
        nowMs = player.options.clock()
        key = player.nextUpload(nowMs)
      if key == NoImage:
        player.pollInput(player.idleWait(nowMs))
      else:
        player.uploadImage(key, player.desiredImage(key, nowMs))
        if not player.ready and player.uploadedCount == StreamDeckKeyCount:
          player.ready = true
          if not onReady.isNil:
            onReady()
  player.deck.showLogo()

proc runConfiguredSession*(deck: StreamDeck, shouldStop: proc (): bool,
    onKey: proc (event: StreamDeckKeyEvent),
    readPage: proc (previousGeneration: int64): JsonNode,
    onReady: proc () = nil, options = defaultPlayerOptions()) =
  ## Own the device until stopped: show the newest page from readPage, animate it,
  ## and report key edges. readPage returns nil when unchanged or
  ## {generation, menu, keys}; nil readPage uses the builtin numbered page.
  ## onReady runs after every key of a new generation is on the device. Stopping
  ## restores the logo; the session is always closed, and a close failure after
  ## another error is logged so the original error propagates. Each loop reads
  ## one options.readIndicators {obs, controls} snapshot to pick status variants preloaded
  ## with the page, without a new generation or animation clock reset.
  if options.clock.isNil or options.onDiagnostic.isNil or options.readIndicators.isNil or
      options.busyLimitMs <= 0 or
      options.idlePollMs < 0 or options.busyRetryMs < 0:
    raise newException(ValueError, "Stream Deck player options are incomplete.")
  var player = Player(deck: deck, onKey: onKey, options: options)
  let reader = if readPage.isNil: builtinPageReader() else: readPage
  try:
    player.runPlayer(shouldStop, reader, onReady)
  except CatchableError:
    try:
      deck.close()
    except CatchableError as closeError:
      stderr.writeLine("Closing Stream Deck failed: " & closeError.msg)
    raise
  deck.close()

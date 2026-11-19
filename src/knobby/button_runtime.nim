import
  std/[algorithm, json, locks, os, strutils, tables, times],
  ./[bindings, button_config, ipc, obs_state, overlay_state]

type
  ButtonServices* = object
    prepare*: proc (config: JsonNode): JsonNode {.gcsafe.}
    importAsset*: proc (source: string): string {.gcsafe.}
    maintain*: proc () {.gcsafe.}
  OperationKind = enum
    ApplyOperation = "apply", PreviewOperation = "preview", ImportOperation = "importAsset"
  OperationRecord = object
    id, kind, status, error, code, field, revision, manifestPath, path: string
    startedMs, finishedMs: int64
  OperationFailure = object of CatchableError
    code, field: string
  ConfigJob = object
    kind: OperationKind
    id, baseRevision, payload: string
  Transition = object
    devices: set[ButtonDevice]
    previous: array[ButtonDevice, string]
  CapturedAction = object
    sequence: int64
    device: ButtonDevice
    key: int
    menu, revision, title: string
    action: ConfiguredAction
  DeviceInput = object
    held, quarantined: array[DeckKeyCount, bool]
  ActiveConfig = object
    buttons: ButtonSet
    configText, revision, source, manifestPath: string
    pages: Table[string, string]
  RuntimeState = object
    initialized: bool
    paths: ButtonPaths
    session, startupError: string
    active: ActiveConfig
    diskText: string
    diskExists, diskMatchesActive: bool
    menus: array[ButtonDevice, string]
    history: seq[Transition]
    input: array[ButtonDevice, DeviceInput]
    deckGeneration, deckReadGeneration: int64
    deckReady: bool
    actions: seq[CapturedAction]
    actionSequence: int64
    job: ConfigJob
    hasJob, busy, workerRunning, workerStopping: bool
    current: OperationRecord
    hasCurrent: bool
    recent: seq[OperationRecord]
    operationSequence: int

const
  MaxButtonActions* = 256
  MaxNavigationHistory* = 32
  MaxRecentOperations* = 8
  MaxRetainedManifests* = 8
  ManifestVersion = 1
  RequestPrefix = "config."
  QueuedStatus = "queued"
  RunningStatus = "running"
  SucceededStatus = "succeeded"
  FailedStatus = "failed"
  NavigationLimitMessage = "Menu navigation is limited to " & $MaxNavigationHistory &
    " levels; press Back or Home before opening another menu."
  CanonicalSource = "canonical"
  LastAppliedSource = "lastApplied"
  DefaultsSource = "defaults"

var
  routerLock: Lock
  jobReady: Cond
  state: RuntimeState
  services: ButtonServices
  workerThread: Thread[void]

initLock(routerLock)
initCond(jobReady)

template withState(body: untyped) =
  ## Run a block holding the router lock, which guards all shared runtime state.
  {.cast(gcsafe).}:
    withLock routerLock:
      body

proc ownedCopy[T](value: T): T =
  ## Return an independent copy so no string, sequence, or ref is shared between threads.
  deepCopy(result, value)

proc epochMs(): int64 =
  ## Return wall-clock milliseconds for operation timestamps shown to clients.
  int64(epochTime() * 1000)

proc fail(code, message: string, field = "") =
  ## Abort the current operation with a client-visible code and optional field.
  var error = newException(OperationFailure, message)
  error.code = code
  error.field = field
  raise error

template step(code: string, body: untyped) =
  ## Convert any failure of one transaction step into a coded operation failure.
  try:
    body
  except OperationFailure:
    raise
  except ButtonConfigError as error:
    fail(code, error.msg, error.field)
  except CatchableError as error:
    fail(code, error.msg)

proc builtinButtonManifest*(config: JsonNode): JsonNode =
  ## Describe compiled numbered images, rejecting any slot that needs real media preparation.
  let canonical = canonicalButtonConfig(config)
  result = %*{"version": ManifestVersion, "menus": {}}
  for position, menu in canonical["menus"].elems:
    var keys = newJObject()
    for key in 1..DeckKeyCount:
      var number = 0
      for entry in menu["deck"]:
        let visual = entry{"visual"}
        if entry["key"].getInt() == key and not visual.isNil and
            visual.hasKey("builtinNumber") and not visual["showTitle"].getBool() and
            not visual.hasKey("states"):
          number = visual["builtinNumber"].getInt()
      if number == 0:
        raise newException(ValueError, "Media preparation is unavailable for menus[" &
          $position & "] deck key " & $key & "; only built-in numbered keys work without it.")
      keys[$key] = %*{"builtinNumber": number}
    result["menus"][menu["id"].getStr()] = keys

proc defaultButtonServices*(): ButtonServices =
  ## Support built-in numbered pages only, refusing media work instead of faking success.
  ButtonServices(
    prepare: proc (config: JsonNode): JsonNode {.gcsafe.} =
      ## Prepare a page from compiled numbered images.
      builtinButtonManifest(config),
    importAsset: proc (source: string): string {.gcsafe.} =
      ## Refuse imports when no media service is installed.
      raise newException(IOError, "Asset import is unavailable without the media service."))

proc manifestPages(buttons: ButtonSet, manifest: JsonNode): Table[string, string] =
  ## Split a prepared manifest into per-menu page JSON, requiring every configured menu.
  if manifest.isNil or manifest.kind != JObject or manifest{"menus"}.isNil or
      manifest["menus"].kind != JObject:
    raise newException(ValueError, "Prepared manifest has no menus object.")
  for menu in buttons.menus:
    let page = manifest["menus"]{menu.id}
    if page.isNil or page.kind != JObject:
      raise newException(ValueError, "Prepared manifest is missing menu " & menu.id & ".")
    result[menu.id] = $page

proc writeManifest(paths: ButtonPaths, revision: string, manifest: JsonNode,
    keep: openArray[string]): string =
  ## Store a revision-addressed manifest and prune older ones, keeping active and recent files.
  result = paths.manifestDirectory() / (revision & ".json")
  writeFileAtomic(result, $manifest)
  var files: seq[(Time, string)]
  for kind, path in walkDir(paths.manifestDirectory()):
    if kind == pcFile and path.endsWith(".json") and path != result and path notin keep:
      files.add((getLastModificationTime(path), path))
  files.sort(proc (a, b: (Time, string)): int = cmp(b[0], a[0]))
  for index in max(0, MaxRetainedManifests - 1)..<files.len:
    removeFile(files[index][1])

proc menuButtons(buttons: ButtonSet, id: string): ConfiguredMenu =
  ## Find a configured menu, falling back to the root for robustness after swaps.
  for menu in buttons.menus:
    if menu.id == id:
      return menu
  for menu in buttons.menus:
    if menu.id == buttons.root:
      return menu
  raise newException(ValueError, "Configuration has no root menu.")

proc quarantineHeld(input: var DeviceInput) =
  ## Ignore held keys until their release, because their binding or page changed.
  for index in 0..<DeckKeyCount:
    if input.held[index]:
      input.quarantined[index] = true

proc bumpDeckPage(current: var RuntimeState) =
  ## Publish a new Deck page; input waits until the player reports it uploaded.
  inc current.deckGeneration
  current.deckReady = false

proc setMenu(current: var RuntimeState, device: ButtonDevice, id: string) =
  ## Move one device to a menu, quarantining its held keys.
  if current.menus[device] != id:
    current.menus[device] = id
    quarantineHeld(current.input[device])
    if device == DeckDevice:
      bumpDeckPage(current)

proc targetDevices(target: ButtonTarget): set[ButtonDevice] =
  ## Map a menu action target to the devices it moves.
  case target
  of TargetMixer: {MixerDevice}
  of TargetDeck: {DeckDevice}
  of TargetBoth: {MixerDevice, DeckDevice}

proc openMenu(current: var RuntimeState, target: ButtonTarget, menu: string) =
  ## Record one linked transition for every target device unless all are already there.
  ## Returning exactly to the newest transition's previous menus on the same devices undoes
  ## that transition instead, so reciprocal menu links do not grow history.
  ## A full history rejects any other transition and leaves menus and history unchanged.
  let devices = targetDevices(target)
  var changes = false
  for device in devices:
    if current.menus[device] != menu:
      changes = true
  var undoes = changes and current.history.len > 0 and current.history[^1].devices == devices
  if undoes:
    for device in devices:
      if current.history[^1].previous[device] != menu:
        undoes = false
  if undoes:
    current.history.setLen(current.history.len - 1)
    for device in devices:
      current.setMenu(device, menu)
  elif changes:
    if current.history.len >= MaxNavigationHistory:
      raise newException(IOError, NavigationLimitMessage)
    var transition = Transition(devices: devices)
    for device in devices:
      transition.previous[device] = current.menus[device]
    current.history.add(transition)
    for device in devices:
      current.setMenu(device, menu)

proc goBack(current: var RuntimeState, device: ButtonDevice) =
  ## Undo the newest transition affecting a device, with its linked devices and dependents.
  var chosen = -1
  for index in countdown(current.history.high, 0):
    if device in current.history[index].devices:
      chosen = index
      break
  if chosen < 0:
    return
  let entry = current.history[chosen]
  var
    affected = entry.devices
    restore = entry.previous
    restored = entry.devices
    kept = current.history[0..<chosen]
  for index in chosen + 1..current.history.high:
    let later = current.history[index]
    if (later.devices * affected).card > 0:
      affected = affected + later.devices
      for other in later.devices - restored:
        restore[other] = later.previous[other]
        restored.incl(other)
    else:
      kept.add(later)
  current.history = kept
  for target in restored:
    current.setMenu(target, restore[target])

proc goHome(current: var RuntimeState) =
  ## Return both devices to the root menu and clear all navigation history.
  current.history = @[]
  for device in ButtonDevice:
    current.setMenu(device, current.active.buttons.root)

proc route(device: ButtonDevice, key: int, pressed: bool) =
  ## Resolve one physical edge against the active menu, navigating synchronously.
  ## Every fresh press updates the help overlay before its own action runs once.
  withState:
    if not state.initialized:
      raise newException(IOError, "Button runtime is not initialized.")
    let index = key - 1
    if not pressed:
      state.input[device].held[index] = false
      state.input[device].quarantined[index] = false
    elif not state.input[device].held[index] and not state.input[device].quarantined[index]:
      state.input[device].held[index] = true
      if device == DeckDevice and not state.deckReady:
        state.input[device].quarantined[index] = true
        pressMixerOverlay(false)
      else:
        let
          menu = menuButtons(state.active.buttons, state.menus[device])
          button = if device == MixerDevice: menu.mixer[index] else: menu.deck[index]
        pressMixerOverlay(button.action.kind == MixerOverlayAction)
        case button.action.kind
        of NoAction: discard
        of MenuAction: state.openMenu(button.action.target, button.action.menu)
        of BackAction: state.goBack(device)
        of HomeAction: state.goHome()
        else:
          if state.actions.len >= MaxButtonActions:
            raise newException(IOError, "Button action queue is full.")
          inc state.actionSequence
          state.actions.add(ownedCopy(CapturedAction(sequence: state.actionSequence,
            device: device, key: key, menu: menu.id, revision: state.active.revision,
            title: button.title, action: button.action)))

proc routeMixerButton*(note: int, pressed: bool) =
  ## Route a mixer note edge; notes outside the twelve buttons are ignored.
  if note in 1..MixerKeyCount:
    route(MixerDevice, note, pressed)

proc routeDeckButton*(keyIndex: int, pressed: bool) =
  ## Route a zero-based Stream Deck key edge.
  if keyIndex in 0..<DeckKeyCount:
    route(DeckDevice, keyIndex + 1, pressed)

proc resetMixerInput*() =
  ## Forget held and quarantined mixer keys at a device session boundary.
  withState:
    state.input[MixerDevice] = DeviceInput()

proc resetDeckInput*() =
  ## Forget held and quarantined Deck keys and require a fresh page upload.
  withState:
    state.input[DeckDevice] = DeviceInput()
    state.deckReady = false
    state.deckReadGeneration = 0

proc takeButtonActions*(): seq[JsonNode] =
  ## Drain resolved, press-time actions in press order without executing them.
  var taken: seq[CapturedAction]
  withState:
    taken = move(state.actions)
    state.actions = @[]
  for action in taken:
    result.add(%*{"sequence": action.sequence, "device": $action.device, "key": action.key,
      "menu": action.menu, "revision": action.revision, "title": action.title,
      "action": actionJson(action.action)})

proc readDeckPage*(previousGeneration: int64): JsonNode =
  ## Return the current Deck page when it differs from the player's, or nil when unchanged.
  var
    generation: int64
    menu, page: string
  withState:
    if previousGeneration <= 0:
      state.input[DeckDevice] = DeviceInput()
    if previousGeneration == state.deckGeneration:
      return nil
    state.deckReady = false
    state.deckReadGeneration = state.deckGeneration
    generation = state.deckGeneration
    menu = ownedCopy(state.menus[DeckDevice])
    page = ownedCopy(state.active.pages[menu])
  result = %*{"generation": generation, "menu": menu, "keys": parseJson(page)}

proc deckPageReady*() =
  ## Accept Deck input once the page last read is uploaded and still current.
  withState:
    if state.deckReadGeneration == state.deckGeneration:
      state.deckReady = true

proc buttonDescription(button: ConfiguredButton, buttons: ButtonSet): string =
  ## Describe a configured button for the status catalog.
  case button.action.kind
  of NoAction: "No action assigned."
  of CommandAction: "Run: " & button.action.command
  of MenuAction:
    let
      target = case button.action.target
        of TargetMixer: "the mixer"
        of TargetDeck: "the Stream Deck"
        of TargetBoth: "both devices"
      menu = menuButtons(buttons, button.action.menu)
    "Open " & (if menu.title.len > 0: menu.title else: menu.id) & " on " & target & "."
  of BackAction: "Return to the previous menu."
  of HomeAction: "Return to the main menu."
  of ObsAction: obsOperationDescription(button.action.operation)
  of GrokAction, ClaudeAction, FfxivAction, MicrophonesAction, DiscordAction:
    let compiled = case button.action.kind
      of GrokAction: OpenGrok
      of ClaudeAction: OpenClaude
      of FfxivAction: LaunchFfxiv
      of MicrophonesAction: ToggleMicrophones
      else: ToggleDiscord
    var description = ""
    for binding in ButtonBindings:
      if binding.action == compiled:
        description = binding.description
    description
  of DiscordDeafenAction, OpenDiscordAction, MixerOverlayAction,
      DiscordAcceptVoiceAction, DiscordAcceptVideoAction:
    namedActionDescription(button.action.kind)

proc activeMixerCatalog*(): JsonNode =
  ## Describe the active mixer menu in the twelve-slot catalog shape used by status.
  var
    menu: ConfiguredMenu
    buttons: ButtonSet
  withState:
    buttons = ownedCopy(state.active.buttons)
    menu = menuButtons(buttons, state.menus[MixerDevice])
  result = %*{"buttons": [], "faders": bindingCatalog()["faders"]}
  for button in menu.mixer:
    let label = if button.title.len > 0: button.title
      elif button.action.kind == NoAction: UnassignedTitle
      else: $button.action.kind
    result["buttons"].add(%*{"note": button.key, "label": label,
      "description": buttonDescription(button, buttons)})

proc recordJson(record: OperationRecord): JsonNode =
  ## Encode an operation record with a fixed field set.
  %*{"id": record.id, "kind": record.kind, "status": record.status, "error": record.error,
    "code": record.code, "field": record.field, "revision": record.revision,
    "manifestPath": record.manifestPath, "path": record.path,
    "startedMs": record.startedMs, "finishedMs": record.finishedMs}

proc buttonRuntimeStatus*(): JsonNode =
  ## Report active revision, navigation, Deck readiness, and bounded operation results.
  withState:
    result = %*{"initialized": state.initialized, "session": state.session,
      "revision": state.active.revision, "source": state.active.source,
      "startupError": state.startupError, "root": state.active.buttons.root,
      "mixerMenu": state.menus[MixerDevice], "deckMenu": state.menus[DeckDevice],
      "historyDepth": state.history.len, "deckGeneration": state.deckGeneration,
      "deckReady": state.deckReady, "manifestPath": state.active.manifestPath,
      "busy": state.busy, "operation": newJNull(), "recent": [],
      "lastOperationSequence": state.operationSequence, "pendingActions": state.actions.len,
      "overlay": mixerOverlayStatus()}
    if state.hasCurrent:
      result["operation"] = recordJson(state.current)
    elif state.recent.len > 0:
      result["operation"] = recordJson(state.recent[0])
    for record in state.recent:
      result["recent"].add(recordJson(record))

proc buttonOperation*(id: string): JsonNode =
  ## Return a retained operation record, or nil when unknown or evicted.
  withState:
    if state.hasCurrent and state.current.id == id:
      return recordJson(state.current)
    for record in state.recent:
      if record.id == id:
        return recordJson(record)

proc installConfig(current: var RuntimeState, active: ActiveConfig) =
  ## Swap the active configuration, resetting navigation and quarantining held keys.
  current.active = ownedCopy(active)
  current.history = @[]
  for device in ButtonDevice:
    current.menus[device] = active.buttons.root
    quarantineHeld(current.input[device])
  current.bumpDeckPage()

proc loadCandidate(config: JsonNode, source: string): tuple[active: ActiveConfig, manifest: JsonNode] =
  ## Validate and prepare one startup candidate on the calling thread.
  let canonical = canonicalButtonConfig(config)
  result.active = ActiveConfig(buttons: parseButtonSet(canonical), configText: $canonical,
    revision: sha256Hex($canonical), source: source)
  {.cast(gcsafe).}:
    result.manifest = services.prepare(canonical)
  result.active.pages = manifestPages(result.active.buttons, result.manifest)

proc initializeButtons*(paths = newButtonPaths(), buttonServices = defaultButtonServices()) =
  ## Load buttons.json, then last-applied.json, then defaults, using the first that prepares.
  if buttonServices.prepare.isNil or buttonServices.importAsset.isNil:
    raise newException(ValueError, "Button services need prepare and importAsset callbacks.")
  withState:
    if state.workerRunning:
      raise newException(ValueError, "Stop the button worker before reinitializing.")
  {.cast(gcsafe).}:
    services = buttonServices
  var
    errors: seq[string]
    diskText = ""
    diskExists = false
    lastAppliedRevision = ""
    chosen: tuple[active: ActiveConfig, manifest: JsonNode]
    found = false
  # Startup recovery deliberately records every candidate failure and keeps going,
  # because a broken edit or missing media must not stop MIDI and audio control.
  if fileExists(paths.configPath()):
    diskExists = true
    try:
      diskText = readFile(paths.configPath())
      chosen = loadCandidate(parseJson(diskText), CanonicalSource)
      found = true
    except CatchableError as error:
      errors.add("buttons.json: " & error.msg)
  if not found and fileExists(paths.lastAppliedPath()):
    try:
      let config = decodeLastApplied(readFile(paths.lastAppliedPath()))
      chosen = loadCandidate(config, LastAppliedSource)
      found = true
      if not diskExists:
        errors.add("buttons.json is missing; using the last applied configuration.")
    except CatchableError as error:
      errors.add("last-applied.json: " & error.msg)
  if not found:
    try:
      chosen = loadCandidate(defaultButtonConfig(), DefaultsSource)
    except CatchableError as error:
      errors.add("defaults: " & error.msg)
      let defaults = defaultButtonConfig()
      chosen.manifest = builtinButtonManifest(defaults)
      chosen.active = ActiveConfig(buttons: parseButtonSet(defaults), configText: $defaults,
        revision: configRevision(defaults), source: DefaultsSource,
        pages: manifestPages(parseButtonSet(defaults), chosen.manifest))
  try:
    chosen.active.manifestPath = writeManifest(paths, chosen.active.revision, chosen.manifest, [])
    if chosen.active.source == CanonicalSource:
      if fileExists(paths.lastAppliedPath()):
        try: lastAppliedRevision = configRevision(decodeLastApplied(readFile(paths.lastAppliedPath())))
        except ValueError: lastAppliedRevision = ""
      if lastAppliedRevision != chosen.active.revision:
        writeFileAtomic(paths.lastAppliedPath(), encodeLastApplied(parseJson(chosen.active.configText)))
  except IOError, OSError:
    errors.add("state: " & getCurrentExceptionMsg())
  var matches = false
  if diskExists and chosen.active.source == CanonicalSource:
    matches = true
  resetMixerOverlay()
  withState:
    state = RuntimeState(initialized: true, paths: ownedCopy(paths),
      session: $getCurrentProcessId() & "." & $epochMs(), startupError: errors.join("\n"),
      diskText: ownedCopy(diskText), diskExists: diskExists, diskMatchesActive: matches)
    state.installConfig(chosen.active)

proc readDisk(paths: ButtonPaths): tuple[exists: bool, text: string] =
  ## Read the canonical file's current bytes for conflict detection.
  if fileExists(paths.configPath()):
    result = (true, readFile(paths.configPath()))

proc runApply(job: ConfigJob, paths: ButtonPaths, record: var OperationRecord) =
  ## Prepare, persist, and swap one configuration; any failure leaves the active one intact.
  let config = parseJson(job.payload)
  var active = ActiveConfig(buttons: parseButtonSet(config), configText: job.payload,
    revision: sha256Hex(job.payload), source: CanonicalSource)
  record.revision = active.revision
  var
    activeRevision, diskText, activeManifest: string
    diskExists, diskMatches: bool
  withState:
    activeRevision = ownedCopy(state.active.revision)
    diskText = ownedCopy(state.diskText)
    diskExists = state.diskExists
    diskMatches = state.diskMatchesActive
    activeManifest = ownedCopy(state.active.manifestPath)
  if activeRevision != job.baseRevision:
    fail("stale", "Configuration changed since revision " & job.baseRevision & ".")
  var manifest: JsonNode
  step("prepare"):
    {.cast(gcsafe).}:
      manifest = services.prepare(config)
    active.pages = manifestPages(active.buttons, manifest)
  step("persist"):
    active.manifestPath = writeManifest(paths, active.revision, manifest, [activeManifest])
  record.manifestPath = active.manifestPath
  var disk: tuple[exists: bool, text: string]
  step("persist"):
    disk = readDisk(paths)
  if disk.exists != diskExists or disk.text != diskText:
    fail("diskChanged", "buttons.json changed outside Knobby after it was loaded. " &
      "Restart Knobby to load it or restore the file; external edits are not overwritten.")
  step("persist"):
    if diskExists and not diskMatches:
      writeFileAtomic(paths.invalidBackupPath(), diskText)
    writeFileAtomic(paths.configPath(), encodeConfigFile(config))
  try:
    writeFileAtomic(paths.lastAppliedPath(), encodeLastApplied(config))
  except CatchableError as error:
    var message = "Saving last-applied.json failed: " & error.msg
    try:
      if diskExists: writeFileAtomic(paths.configPath(), diskText)
      else: removeFile(paths.configPath())
    except CatchableError as restoreError:
      message.add(" Restoring buttons.json also failed: " & restoreError.msg)
    fail("persist", message)
  withState:
    state.installConfig(active)
    state.diskText = encodeConfigFile(config)
    state.diskExists = true
    state.diskMatchesActive = true
    state.startupError = ""

proc runPreview(job: ConfigJob, paths: ButtonPaths, record: var OperationRecord) =
  ## Prepare a candidate and expose its manifest file without changing the active page.
  let config = parseJson(job.payload)
  record.revision = sha256Hex(job.payload)
  var
    manifest: JsonNode
    activeManifest: string
  withState:
    activeManifest = ownedCopy(state.active.manifestPath)
  step("prepare"):
    {.cast(gcsafe).}:
      manifest = services.prepare(config)
    discard manifestPages(parseButtonSet(config), manifest)
  step("persist"):
    record.manifestPath = writeManifest(paths, record.revision, manifest, [activeManifest])

proc runImport(job: ConfigJob, record: var OperationRecord) =
  ## Copy a source file into managed assets through the media service.
  var path: string
  step("import"):
    {.cast(gcsafe).}:
      path = services.importAsset(job.payload)
  if not isManagedAssetPath(path):
    fail("import", "Media service returned an unmanaged asset path: " & path)
  record.path = path

proc runWorker() {.thread.} =
  ## Execute one config job at a time, away from input, render, and IPC threads.
  while true:
    var
      job: ConfigJob
      record: OperationRecord
      paths: ButtonPaths
      haveJob = false
    withState:
      while not state.hasJob and not state.workerStopping:
        wait(jobReady, routerLock)
      if state.hasJob:
        job = ownedCopy(state.job)
        state.hasJob = false
        state.current.status = RunningStatus
        record = ownedCopy(state.current)
        paths = ownedCopy(state.paths)
        haveJob = true
    if not haveJob:
      break
    try:
      case job.kind
      of ApplyOperation: runApply(job, paths, record)
      of PreviewOperation: runPreview(job, paths, record)
      of ImportOperation: runImport(job, record)
      record.status = SucceededStatus
    except OperationFailure as error:
      record.status = FailedStatus
      record.error = error.msg
      record.code = error.code
      record.field = error.field
    {.cast(gcsafe).}:
      if record.status == SucceededStatus and job.kind != ImportOperation and
          not services.maintain.isNil:
        try:
          services.maintain()
        except CatchableError as error:
          stderr.writeLine("Button cache maintenance failed: " & error.msg)
    record.finishedMs = epochMs()
    withState:
      state.hasCurrent = false
      state.busy = false
      state.recent.insert(ownedCopy(record), 0)
      if state.recent.len > MaxRecentOperations:
        state.recent.setLen(MaxRecentOperations)

proc startButtonWorker*() =
  ## Start the single configuration job worker after initialization.
  withState:
    if not state.initialized:
      raise newException(ValueError, "Initialize buttons before starting the worker.")
    if state.workerRunning:
      raise newException(ValueError, "Button worker is already running.")
    state.workerRunning = true
    state.workerStopping = false
  createThread(workerThread, runWorker)

proc stopButtonWorker*() =
  ## Finish any accepted job, then join the worker.
  withState:
    if not state.workerRunning:
      return
    state.workerStopping = true
    signal(jobReady)
  joinThread(workerThread)
  withState:
    state.workerRunning = false

proc resultReply(ok: bool): JsonNode =
  ## Start a versioned request result.
  %*{"version": ProtocolVersion, "type": "result", "ok": ok}

proc errorReply(code, message: string, field = ""): JsonNode =
  ## Describe a rejected request with metadata the editor maps to fields.
  result = resultReply(false)
  result["error"] = %message
  result["code"] = %code
  result["field"] = %field

proc enqueue(kind: OperationKind, baseRevision, payload: string): JsonNode =
  ## Accept one job, or reject it immediately as unavailable, busy, or stale.
  withState:
    if not state.workerRunning or state.workerStopping:
      return errorReply("unavailable", "The button configuration worker is not running.")
    if state.busy:
      return errorReply("busy", "Another button configuration operation is in progress.")
    if kind == ApplyOperation and baseRevision != state.active.revision:
      result = errorReply("stale", "Configuration changed since revision " & baseRevision &
        "; export it again and reapply your edits.", "baseRevision")
      result["revision"] = %state.active.revision
      return
    inc state.operationSequence
    let id = state.session & "-" & $state.operationSequence
    state.job = ownedCopy(ConfigJob(kind: kind, id: id, baseRevision: baseRevision,
      payload: payload))
    state.hasJob = true
    state.busy = true
    state.current = OperationRecord(id: id, kind: $kind, status: QueuedStatus, startedMs: epochMs())
    state.hasCurrent = true
    signal(jobReady)
    result = resultReply(true)
    result["operationId"] = %id

proc requestedConfig(message: JsonNode): JsonNode =
  ## Return the request's configuration object, naming the missing field otherwise.
  result = message{"config"}
  if result.isNil or result.kind != JObject:
    var error = newException(ButtonConfigError, "config: Expected a configuration object.")
    error.field = "config"
    raise error

proc processConfigRequest*(message: JsonNode): JsonNode =
  ## Answer one versioned config.* request immediately; slow work runs as an operation.
  if message.isNil or message.kind != JObject or message{"version"}.getInt(-1) != ProtocolVersion:
    return errorReply("version", "Incompatible Knobby IPC version.")
  var initialized = false
  withState:
    initialized = state.initialized
  if not initialized:
    return errorReply("unavailable", "Button configuration is not initialized.")
  let kind = message{"type"}.getStr()
  try:
    case kind
    of RequestPrefix & "get":
      var revision, configText, source, startupError: string
      withState:
        revision = ownedCopy(state.active.revision)
        configText = ownedCopy(state.active.configText)
        source = ownedCopy(state.active.source)
        startupError = ownedCopy(state.startupError)
      result = resultReply(true)
      result["envelope"] = %*{"baseRevision": revision, "config": parseJson(configText)}
      result["source"] = %source
      result["startupError"] = %startupError
    of RequestPrefix & "validate":
      let canonical = canonicalButtonConfig(requestedConfig(message))
      result = resultReply(true)
      result["revision"] = %sha256Hex($canonical)
      result["config"] = canonical
    of RequestPrefix & "apply":
      let envelope = parseConfigEnvelope(message{"envelope"})
      result = enqueue(ApplyOperation, envelope.baseRevision, $canonicalButtonConfig(envelope.config))
    of RequestPrefix & "preview":
      result = enqueue(PreviewOperation, "", $canonicalButtonConfig(requestedConfig(message)))
    of RequestPrefix & "importAsset":
      let source = message{"source"}.getStr()
      if source.len == 0 or not source.isAbsolute():
        result = errorReply("invalid", "Asset source must be an absolute path.", "source")
      else:
        result = enqueue(ImportOperation, "", source)
    else:
      result = errorReply("unsupported", "Unsupported request type: " & kind)
  except ButtonConfigError as error:
    result = errorReply("invalid", error.msg, error.field)

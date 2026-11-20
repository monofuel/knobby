import
  std/[algorithm, json, os, strutils, unicode],
  knobby/[button_config, controls_state, obs_state]

type
  ConflictState* = enum
    NoConflict, StaleRevision
  EditorModel* = object
    ## Draft editing state shared by the GUI and tests; it holds no rendering or I/O handles.
    live*: JsonNode
    liveRevision*: string
    base*: JsonNode
    baseRevision*: string
    draft*: JsonNode
    menu*: string
    device*: ButtonDevice
    key*: int
    dirty*: bool
    validation*, validationField*: string
    error*, errorField*, notice*: string
    conflict*: ConflictState
    edits*: int
    loaded*: bool
    submitted*: JsonNode
    submittedEdits*: int
    visualState*: string
  DraftSaver* = object
    ## Autosave bookkeeping; edits count as saved only after the file write or removal succeeds.
    path*: string
    savedEdits*, seenEdits*: int
    changedMs*, retryMs*: int64
    failure*: string

const
  BackKey* = 1
  ActionLabels*: array[ConfigActionKind, string] = ["None", "Command", "Grok",
    "Claude", "FFXIV", "Microphones", "Discord mute", "Open menu", "Back", "Home", "OBS",
    "Discord deafen", "Open Discord", "Mixer overlay", "Answer voice", "Answer video", "Menu drawer"]
  TargetLabels*: array[ButtonTarget, string] = ["Mixer", "Deck", "Both"]
  DeviceLabels*: array[ButtonDevice, string] = ["Arduino mixer", "Stream Deck"]
  StaleCode* = "stale"
  DraftFileName = "gui-draft.json"
  DraftSaveDelayMs* = 700
  MaxPreparedBytes* = 64 * 1024
  NormalState* = ""
  StateLabels* = [("", "Default"), ("recording", "Recording"), ("paused", "Paused"),
    ("muted", "Muted"), ("unavailable", "Unavailable"),
    ("running", "Running"), ("ready", "Ready"), ("active", "Selected"),
    ("blocked", "Switching blocked"), ("mixed", "Mixed"), ("deafened", "Deafened")]

proc keyCount*(device: ButtonDevice): int =
  ## Return the number of editable physical keys on a device.
  case device
  of MixerDevice: MixerKeyCount
  of DeckDevice: DeckKeyCount

proc rootMenu*(config: JsonNode): string =
  ## Return the configured root menu ID, which need not be named "root".
  if config.isNil: RootMenuId else: config{"root"}.getStr(RootMenuId)

proc isLockedBack*(config: JsonNode, menu: string, key: int): bool =
  ## Report whether a slot is the reserved Home or Back key in a non-root menu.
  menu != config.rootMenu() and key == BackKey

proc menus*(config: JsonNode): seq[JsonNode] =
  ## Return menu objects in their configured order.
  if config.isNil or config{"menus"}.isNil: return
  for menu in config["menus"]: result.add(menu)

proc findMenu*(config: JsonNode, id: string): JsonNode =
  ## Return the menu with an ID, or nil when absent.
  for menu in config.menus():
    if menu{"id"}.getStr() == id: return menu

proc menuIds*(config: JsonNode): seq[string] =
  ## List menu IDs in configured order.
  for menu in config.menus(): result.add(menu{"id"}.getStr())

proc menuTitle*(config: JsonNode, id: string): string =
  ## Return a menu's display title, falling back to its ID.
  let menu = config.findMenu(id)
  if menu.isNil or menu{"title"}.getStr().len == 0: id
  else: menu["title"].getStr()

proc entryAt*(config: JsonNode, menu: string, device: ButtonDevice, key: int): JsonNode =
  ## Return a slot from a possibly invalid draft, filling Back and unassigned keys like buttonAt.
  let menuNode = config.findMenu(menu)
  if not menuNode.isNil and not menuNode{$device}.isNil and menuNode[$device].kind == JArray:
    for entry in menuNode[$device]:
      if entry{"key"}.getInt() == key: return entry
  if config.isLockedBack(menu, key):
    %*{"key": key, "title": BackTitle, "action": {"kind": $BackAction}}
  else:
    %*{"key": key, "title": UnassignedTitle, "action": {"kind": $NoAction}}

proc effectiveDeckMenu*(menu, drawer: string, key: int): string =
  ## Return the menu a live Deck key shows: an open drawer covers keys 1 to 5.
  if drawer.len > 0 and key in 1..DrawerKeyCount: drawer else: menu

proc actionKind*(entry: JsonNode): ConfigActionKind =
  ## Return a slot's action kind.
  parseEnum[ConfigActionKind](entry{"action"}{"kind"}.getStr("none"), NoAction)

proc menuTarget*(entry: JsonNode): ButtonTarget =
  ## Return a menu action's target devices.
  parseEnum[ButtonTarget](entry{"action"}{"target"}.getStr("both"), TargetBoth)

proc hasImage*(entry: JsonNode): bool =
  ## Report whether a Deck slot uses an imported image.
  entry{"visual"}{"image"}.getStr().len > 0

proc showsTitle*(entry: JsonNode): bool =
  ## Return the effective title overlay setting, defaulting by image presence.
  let value = entry{"visual"}{"showTitle"}
  if not value.isNil and value.kind == JBool: value.getBool()
  else: not entry.hasImage()

proc obsOperation*(entry: JsonNode): string =
  ## Return an OBS action's operation, or "" for any other action.
  if entry.actionKind() == ObsAction: entry{"action"}{"operation"}.getStr() else: ""

proc obsStates*(operation: string): seq[string] =
  ## List the visual states core can select for an operation, in display order.
  case operation
  of "recordToggle", "pauseToggle": @["recording", "paused", "unavailable"]
  of "micToggle": @["muted", "unavailable"]
  of "open": @["running", "unavailable"]
  of "minecraft1080", "firefox1080", "wow1080": @["running", "ready", "unavailable"]
  of "selectMinecraft", "selectFirefox", "selectWow": @["active", "blocked", "unavailable"]
  else: @[]

proc controlStates*(kind: string): seq[string] =
  ## List the visual states core can select for a control action, in display order.
  case kind
  of "microphones": @["muted", "mixed", "unavailable"]
  of "discord": @["muted", "deafened", "unavailable"]
  of "discordDeafen": @["deafened", "unavailable"]
  of "openDiscord": @["running", "ready"]
  of "discordAcceptVoice", "discordAcceptVideo": @["ready", "unavailable"]
  else: @[]

proc entryStates*(entry: JsonNode): seq[string] =
  ## List the visual states of a configured slot's OBS or control action.
  if entry.actionKind() == ObsAction: obsStates(entry.obsOperation())
  else: controlStates(entry{"action"}{"kind"}.getStr())

proc manifestStates*(entry: JsonNode): seq[string] =
  ## List the visual states of a prepared manifest entry's OBS or control action.
  let (kind, operation) = entry.manifestStatusAction()
  if kind == "obs": obsStates(operation) else: controlStates(kind)

proc stateLabel*(state: string): string =
  ## Name a visual state for editor controls.
  for (name, label) in StateLabels:
    if name == state: return label
  state

proc stateImage*(entry: JsonNode, state: string): string =
  ## Return the managed image for a visual state, or the base image for NormalState.
  if state == NormalState: entry{"visual"}{"image"}.getStr()
  else: entry{"visual"}{"states"}{state}.getStr()

proc describeAction*(config: JsonNode, entry: JsonNode): string =
  ## Summarize an action for compact grid tiles and status text.
  let action = entry{"action"}
  case entry.actionKind()
  of NoAction: "No action"
  of CommandAction: "Run " & action{"command"}.getStr()
  of MenuAction:
    "Open " & config.menuTitle(action{"menu"}.getStr()) & " on " &
      TargetLabels[entry.menuTarget()].toLowerAscii()
  of HomeAction: "Return to main menu"
  of DeckMenuAction: "Open the " & config.menuTitle(action{"menu"}.getStr()) & " drawer"
  of ObsAction: "OBS: " & obsOperationLabel(entry.obsOperation())
  else: ActionLabels[entry.actionKind()]

proc menuReferences*(config: JsonNode, id: string): seq[string] =
  ## Describe every slot that opens a menu, so deletion never leaves dangling targets.
  for menu in config.menus():
    for device in ButtonDevice:
      if menu{$device}.isNil: continue
      for entry in menu[$device]:
        if entry.actionKind() in {MenuAction, DeckMenuAction} and
            entry["action"]{"menu"}.getStr() == id:
          result.add(config.menuTitle(menu{"id"}.getStr()) & " " & $device &
            " key " & $entry{"key"}.getInt())

proc menuIdFromTitle*(config: JsonNode, title: string): string =
  ## Derive a stable unique ASCII ID from a possibly Unicode menu title.
  var slug = ""
  for character in title.toLowerAscii():
    if character in {'a'..'z', '0'..'9'}:
      slug.add(character)
    elif slug.len > 0 and slug[^1] != '-':
      slug.add('-')
  slug = slug.strip(chars = {'-'})
  if slug.len == 0: slug = "menu"
  const SuffixRoom = 4
  if slug.len > MaxIdBytes - SuffixRoom:
    slug = slug[0..<MaxIdBytes - SuffixRoom].strip(chars = {'-'})
  result = slug
  var suffix = 2
  let ids = config.menuIds()
  while result in ids:
    result = slug & "-" & $suffix
    inc suffix

proc sameConfiguration(a, b: JsonNode): bool =
  ## Compare by canonical revision so defaulted fields and entry order are not edits.
  if a == b: return true
  try:
    result = configRevision(a) == configRevision(b)
  except ValueError:
    result = false

proc refresh(model: var EditorModel) =
  ## Recompute dirtiness and run the shared core validator over the draft.
  model.dirty = model.loaded and not sameConfiguration(model.draft, model.base)
  model.validation = ""
  model.validationField = ""
  try:
    validateButtonConfig(model.draft)
  except ButtonConfigError as error:
    model.validation = error.msg
    model.validationField = error.field

proc ensureSelection(model: var EditorModel) =
  ## Keep the selected menu and key valid after configuration changes.
  if model.draft.findMenu(model.menu).isNil:
    model.menu = model.draft.rootMenu()
  model.key = clamp(model.key, 1, model.device.keyCount())
  let states = model.draft.entryAt(model.menu, model.device, model.key).entryStates()
  if model.device != DeckDevice or model.visualState notin states:
    model.visualState = NormalState

proc touch(model: var EditorModel) =
  ## Record a draft edit, clear the previous failure, and revalidate.
  model.ensureSelection()
  inc model.edits
  model.error = ""
  model.errorField = ""
  model.notice = ""
  model.refresh()

proc newEditorModel*(): EditorModel =
  ## Create an unloaded editor targeting the root mixer page.
  EditorModel(menu: RootMenuId, device: MixerDevice, key: BackKey)

proc isDirty*(model: EditorModel): bool =
  ## Report whether the draft differs from the configuration it was based on.
  model.dirty

proc canApply*(model: EditorModel): bool =
  ## Report whether Save & Apply can be attempted without a known local failure.
  model.loaded and model.dirty and model.validation.len == 0 and
    model.conflict == NoConflict

proc loadLive*(model: var EditorModel, envelope: JsonNode) =
  ## Record the daemon's configuration, retaining unsaved edits and flagging a changed base.
  let parsed = parseConfigEnvelope(envelope)
  model.live = parsed.config.copy()
  model.liveRevision = parsed.baseRevision
  if not model.loaded or not model.dirty:
    model.base = parsed.config.copy()
    model.baseRevision = parsed.baseRevision
    model.draft = parsed.config.copy()
    model.conflict = NoConflict
  elif parsed.baseRevision != model.baseRevision:
    model.conflict = StaleRevision
  if not model.loaded:
    model.menu = model.draft.rootMenu()
  model.loaded = true
  model.ensureSelection()
  model.refresh()

proc recoverDraft*(model: var EditorModel, draftEnvelope: JsonNode) =
  ## Restore an autosaved draft after loading live state; an older base becomes a conflict.
  if not model.loaded:
    raise newException(ValueError, "Load the live configuration before recovering a draft.")
  let config = draftEnvelope{"config"}
  if config.isNil or config.kind != JObject:
    raise newException(ValueError, "Draft has no config object.")
  if sameConfiguration(config, model.live):
    return
  let revision = draftEnvelope{"baseRevision"}.getStr()
  model.draft = config.copy()
  model.base = model.live.copy()
  model.baseRevision = revision
  model.conflict = if revision == model.liveRevision: NoConflict else: StaleRevision
  model.notice = "Recovered unsaved draft."
  inc model.edits
  model.ensureSelection()
  model.refresh()

proc rebaseDraft*(model: var EditorModel) =
  ## Keep the draft and target the newest live revision, replacing external changes on apply.
  model.base = model.live.copy()
  model.baseRevision = model.liveRevision
  model.conflict = NoConflict
  model.touch()

proc discardDraft*(model: var EditorModel) =
  ## Drop all unsaved edits and return to the newest live configuration.
  model.base = model.live.copy()
  model.baseRevision = model.liveRevision
  model.draft = model.live.copy()
  model.conflict = NoConflict
  model.ensureSelection()
  model.touch()

proc draftEnvelope*(model: EditorModel): JsonNode =
  ## Build the shared CLI/GUI envelope for apply and draft files.
  %*{"baseRevision": model.baseRevision, "config": model.draft}

proc selectMenu*(model: var EditorModel, id: string) =
  ## Choose the menu being edited without changing any device's live menu.
  if model.draft.findMenu(id).isNil:
    raise newException(ValueError, "Unknown menu: " & id)
  model.menu = id
  model.ensureSelection()

proc selectDevice*(model: var EditorModel, device: ButtonDevice) =
  ## Choose the device grid being edited.
  model.device = device
  model.key = clamp(model.key, 1, device.keyCount())
  model.ensureSelection()

proc selectKey*(model: var EditorModel, key: int) =
  ## Inspect one slot; selection never dispatches its action.
  if key notin 1..model.device.keyCount():
    raise newException(ValueError, "Key " & $key & " is outside the " & $model.device & " grid.")
  model.key = key
  model.ensureSelection()

proc selected*(model: EditorModel): JsonNode =
  ## Return the effective selected slot, including implicit Back and unassigned keys.
  model.draft.entryAt(model.menu, model.device, model.key)

proc selectVisualState*(model: var EditorModel, state: string) =
  ## Choose which state's image the Deck preview and image controls use; OBS and controls are never contacted.
  if model.device != DeckDevice or
      (state != NormalState and state notin model.selected().entryStates()):
    raise newException(ValueError, "The selected key has no " & stateLabel(state).toLowerAscii() &
      " image.")
  model.visualState = state

proc selectedLocked*(model: EditorModel): bool =
  ## Report whether the selected slot is the reserved Home or Back key; a Deck Menu key stays editable.
  model.draft.isLockedBack(model.menu, model.key) and
    not (model.device == DeckDevice and model.selected().actionKind() == DeckMenuAction)

proc mutableEntry(model: var EditorModel): JsonNode =
  ## Return the selected slot in the draft, materializing it in key order.
  if model.selectedLocked():
    raise newException(ValueError, "Key 1 of a submenu is reserved for navigation.")
  let menu = model.draft.findMenu(model.menu)
  if menu.isNil:
    raise newException(ValueError, "Unknown menu: " & model.menu)
  if menu{$model.device}.isNil:
    menu[$model.device] = newJArray()
  for entry in menu[$model.device]:
    if entry{"key"}.getInt() == model.key:
      return entry
  result = %*{"key": model.key, "title": "", "action": {"kind": "none"}}
  var entries = menu[$model.device].getElems()
  entries.add(result)
  entries.sort(proc (a, b: JsonNode): int = cmp(a{"key"}.getInt(), b{"key"}.getInt()))
  menu[$model.device] = %entries

proc setTitle*(model: var EditorModel, title: string) =
  ## Set a slot's Unicode title; a Deck title replaces migrated numbered artwork.
  if title.validateUtf8() >= 0:
    raise newException(ValueError, "Title is not valid UTF-8.")
  let entry = model.mutableEntry()
  entry["title"] = %title.replace("\n", " ")
  let visual = entry{"visual"}
  if model.device == DeckDevice and not visual.isNil and visual.hasKey("builtinNumber"):
    visual.delete("builtinNumber")
    if visual.hasKey("showTitle"): visual.delete("showTitle")
  model.touch()

proc setActionKind*(model: var EditorModel, kind: ConfigActionKind) =
  ## Change a slot's action, keeping compatible fields and defaulting menu targets.
  let
    entry = model.mutableEntry()
    previous = entry{"action"}
  var action = %*{"kind": $kind}
  case kind
  of CommandAction:
    action["command"] = %previous{"command"}.getStr()
  of MenuAction:
    var target = previous{"menu"}.getStr()
    if model.draft.findMenu(target).isNil:
      target = ""
      for id in model.draft.menuIds():
        if id != model.menu and id != model.draft.rootMenu():
          target = id
          break
    action["menu"] = %target
    action["target"] = %previous{"target"}.getStr($TargetBoth)
  of DeckMenuAction:
    var target = previous{"menu"}.getStr()
    if model.draft.findMenu(target).isNil:
      target = model.menu
    action["menu"] = %target
  of ObsAction:
    let operation = previous{"operation"}.getStr()
    action["operation"] = %(if isObsOperation(operation): operation else: ObsOperations[0])
  else: discard
  entry["action"] = action
  model.touch()

proc setCommand*(model: var EditorModel, command: string) =
  ## Set the shell command for a command action.
  let entry = model.mutableEntry()
  if entry.actionKind() != CommandAction:
    raise newException(ValueError, "Only command actions have a command.")
  entry["action"]["command"] = %command
  model.touch()

proc setMenuTarget*(model: var EditorModel, menu: string) =
  ## Choose the menu a menu action opens.
  if model.draft.findMenu(menu).isNil:
    raise newException(ValueError, "Unknown menu: " & menu)
  let entry = model.mutableEntry()
  if entry.actionKind() notin {MenuAction, DeckMenuAction}:
    raise newException(ValueError, "Only menu and drawer actions have a target menu.")
  entry["action"]["menu"] = %menu
  model.touch()

proc setTargetDevice*(model: var EditorModel, target: ButtonTarget) =
  ## Choose whether a menu action opens on the mixer, Deck, or both.
  let entry = model.mutableEntry()
  if entry.actionKind() != MenuAction:
    raise newException(ValueError, "Only menu actions have a target device.")
  entry["action"]["target"] = %($target)
  model.touch()

proc deckVisual(model: var EditorModel): JsonNode =
  ## Return the selected Deck slot's mutable visual object.
  if model.device != DeckDevice:
    raise newException(ValueError, "Only Stream Deck keys have images.")
  let entry = model.mutableEntry()
  if entry{"visual"}.isNil or entry["visual"].kind != JObject:
    entry["visual"] = newJObject()
  entry["visual"]

proc setObsOperation*(model: var EditorModel, operation: string) =
  ## Choose what an OBS key does; its per-state images are kept for every operation.
  if not isObsOperation(operation):
    raise newException(ValueError, "Unknown OBS operation: " & operation)
  let entry = model.mutableEntry()
  if entry.actionKind() != ObsAction:
    raise newException(ValueError, "Only OBS actions have an operation.")
  entry["action"]["operation"] = %operation
  model.touch()

proc setImage*(model: var EditorModel, managedPath: string, state = NormalState) =
  ## Use an imported managed asset for the base face or one status state; base images hide the title.
  if not isManagedAssetPath(managedPath):
    raise newException(ValueError, "Images must be imported into the managed assets directory.")
  if state != NormalState and state notin VisualStates:
    raise newException(ValueError, "Unknown key state: " & state)
  let visual = model.deckVisual()
  if state == NormalState:
    if visual.hasKey("builtinNumber"): visual.delete("builtinNumber")
    visual["image"] = %managedPath
    if not visual.hasKey("showTitle"):
      visual["showTitle"] = %false
  else:
    if visual{"states"}.isNil or visual["states"].kind != JObject:
      visual["states"] = newJObject()
    visual["states"][state] = %managedPath
  model.touch()

proc clearImage*(model: var EditorModel, state = NormalState) =
  ## Remove the base image so the key renders its title, or one OBS state's image.
  let visual = model.deckVisual()
  if state == NormalState:
    for field in ["image", "showTitle"]:
      if visual.hasKey(field): visual.delete(field)
  else:
    let states = visual{"states"}
    if not states.isNil and states.kind == JObject and states.hasKey(state):
      states.delete(state)
      if states.len == 0: visual.delete("states")
  model.touch()

proc setShowTitle*(model: var EditorModel, show: bool) =
  ## Choose whether the title is drawn over a Deck key.
  model.deckVisual()["showTitle"] = %show
  model.touch()

proc createMenu*(model: var EditorModel, title: string): string =
  ## Add an empty submenu with a stable ASCII ID derived from its title.
  let name = title.strip()
  if name.len == 0:
    raise newException(ValueError, "Menu title cannot be empty.")
  if name.validateUtf8() >= 0:
    raise newException(ValueError, "Menu title is not valid UTF-8.")
  if model.draft.menus().len >= MaxMenus:
    raise newException(ValueError, "At most " & $MaxMenus & " menus are supported.")
  result = model.draft.menuIdFromTitle(name)
  model.draft["menus"].add(%*{"id": result, "title": name, "mixer": [], "deck": []})
  model.menu = result
  model.key = BackKey
  model.touch()

proc renameMenu*(model: var EditorModel, id, title: string) =
  ## Change a menu's displayed title; its ID and references stay stable.
  let menu = model.draft.findMenu(id)
  if menu.isNil:
    raise newException(ValueError, "Unknown menu: " & id)
  menu["title"] = %title.replace("\n", " ")
  model.touch()

proc deleteMenu*(model: var EditorModel, id: string) =
  ## Remove an unreferenced submenu; the root menu is permanent.
  if id == model.draft.rootMenu():
    raise newException(ValueError, "The main menu cannot be deleted.")
  if model.draft.findMenu(id).isNil:
    raise newException(ValueError, "Unknown menu: " & id)
  let references = model.draft.menuReferences(id)
  if references.len > 0:
    raise newException(ValueError, "Opened by " & references.join(", ") &
      ". Change those buttons first.")
  var kept = newJArray()
  for menu in model.draft["menus"]:
    if menu{"id"}.getStr() != id: kept.add(menu)
  model.draft["menus"] = kept
  if model.menu == id:
    model.menu = model.draft.rootMenu()
  model.touch()

proc setError*(model: var EditorModel, message: string, field = "") =
  ## Show a failure while retaining every draft edit.
  model.error = message
  model.errorField = field
  model.notice = ""

proc slotField*(model: EditorModel, menu: string, device: ButtonDevice, key: int): string =
  ## Return the validation path for one stored slot, or "" when it is implicit.
  var menuIndex = 0
  for menuNode in model.draft.menus():
    if menuNode{"id"}.getStr() == menu:
      var entryIndex = 0
      if not menuNode{$device}.isNil:
        for entry in menuNode[$device]:
          if entry{"key"}.getInt() == key:
            return "menus[" & $menuIndex & "]." & $device & "[" & $entryIndex & "]"
          inc entryIndex
      return ""
    inc menuIndex

proc menuField*(model: EditorModel, menu: string): string =
  ## Return the validation path for one menu, or "" when absent.
  let index = model.draft.menuIds().find(menu)
  if index >= 0: "menus[" & $index & "]" else: ""

proc fieldWithin(field, prefix: string): bool =
  ## Report whether a validation path names an object or one of its children.
  prefix.len > 0 and (field == prefix or field.startsWith(prefix & ".") or
    field.startsWith(prefix & "["))

proc problemField*(model: EditorModel): string =
  ## Return the field of the failure currently shown, preferring daemon errors.
  if model.error.len > 0: model.errorField else: model.validationField

proc problem*(model: EditorModel): string =
  ## Return the failure currently shown, preferring daemon errors over local validation.
  if model.error.len > 0: model.error else: model.validation

proc slotHasProblem*(model: EditorModel, menu: string, device: ButtonDevice, key: int): bool =
  ## Report whether the shown failure points at a slot.
  model.problemField().fieldWithin(model.slotField(menu, device, key))

proc menuHasProblem*(model: EditorModel, menu: string): bool =
  ## Report whether the shown failure points into a menu.
  model.problemField().fieldWithin(model.menuField(menu))

proc applySubmitted*(model: var EditorModel) =
  ## Record the draft just sent to the daemon, so edits made while it applies stay separate.
  model.submitted = model.draft.copy()
  model.submittedEdits = model.edits

proc applySucceeded*(model: var EditorModel, revision: string) =
  ## Adopt the submitted configuration as live; edits made while applying remain a dirty draft.
  if model.submitted.isNil:
    raise newException(ValueError, "No configuration was submitted for apply.")
  let applied = canonicalButtonConfig(model.submitted)
  model.live = applied.copy()
  model.liveRevision = revision
  model.base = applied.copy()
  model.baseRevision = revision
  if model.edits == model.submittedEdits:
    model.draft = applied.copy()
  model.submitted = nil
  model.conflict = NoConflict
  model.error = ""
  model.errorField = ""
  model.notice = "Applied."
  model.ensureSelection()
  model.refresh()

proc applyFailed*(model: var EditorModel, message, code, field: string) =
  ## Keep the draft, including edits made while applying, and mark revision conflicts.
  model.submitted = nil
  model.setError(message, field)
  if code == StaleCode: model.conflict = StaleRevision

proc draftPath*(): string =
  ## Return the GUI's autosaved draft path under Knobby's XDG state directory.
  buttonStateDirectory() / DraftFileName

proc writeDraft*(path: string, envelope: JsonNode) =
  ## Atomically replace the autosaved draft envelope.
  createDir(path.parentDir())
  writeFileAtomic(path, envelope.pretty() & "\n")

proc readDraft*(path: string): JsonNode =
  ## Load an autosaved draft envelope, or nil when none exists.
  if not fileExists(path): return nil
  result = parseFile(path)
  if result.kind != JObject or result{"config"}.isNil or result["config"].kind != JObject:
    raise newException(ValueError, "Draft file is not a configuration envelope: " & path)

proc readPreparedFrame*(path: string): string =
  ## Read one prepared key JPEG, refusing files larger than MaxPreparedBytes instead of loading them.
  let file = open(path)
  defer: file.close()
  result = newString(MaxPreparedBytes + 1)
  let count = file.readBuffer(addr result[0], result.len)
  if count > MaxPreparedBytes:
    raise newException(ValueError, "Prepared key image exceeds " & $MaxPreparedBytes &
      " bytes: " & path)
  result.setLen(count)

proc removeDraft*(path: string) =
  ## Delete an autosaved draft after it was applied or discarded.
  if fileExists(path): removeFile(path)

proc newDraftSaver*(path: string): DraftSaver =
  ## Track autosave progress for one draft file.
  DraftSaver(path: path)

proc markDraftSaved*(saver: var DraftSaver, model: EditorModel) =
  ## Record that the file already matches the current draft, as after recovering it.
  saver.savedEdits = model.edits
  saver.seenEdits = model.edits

proc markDraftStale*(saver: var DraftSaver) =
  ## Require the next autosave to rewrite or remove the file, as after an apply adopts the draft.
  saver.savedEdits = low(int)

proc draftPending*(saver: DraftSaver, model: EditorModel): bool =
  ## Report whether the draft file lags behind the latest edit.
  model.loaded and model.edits != saver.savedEdits

proc autosaveDraft*(saver: var DraftSaver, model: var EditorModel, timeMs: int64, force = false) =
  ## Write or remove the draft once edits settle; failures stay pending and retry after the same delay.
  if model.edits != saver.seenEdits:
    saver.seenEdits = model.edits
    saver.changedMs = timeMs
  if not saver.draftPending(model): return
  if not force and timeMs < max(saver.changedMs + DraftSaveDelayMs, saver.retryMs): return
  let edits = model.edits
  var failure = ""
  try:
    if model.dirty: writeDraft(saver.path, model.draftEnvelope())
    else: removeDraft(saver.path)
  except IOError, OSError:
    failure = "Draft autosave failed: " & getCurrentExceptionMsg() & " Retrying."
  if failure.len > 0:
    saver.retryMs = timeMs + DraftSaveDelayMs
    saver.failure = failure
    model.setError(failure)
  else:
    saver.savedEdits = edits
    saver.retryMs = 0
    if saver.failure.len > 0 and model.error == saver.failure:
      model.error = ""
      model.errorField = ""
    saver.failure = ""

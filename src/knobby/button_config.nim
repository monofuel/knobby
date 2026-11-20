import
  std/[algorithm, json, os, posix, sets, strutils, unicode],
  ./[bindings, obs_state]

type
  ButtonConfigError* = object of ValueError
    field*: string
  ConfigActionKind* = enum
    NoAction = "none", CommandAction = "command", GrokAction = "grok",
    ClaudeAction = "claude", FfxivAction = "ffxiv",
    MicrophonesAction = "microphones", DiscordAction = "discord",
    MenuAction = "menu", BackAction = "back", HomeAction = "home",
    ObsAction = "obs", DiscordDeafenAction = "discordDeafen",
    OpenDiscordAction = "openDiscord", MixerOverlayAction = "mixerOverlay",
    DiscordAcceptVoiceAction = "discordAcceptVoice", DiscordAcceptVideoAction = "discordAcceptVideo",
    DeckMenuAction = "deckMenu"
  ButtonTarget* = enum
    TargetMixer = "mixer", TargetDeck = "deck", TargetBoth = "both"
  ButtonDevice* = enum
    MixerDevice = "mixer", DeckDevice = "deck"
  ConfiguredAction* = object
    kind*: ConfigActionKind
    command*, menu*, operation*: string
    target*: ButtonTarget
  ConfiguredButton* = object
    key*: int
    title*: string
    action*: ConfiguredAction
    explicit*: bool
  ConfiguredMenu* = object
    id*, title*: string
    mixer*: array[12, ConfiguredButton]
    deck*: array[15, ConfiguredButton]
  ButtonSet* = object
    root*: string
    menus*: seq[ConfiguredMenu]
  ButtonPaths* = object
    configDir*, stateDir*: string

const
  ButtonConfigVersion* = 1
  MixerKeyCount* = 12
  DeckKeyCount* = 15
  MaxMenus* = 64
  MaxIdBytes* = 64
  MaxTitleRunes* = 64
  MaxCommandBytes* = 4096
  MaxConfigBytes* = 512 * 1024
  MaxAssetNameBytes = 128
  DrawerKeyCount* = 5
  RootMenuId* = "root"
  RootMenuTitle = "Main"
  BackTitle* = "Back"
  UnassignedTitle* = "Unassigned"
  ConfigFileName = "buttons.json"
  InvalidBackupName = "buttons.invalid.json"
  AssetDirectoryName = "assets"
  LastAppliedVersion = 1
  ConfigKeys = ["version", "root", "menus"]
  MenuKeys = ["id", "title", "mixer", "deck"]
  MixerEntryKeys = ["key", "title", "action"]
  DeckEntryKeys = ["key", "title", "action", "visual"]
  VisualKeys = ["image", "showTitle", "builtinNumber", "states"]
  ActionFields = ["command", "menu", "target", "operation"]
  NamedActionKinds* = {GrokAction, ClaudeAction, FfxivAction, MicrophonesAction, DiscordAction,
    DiscordDeafenAction, OpenDiscordAction, MixerOverlayAction,
    DiscordAcceptVoiceAction, DiscordAcceptVideoAction}
  Sha256Initial = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  Sha256Rounds = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32,
    0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32, 0xd807aa98'u32, 0x12835b01'u32,
    0x243185be'u32, 0x550c7dc3'u32, 0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32,
    0xc19bf174'u32, 0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32, 0x983e5152'u32,
    0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32,
    0x06ca6351'u32, 0x14292967'u32, 0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32,
    0x53380d13'u32, 0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32,
    0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32, 0x19a4c116'u32, 0x1e376c08'u32,
    0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32,
    0x682e6ff3'u32, 0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc sha256Hex*(data: string): string =
  ## Return the lowercase hexadecimal SHA-256 digest of a byte string.
  var
    state = Sha256Initial
    message = data
    words: array[64, uint32]
  let bitLength = uint64(data.len) * 8
  message.add('\x80')
  while message.len mod 64 != 56:
    message.add('\0')
  for shift in countdown(56, 0, 8):
    message.add(char((bitLength shr shift) and 0xff))
  proc rotr(value: uint32, count: int): uint32 = (value shr count) or (value shl (32 - count))
  for chunk in countup(0, message.len - 1, 64):
    for index in 0..15:
      let offset = chunk + index * 4
      words[index] = (uint32(ord(message[offset])) shl 24) or
        (uint32(ord(message[offset + 1])) shl 16) or
        (uint32(ord(message[offset + 2])) shl 8) or uint32(ord(message[offset + 3]))
    for index in 16..63:
      let
        s0 = rotr(words[index - 15], 7) xor rotr(words[index - 15], 18) xor (words[index - 15] shr 3)
        s1 = rotr(words[index - 2], 17) xor rotr(words[index - 2], 19) xor (words[index - 2] shr 10)
      words[index] = words[index - 16] + s0 + words[index - 7] + s1
    var work = state
    for index in 0..63:
      let
        sum1 = rotr(work[4], 6) xor rotr(work[4], 11) xor rotr(work[4], 25)
        choice = (work[4] and work[5]) xor ((not work[4]) and work[6])
        first = work[7] + sum1 + choice + Sha256Rounds[index] + words[index]
        sum0 = rotr(work[0], 2) xor rotr(work[0], 13) xor rotr(work[0], 22)
        majority = (work[0] and work[1]) xor (work[0] and work[2]) xor (work[1] and work[2])
        second = sum0 + majority
      for shifted in countdown(7, 1):
        work[shifted] = work[shifted - 1]
      work[4] += first
      work[0] = first + second
    for index in 0..7:
      state[index] += work[index]
  for value in state:
    result.add(toHex(value, 8).toLowerAscii())

proc configError(field, reason: string): ref ButtonConfigError =
  ## Build a validation error whose message and metadata both name the field.
  result = newException(ButtonConfigError,
    (if field.len > 0: field & ": " else: "") & reason)
  result.field = field

proc join(path, child: string): string =
  ## Extend a JSON field path with an object member name.
  if path.len == 0: child else: path & "." & child

proc requireObject(node: JsonNode, field: string, allowed: openArray[string]) =
  ## Require a JSON object without unknown members, so misspelled fields are reported.
  if node.isNil or node.kind != JObject:
    raise configError(field, "Expected an object.")
  for key in node.keys:
    if key notin allowed:
      raise configError(join(field, key), "Unknown field.")

proc requireMember(node: JsonNode, name, field: string, kind: JsonNodeKind): JsonNode =
  ## Return a required member of the expected JSON kind.
  if not node.hasKey(name):
    raise configError(join(field, name), "Missing required field.")
  result = node[name]
  if result.kind != kind:
    raise configError(join(field, name), "Expected " & ($kind)[1..^1].toLowerAscii() & ".")

proc optionalString(node: JsonNode, name, field: string): string =
  ## Return an optional string member, defaulting to empty.
  if node.hasKey(name):
    result = requireMember(node, name, field, JString).getStr()

proc validateId(id, field: string) =
  ## Require a stable ASCII identifier suitable for file names and references.
  if id.len == 0 or id.len > MaxIdBytes:
    raise configError(field, "Identifier must be 1 to " & $MaxIdBytes & " characters.")
  for character in id:
    if character notin {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}:
      raise configError(field, "Identifier may only use ASCII letters, digits, '_' and '-'.")

proc validateTitle(title, field: string) =
  ## Accept any valid UTF-8 text without control characters, within the display limit.
  if validateUtf8(title) >= 0:
    raise configError(field, "Title must be valid UTF-8.")
  var count = 0
  for rune in title.runes:
    let code = int32(rune)
    if code < 0x20 or code in 0x7f'i32..0x9f'i32:
      raise configError(field, "Title must not contain control characters.")
    inc count
  if count > MaxTitleRunes:
    raise configError(field, "Title must be at most " & $MaxTitleRunes & " characters.")

proc isManagedAssetPath*(path: string): bool =
  ## Report whether a path names one file directly inside the managed assets directory.
  let prefix = AssetDirectoryName & "/"
  if not path.startsWith(prefix):
    return false
  let name = path[prefix.len..^1]
  result = name.len in 1..MaxAssetNameBytes and name[0] != '.'
  for character in name:
    if character notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-'}:
      result = false

proc parseAction(node: JsonNode, field: string, menuIds: HashSet[string]): ConfiguredAction =
  ## Validate one action object and keep only the fields its kind uses.
  requireObject(node, field, @["kind"] & @ActionFields)
  let kindText = requireMember(node, "kind", field, JString).getStr()
  try:
    result.kind = parseEnum[ConfigActionKind](kindText)
  except ValueError:
    raise configError(join(field, "kind"), "Unknown action kind: " & kindText)
  for name in ActionFields:
    let used = (name == "command" and result.kind == CommandAction) or
      (name == "menu" and result.kind == DeckMenuAction) or
      (name in ["menu", "target"] and result.kind == MenuAction) or
      (name == "operation" and result.kind == ObsAction)
    if node.hasKey(name) and not used:
      raise configError(join(field, name), "Field is not used by action kind " & kindText & ".")
  case result.kind
  of CommandAction:
    result.command = requireMember(node, "command", field, JString).getStr()
    if result.command.strip().len == 0:
      raise configError(join(field, "command"), "Command must not be empty.")
    if result.command.len > MaxCommandBytes:
      raise configError(join(field, "command"), "Command must be at most " & $MaxCommandBytes & " bytes.")
    if '\0' in result.command or validateUtf8(result.command) >= 0:
      raise configError(join(field, "command"), "Command must be valid UTF-8 without NUL bytes.")
  of MenuAction:
    result.menu = requireMember(node, "menu", field, JString).getStr()
    if result.menu notin menuIds:
      raise configError(join(field, "menu"), "Unknown menu: " & result.menu)
    let targetText = requireMember(node, "target", field, JString).getStr()
    try:
      result.target = parseEnum[ButtonTarget](targetText)
    except ValueError:
      raise configError(join(field, "target"), "Target must be mixer, deck, or both.")
  of DeckMenuAction:
    result.menu = requireMember(node, "menu", field, JString).getStr()
    if result.menu notin menuIds:
      raise configError(join(field, "menu"), "Unknown menu: " & result.menu)
  of ObsAction:
    result.operation = requireMember(node, "operation", field, JString).getStr()
    if not isObsOperation(result.operation):
      raise configError(join(field, "operation"), "OBS operation must be one of " &
        ObsOperations.join(", ") & ".")
  else:
    discard

proc parseEntries(menu: JsonNode, device: ButtonDevice, field, rootId: string,
    menuIds: HashSet[string], buttons: var openArray[ConfiguredButton]) =
  ## Validate one device's sparse entry list into a complete fixed-size slot array.
  let
    isRoot = menu["id"].getStr() == rootId
    name = $device
    listField = join(field, name)
    allowed = if device == MixerDevice: @MixerEntryKeys else: @DeckEntryKeys
  for index in 0..buttons.high:
    buttons[index] = ConfiguredButton(key: index + 1, title: UnassignedTitle)
  if not isRoot:
    buttons[0] = ConfiguredButton(key: 1, title: BackTitle,
      action: ConfiguredAction(kind: BackAction))
  if not menu.hasKey(name):
    return
  let entries = requireMember(menu, name, field, JArray)
  for position, entry in entries.elems:
    let entryField = listField & "[" & $position & "]"
    requireObject(entry, entryField, allowed)
    let key = requireMember(entry, "key", entryField, JInt).getBiggestInt()
    if key notin 1'i64..int64(buttons.len):
      raise configError(join(entryField, "key"), "Key must be 1 to " & $buttons.len & ".")
    if buttons[key - 1].explicit:
      raise configError(join(entryField, "key"), "Duplicate key " & $key & ".")
    let title = optionalString(entry, "title", entryField)
    validateTitle(title, join(entryField, "title"))
    let action = parseAction(requireMember(entry, "action", entryField, JObject),
      join(entryField, "action"), menuIds)
    let deckHome = device == DeckDevice and action.kind == MenuAction and
      action.menu == rootId and action.target == TargetDeck
    if action.kind == DeckMenuAction and (device != DeckDevice or key != 1):
      raise configError(join(entryField, "action"), "Only Stream Deck key 1 can open a menu drawer.")
    if not isRoot and key == 1 and action.kind notin {BackAction, DeckMenuAction} and not deckHome:
      raise configError(join(entryField, "action"),
        "Key 1 of a submenu must be Back, a menu drawer, or a Deck-only link to Home on the Deck.")
    if entry.hasKey("visual"):
      let visualField = join(entryField, "visual")
      let visual = entry["visual"]
      requireObject(visual, visualField, VisualKeys)
      let image = optionalString(visual, "image", visualField)
      if visual.hasKey("image") and not isManagedAssetPath(image):
        raise configError(join(visualField, "image"),
          "Image must be a managed file path such as assets/<name>.png.")
      if visual.hasKey("showTitle"):
        discard requireMember(visual, "showTitle", visualField, JBool)
      if visual.hasKey("builtinNumber"):
        let number = requireMember(visual, "builtinNumber", visualField, JInt).getBiggestInt()
        if number notin 1'i64..int64(DeckKeyCount):
          raise configError(join(visualField, "builtinNumber"), "Built-in number must be 1 to 15.")
        if visual.hasKey("image"):
          raise configError(join(visualField, "builtinNumber"),
            "Use either an image or a built-in number, not both.")
      if visual.hasKey("states"):
        let statesField = join(visualField, "states")
        requireObject(visual["states"], statesField, VisualStates)
        for state in VisualStates:
          if visual["states"].hasKey(state) and
              not isManagedAssetPath(requireMember(visual["states"], state, statesField, JString).getStr()):
            raise configError(join(statesField, state),
              "State image must be a managed file path such as assets/<name>.png.")
    buttons[key - 1] = ConfiguredButton(key: int(key), title: title, action: action, explicit: true)

proc validateDrawerMenu(buttons: ButtonSet, id: string) =
  ## Require a drawer menu to cancel itself on key 1 and offer only Deck-only menu links on keys 2 to 5,
  ## so opening or using the drawer can never run an application action.
  for position, menu in buttons.menus:
    if menu.id == id:
      let field = "menus[" & $position & "].deck"
      if menu.deck[0].action.kind != DeckMenuAction or menu.deck[0].action.menu != id:
        raise configError(field, "Deck key 1 of drawer menu " & id & " must open drawer " & id & ".")
      for index in 1..<DrawerKeyCount:
        let action = menu.deck[index].action
        if action.kind != NoAction and (action.kind != MenuAction or action.target != TargetDeck):
          raise configError(field, "Deck key " & $(index + 1) & " of drawer menu " & id &
            " must be unassigned or a Deck-only menu link.")

proc parseButtonSet*(config: JsonNode): ButtonSet =
  ## Validate a configuration and convert it to the typed, reference-free routing model.
  requireObject(config, "", ConfigKeys)
  let version = requireMember(config, "version", "", JInt).getBiggestInt()
  if version != ButtonConfigVersion:
    raise configError("version", "Unsupported configuration version " & $version & ".")
  result.root = requireMember(config, "root", "", JString).getStr()
  let menus = requireMember(config, "menus", "", JArray)
  if menus.len == 0 or menus.len > MaxMenus:
    raise configError("menus", "Configuration needs 1 to " & $MaxMenus & " menus.")
  var menuIds: HashSet[string]
  for position, menu in menus.elems:
    let field = "menus[" & $position & "]"
    requireObject(menu, field, MenuKeys)
    let id = requireMember(menu, "id", field, JString).getStr()
    validateId(id, join(field, "id"))
    if id in menuIds:
      raise configError(join(field, "id"), "Duplicate menu id: " & id)
    menuIds.incl(id)
  if result.root notin menuIds:
    raise configError("root", "Root menu does not exist: " & result.root)
  for position, menu in menus.elems:
    let field = "menus[" & $position & "]"
    var parsed = ConfiguredMenu(id: menu["id"].getStr(),
      title: optionalString(menu, "title", field))
    validateTitle(parsed.title, join(field, "title"))
    parseEntries(menu, MixerDevice, field, result.root, menuIds, parsed.mixer)
    parseEntries(menu, DeckDevice, field, result.root, menuIds, parsed.deck)
    result.menus.add(parsed)
  for menu in result.menus:
    if menu.deck[0].action.kind == DeckMenuAction:
      validateDrawerMenu(result, menu.deck[0].action.menu)

proc actionJson*(action: ConfiguredAction): JsonNode =
  ## Encode an action with only the fields its kind uses, in canonical order.
  result = %*{"kind": $action.kind}
  case action.kind
  of CommandAction: result["command"] = %action.command
  of MenuAction:
    result["menu"] = %action.menu
    result["target"] = %($action.target)
  of DeckMenuAction: result["menu"] = %action.menu
  of ObsAction: result["operation"] = %action.operation
  else: discard

proc canonicalEntry(entry: JsonNode, button: ConfiguredButton, device: ButtonDevice): JsonNode =
  ## Encode one explicit entry deterministically, materializing the title display default.
  result = %*{"key": button.key, "title": button.title, "action": actionJson(button.action)}
  if device == DeckDevice and entry.hasKey("visual"):
    let source = entry["visual"]
    var visual = newJObject()
    if source.hasKey("image"):
      visual["image"] = source["image"]
    if source.hasKey("builtinNumber"):
      visual["builtinNumber"] = source["builtinNumber"]
    visual["showTitle"] = %(if source.hasKey("showTitle"): source["showTitle"].getBool()
      else: not source.hasKey("image"))
    if source.hasKey("states") and source["states"].len > 0:
      var states = newJObject()
      for state in VisualStates:
        if source["states"].hasKey(state):
          states[state] = source["states"][state]
      visual["states"] = states
    result["visual"] = visual

proc canonicalEntries(menu: JsonNode, device: ButtonDevice, buttons: openArray[ConfiguredButton]): JsonNode =
  ## Encode explicit entries sorted by key.
  result = newJArray()
  if menu.hasKey($device):
    var entries = menu[$device].elems
    entries.sort(proc (a, b: JsonNode): int = cmp(a["key"].getInt(), b["key"].getInt()))
    for entry in entries:
      result.add(canonicalEntry(entry, buttons[entry["key"].getInt() - 1], device))

proc canonicalButtonConfig*(config: JsonNode): JsonNode =
  ## Validate and return a deterministic copy used for persistence, envelopes, and revisions.
  let parsed = parseButtonSet(config)
  result = %*{"version": ButtonConfigVersion, "root": parsed.root, "menus": []}
  for position, menu in config["menus"].elems:
    let typed = parsed.menus[position]
    result["menus"].add(%*{"id": typed.id, "title": typed.title,
      "mixer": canonicalEntries(menu, MixerDevice, typed.mixer),
      "deck": canonicalEntries(menu, DeckDevice, typed.deck)})
  if ($result).len > MaxConfigBytes:
    raise configError("", "Configuration exceeds " & $MaxConfigBytes & " bytes.")

proc validateButtonConfig*(config: JsonNode) =
  ## Raise ButtonConfigError, naming the offending field, when a configuration is invalid.
  discard canonicalButtonConfig(config)

proc configRevision*(config: JsonNode): string =
  ## Return an opaque digest that is stable across formatting and entry order.
  sha256Hex($canonicalButtonConfig(config))

proc configEnvelope*(config: JsonNode): JsonNode =
  ## Wrap a configuration with the revision an edit must be based on.
  let canonical = canonicalButtonConfig(config)
  %*{"baseRevision": sha256Hex($canonical), "config": canonical}

proc parseConfigEnvelope*(node: JsonNode): tuple[baseRevision: string, config: JsonNode] =
  ## Validate an export or draft envelope's shape; the configuration is validated separately.
  requireObject(node, "", ["baseRevision", "config"])
  result.baseRevision = requireMember(node, "baseRevision", "", JString).getStr()
  if result.baseRevision.len == 0:
    raise configError("baseRevision", "Base revision must not be empty.")
  result.config = requireMember(node, "config", "", JObject)

proc defaultButtonConfig*(): JsonNode =
  ## Describe the compiled desktop bindings and numbered Stream Deck page as editable JSON.
  var mixer = newJArray()
  for binding in ButtonBindings:
    let kind = case binding.action
      of OpenGrok: GrokAction
      of OpenClaude: ClaudeAction
      of LaunchFfxiv: FfxivAction
      of ToggleMicrophones: MicrophonesAction
      of ToggleDiscord: DiscordAction
      of Unassigned: NoAction
    mixer.add(%*{"key": binding.note, "title": binding.label, "action": {"kind": $kind}})
  var deck = newJArray()
  for key in 1..DeckKeyCount:
    deck.add(%*{"key": key, "title": $key, "action": {"kind": $NoAction},
      "visual": {"builtinNumber": key, "showTitle": false}})
  canonicalButtonConfig(%*{"version": ButtonConfigVersion, "root": RootMenuId,
    "menus": [{"id": RootMenuId, "title": RootMenuTitle, "mixer": mixer, "deck": deck}]})

proc menuAt*(config: JsonNode, id: string): JsonNode =
  ## Return the canonical stored menu object, without filled slots.
  for menu in canonicalButtonConfig(config)["menus"]:
    if menu["id"].getStr() == id:
      return menu
  raise configError("menus", "Unknown menu: " & id)

proc buttonAt*(config: JsonNode, menu: string, device: string, key: int): JsonNode =
  ## Return the effective entry for a slot, filling non-root Back and unassigned slots.
  let parsedDevice = try: parseEnum[ButtonDevice](device)
    except ValueError: raise configError("", "Device must be mixer or deck.")
  let stored = menuAt(config, menu)
  let count = if parsedDevice == MixerDevice: MixerKeyCount else: DeckKeyCount
  if key notin 1..count:
    raise configError("", "Key must be 1 to " & $count & ".")
  for entry in stored[device]:
    if entry["key"].getInt() == key:
      return entry
  let parsed = parseButtonSet(config)
  for typed in parsed.menus:
    if typed.id == menu:
      let button = if parsedDevice == MixerDevice: typed.mixer[key - 1] else: typed.deck[key - 1]
      result = %*{"key": key, "title": button.title, "action": actionJson(button.action)}

proc namedActionDescription*(kind: ConfigActionKind): string =
  ## Describe a named action that has no compiled default binding.
  case kind
  of DiscordDeafenAction: "Toggle Discord deafen through local RPC."
  of OpenDiscordAction: "Open or focus Discord."
  of DiscordAcceptVoiceAction: "Answer an incoming Discord call with voice."
  of DiscordAcceptVideoAction: "Answer an incoming Discord call with video."
  of MixerOverlayAction: "Show the mixer overlay."
  else: ""

proc isQueuedAction*(kind: ConfigActionKind): bool =
  ## Report whether an action runs on the action worker rather than navigating.
  kind in {CommandAction, ObsAction} or kind in NamedActionKinds

proc encodeLastApplied*(config: JsonNode): string =
  ## Encode the recovery record for the configuration most recently applied.
  let canonical = canonicalButtonConfig(config)
  pretty(%*{"version": LastAppliedVersion, "revision": sha256Hex($canonical),
    "config": canonical}) & "\n"

proc decodeLastApplied*(text: string): JsonNode =
  ## Decode a recovery record, rejecting unsupported or internally inconsistent files.
  let node = parseJson(text)
  if node.kind != JObject or node{"version"}.getInt(-1) != LastAppliedVersion or
      node{"config"}.isNil or node{"revision"}.isNil:
    raise configError("", "Unsupported last-applied record.")
  if configRevision(node["config"]) != node["revision"].getStr():
    raise configError("revision", "Last-applied revision does not match its configuration.")
  result = node["config"]

proc encodeConfigFile*(config: JsonNode): string =
  ## Render the bare canonical configuration as human-editable JSON.
  pretty(canonicalButtonConfig(config)) & "\n"

proc xdgDirectory(variable, fallback: string): string =
  ## Resolve an XDG base directory, treating an empty variable as unset.
  let value = getEnv(variable)
  (if value.len == 0: getHomeDir() / fallback else: value) / "knobby"

proc buttonConfigDirectory*(): string =
  ## Locate the editable configuration directory.
  xdgDirectory("XDG_CONFIG_HOME", ".config")

proc buttonStateDirectory*(): string =
  ## Locate prepared media, recovery records, and drafts.
  xdgDirectory("XDG_STATE_HOME", ".local/state")

proc buttonConfigPath*(): string =
  ## Locate the canonical bare configuration file.
  buttonConfigDirectory() / ConfigFileName

proc newButtonPaths*(configDir = buttonConfigDirectory(), stateDir = buttonStateDirectory()): ButtonPaths =
  ## Describe configuration and state locations; tests pass temporary directories.
  ButtonPaths(configDir: configDir, stateDir: stateDir)

proc configPath*(paths: ButtonPaths): string =
  ## Return the canonical configuration file.
  paths.configDir / ConfigFileName

proc invalidBackupPath*(paths: ButtonPaths): string =
  ## Return where replaced, unapplied disk content is preserved.
  paths.configDir / InvalidBackupName

proc assetDirectory*(paths: ButtonPaths): string =
  ## Return the immutable, content-addressed source asset directory.
  paths.configDir / AssetDirectoryName

proc preparedDirectory*(paths: ButtonPaths): string =
  ## Return the media preparation cache directory.
  paths.stateDir / "prepared"

proc manifestDirectory*(paths: ButtonPaths): string =
  ## Return the directory of revision-addressed prepared manifests.
  paths.stateDir / "manifests"

proc lastAppliedPath*(paths: ButtonPaths): string =
  ## Return the recovery record of the last applied configuration.
  paths.stateDir / "last-applied.json"

proc guiDraftPath*(paths: ButtonPaths): string =
  ## Return the GUI's retained draft envelope.
  paths.stateDir / "gui-draft.json"

proc writeFileAtomic*(path, content: string) =
  ## Replace a file through a synced temporary file in the same directory.
  createDir(path.parentDir())
  let temporary = path & ".tmp-" & $getCurrentProcessId()
  try:
    var file = open(temporary, fmWrite)
    try:
      file.write(content)
      file.flushFile()
      if fsync(getOsFileHandle(file)) != 0:
        raiseOSError(osLastError(), temporary)
    finally:
      file.close()
    moveFile(temporary, path)
  except CatchableError:
    if fileExists(temporary):
      removeFile(temporary)
    raise

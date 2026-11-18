import
  std/[json, os, unittest],
  knobby/[button_config, button_runtime, daemon_workers, ipc, midi_events, overlay_state]

const
  StartMs = 1_000_000'i64
  HelpKey = 3

var directoryCounter: int

proc fakePrepare(config: JsonNode): JsonNode {.gcsafe.} =
  ## Return a hardware-free manifest for every configured menu.
  result = %*{"version": 1, "menus": {}}
  for menu in config["menus"]:
    var keys = newJObject()
    for key in 1..DeckKeyCount:
      keys[$key] = %*{"builtinNumber": key}
    result["menus"][menu["id"].getStr()] = keys

proc fakeImport(source: string): string {.gcsafe.} =
  ## Refuse imports, which these tests never request.
  raise newException(IOError, "Imports are not used by overlay tests.")

proc overlayConfig(helpKind: string): JsonNode =
  ## Describe a root menu with a help key, a command, an unassigned key, and a submenu.
  %*{"version": 1, "root": "root", "menus": [
    {"id": "root", "title": "Main",
      "mixer": [
        {"key": HelpKey, "title": "Help", "action": {"kind": helpKind}},
        {"key": 5, "title": "Echo", "action": {"kind": "command", "command": "echo mixer"}},
        {"key": 6, "title": "Tools", "action": {"kind": "menu", "menu": "tools", "target": "mixer"}}],
      "deck": [
        {"key": 4, "title": "Deck echo", "action": {"kind": "command", "command": "echo deck"}}]},
    {"id": "tools", "title": "Tools",
      "mixer": [{"key": 2, "title": "Tool", "action": {"kind": "grok"}}],
      "deck": []}]}

proc start(config: JsonNode): ButtonPaths =
  ## Initialize the runtime from a private canonical configuration file.
  inc directoryCounter
  let root = getTempDir() / ("knobby-overlay-" & $getCurrentProcessId() & "-" & $directoryCounter)
  removeDir(root)
  result = newButtonPaths(root / "config", root / "state")
  createDir(result.configDir)
  createDir(result.stateDir)
  writeFileAtomic(result.configPath(), encodeConfigFile(config))
  initializeButtons(result, ButtonServices(prepare: fakePrepare, importAsset: fakeImport))

proc finish(paths: ButtonPaths) =
  ## Delete one test's private directories.
  removeDir(paths.configDir.parentDir())

proc overlay(): JsonNode =
  ## Read the overlay member that the daemon publishes in its status.
  buttonRuntimeStatus()["overlay"]

proc showing(): bool =
  ## Report whether the published overlay is visible now.
  overlay()["visible"].getBool()

proc readyDeck() =
  ## Act as the Deck player and accept input for the current page.
  discard readDeckPage(0)
  deckPageReady()

proc kinds(actions: seq[JsonNode]): seq[string] =
  ## Extract captured action kinds in order.
  for action in actions:
    result.add(action["action"]["kind"].getStr())

suite "Overlay request state":
  test "help shows for ten seconds and expires without replay":
    var request: OverlayRequest
    check not request.visible(StartMs)
    request.press(true, StartMs)
    check request.visible(StartMs)
    check request.expiresAtMs == StartMs + MixerOverlayDurationMs
    check request.visible(StartMs + MixerOverlayDurationMs - 1)
    check not request.visible(StartMs + MixerOverlayDurationMs)
    let expired = request.toJson(StartMs + MixerOverlayDurationMs + 5000)
    check not expired["visible"].getBool()
    check expired["expiresAtMs"].getBiggestInt() == 0

  test "help toggles closed and reopens with a fresh deadline":
    var request: OverlayRequest
    request.press(true, StartMs)
    let first = request.sequence
    request.press(true, StartMs + 7000)
    check request.expiresAtMs == 0
    check request.sequence == first + 1
    check not request.visible(StartMs + 7000)
    request.press(true, StartMs + 8000)
    check request.expiresAtMs == StartMs + 8000 + MixerOverlayDurationMs
    check request.sequence == first + 2
    check request.visible(StartMs + 12000)
    request.press(true, StartMs + 30000)
    check request.visible(StartMs + 30000)

  test "other presses dismiss, while presses with nothing showing change nothing":
    var request: OverlayRequest
    request.press(false, StartMs)
    check request.sequence == 0
    request.press(true, StartMs)
    request.press(false, StartMs + 10)
    check not request.visible(StartMs + 10)
    let dismissed = request.sequence
    request.press(false, StartMs + 20)
    check request.sequence == dismissed
    request.press(true, StartMs)
    request.press(false, StartMs + MixerOverlayDurationMs + 1)
    check request.expiresAtMs == StartMs + MixerOverlayDurationMs

  test "status JSON uses the host monotonic deadline":
    var request: OverlayRequest
    request.press(true, StartMs)
    let encoded = request.toJson(StartMs + 1)
    check encoded["visible"].getBool()
    check encoded["expiresAtMs"].getBiggestInt() == StartMs + MixerOverlayDurationMs
    check encoded["durationMs"].getBiggestInt() == MixerOverlayDurationMs
    check encoded["sequence"].getBiggestInt() == 1

suite "Overlay button routing":
  test "fresh mixer and Deck presses dismiss and still run their action once":
    let paths = start(overlayConfig("none"))
    defer: finish(paths)
    check overlay() == %*{"visible": false, "expiresAtMs": 0,
      "durationMs": MixerOverlayDurationMs, "sequence": 0}
    pressMixerOverlay(true)
    check showing()
    check overlay()["expiresAtMs"].getBiggestInt() > monotonicMs()
    routeMixerButton(5, true)
    check not showing()
    check kinds(takeButtonActions()) == @["command"]
    routeMixerButton(5, false)
    pressMixerOverlay(true)
    readyDeck()
    routeDeckButton(3, true)
    check not showing()
    let deckActions = takeButtonActions()
    check kinds(deckActions) == @["command"]
    check deckActions[0]["device"].getStr() == "deck"
    routeDeckButton(3, false)

  test "unassigned keys, menu keys, and unready Deck presses dismiss":
    let paths = start(overlayConfig("none"))
    defer: finish(paths)
    pressMixerOverlay(true)
    routeMixerButton(1, true)
    check not showing()
    check takeButtonActions().len == 0
    routeMixerButton(1, false)
    pressMixerOverlay(true)
    routeMixerButton(6, true)
    check not showing()
    check buttonRuntimeStatus()["mixerMenu"].getStr() == "tools"
    routeMixerButton(6, false)
    pressMixerOverlay(true)
    routeDeckButton(9, true)
    check not showing()
    check takeButtonActions().len == 0

  test "releases, held repeats, faders, and out-of-range notes do not dismiss":
    let paths = start(overlayConfig("none"))
    defer: finish(paths)
    routeMixerButton(5, true)
    discard takeButtonActions()
    pressMixerOverlay(true)
    let sequence = overlay()["sequence"].getBiggestInt()
    routeMixerButton(5, true)
    routeMixerButton(5, false)
    routeMixerButton(13, true)
    routeMixerButton(0, true)
    queueActions([MidiEvent(kind: ControlChange, controller: 16, value: 40),
      MidiEvent(kind: ControlChange, controller: 19, value: 127),
      MidiEvent(kind: NoteOff, note: 7, velocity: 0),
      MidiEvent(kind: NoteOn, note: 7, velocity: 0)])
    check showing()
    check overlay()["sequence"].getBiggestInt() == sequence
    check takeButtonActions().len == 0

  test "a fresh runtime start never replays an earlier request":
    let first = start(overlayConfig("none"))
    pressMixerOverlay(true)
    check showing()
    finish(first)
    let second = start(overlayConfig("none"))
    defer: finish(second)
    check not showing()
    check overlay()["sequence"].getBiggestInt() == 0

  when declared(MixerOverlayAction):
    test "the help key toggles only on fresh presses and ignores held repeats":
      let paths = start(overlayConfig("mixerOverlay"))
      defer: finish(paths)
      check activeMixerCatalog()["buttons"][HelpKey - 1]["label"].getStr() == "Help"
      routeMixerButton(HelpKey, true)
      check showing()
      let first = overlay()
      routeMixerButton(HelpKey, true)
      check overlay() == first
      routeMixerButton(HelpKey, false)
      sleep(5)
      routeMixerButton(HelpKey, true)
      check not showing()
      check overlay()["expiresAtMs"].getBiggestInt() == 0
      check overlay()["sequence"].getBiggestInt() == first["sequence"].getBiggestInt() + 1
      routeMixerButton(HelpKey, false)
      routeMixerButton(HelpKey, true)
      check showing()
      check overlay()["expiresAtMs"].getBiggestInt() > first["expiresAtMs"].getBiggestInt()
      routeMixerButton(HelpKey, false)
      check kinds(takeButtonActions()) == @["mixerOverlay", "mixerOverlay", "mixerOverlay"]
      routeMixerButton(5, true)
      check not showing()
      check kinds(takeButtonActions()) == @["command"]

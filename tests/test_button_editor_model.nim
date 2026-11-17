import
  std/[json, os, strutils, unittest],
  knobby/button_config,
  ../gui/app/src/button_editor_model

proc liveModel(config = defaultButtonConfig()): EditorModel =
  ## Load a canonical configuration the way the GUI receives it from config.get.
  result = newEditorModel()
  result.loadLive(configEnvelope(config))

proc withSubmenu(): JsonNode =
  ## Build a valid configuration whose root Deck key 5 opens a games submenu.
  result = defaultButtonConfig()
  result["menus"].add(%*{"id": "games", "title": "Games", "mixer": [], "deck": []})
  for entry in result["menus"][0]["deck"]:
    if entry["key"].getInt() == 5:
      entry["action"] = %*{"kind": "menu", "menu": "games", "target": "both"}

suite "Button editor model":
  test "loading live state starts clean and selection never edits":
    var model = liveModel()
    check model.loaded and not model.isDirty()
    model.selectDevice(DeckDevice)
    model.selectKey(15)
    check model.selected()["title"].getStr() == "15"
    check not model.isDirty()
    expect ValueError: model.selectKey(16)

  test "raw slot reads match the core buttonAt semantics":
    let config = canonicalButtonConfig(withSubmenu())
    for menu in ["root", "games"]:
      for device in ButtonDevice:
        for key in 1..device.keyCount():
          check config.entryAt(menu, device, key) == buttonAt(config, menu, $device, key)

  test "Unicode titles and commands edit the draft and validate through core":
    var model = liveModel()
    model.selectKey(3)
    model.setTitle("Música 🎵 日本")
    model.setActionKind(CommandAction)
    check model.validationField.endsWith("action.command")
    check not model.canApply()
    model.setCommand("notify-send hi")
    check model.validation == ""
    check model.isDirty() and model.canApply()
    check model.selected()["title"].getStr() == "Música 🎵 日本"
    check model.selected()["action"] == %*{"kind": "command", "command": "notify-send hi"}

  test "deck titles replace migrated numbered artwork and images default the overlay off":
    var model = liveModel()
    model.selectDevice(DeckDevice)
    model.selectKey(4)
    check model.selected()["visual"]["builtinNumber"].getInt() == 4
    model.setTitle("Lights")
    check not model.selected()["visual"].hasKey("builtinNumber")
    check model.selected().showsTitle()
    model.setImage("assets/abc123.png")
    check not model.selected().showsTitle()
    model.setShowTitle(true)
    check model.selected().showsTitle()
    model.clearImage()
    check not model.selected().hasImage() and model.selected().showsTitle()
    expect ValueError: model.setImage("/tmp/raw.png")
    model.selectDevice(MixerDevice)
    expect ValueError: model.setImage("assets/abc123.png")

  test "submenu key 1 is locked Back on both devices":
    var model = liveModel(withSubmenu())
    model.selectMenu("games")
    for device in ButtonDevice:
      model.selectDevice(device)
      model.selectKey(1)
      check model.selectedLocked()
      check model.selected().actionKind() == BackAction
      expect ValueError: model.setTitle("Nope")
      expect ValueError: model.setActionKind(GrokAction)
    model.selectMenu("root")
    model.selectKey(1)
    check not model.selectedLocked()
    model.setActionKind(GrokAction)
    check model.validation == ""

  test "menus can be created, renamed, targeted, and deleted only when unreferenced":
    var model = liveModel()
    let id = model.createMenu("Spiele ✓")
    check id == "spiele"
    check model.menu == id
    check model.createMenu("Spiele") == "spiele-2"
    model.renameMenu(id, "Spiele 🎮")
    check model.draft.menuTitle(id) == "Spiele 🎮"
    check model.draft.findMenu(id)["id"].getStr() == "spiele"
    model.selectMenu("root")
    model.selectDevice(DeckDevice)
    model.selectKey(2)
    model.setActionKind(MenuAction)
    check model.selected()["action"]["menu"].getStr() == "spiele"
    model.setTargetDevice(TargetDeck)
    model.setMenuTarget("spiele-2")
    check model.selected().menuTarget() == TargetDeck
    check model.validation == ""
    expect ValueError: model.deleteMenu("spiele-2")
    expect ValueError: model.deleteMenu(RootMenuId)
    model.deleteMenu("spiele")
    check model.draft.findMenu("spiele").isNil
    check model.validation == ""

  test "local validation points at the offending slot":
    var model = liveModel()
    model.selectDevice(DeckDevice)
    model.selectKey(7)
    model.setActionKind(CommandAction)
    check model.slotHasProblem("root", DeckDevice, 7)
    check not model.slotHasProblem("root", DeckDevice, 8)
    check model.menuHasProblem("root")

  test "failed apply retains edits and stale revisions need explicit resolution":
    var model = liveModel()
    model.selectKey(2)
    model.setTitle("Draft")
    let draft = model.draft.copy()
    model.applyFailed("Media preparation failed.", "prepare", "")
    check model.draft == draft and model.isDirty()
    check model.conflict == NoConflict and model.problem() == "Media preparation failed."
    model.applyFailed("Configuration changed.", StaleCode, "")
    check model.conflict == StaleRevision and not model.canApply()
    var external = defaultButtonConfig()
    external["menus"][0]["title"] = %"Elsewhere"
    model.loadLive(configEnvelope(external))
    check model.draft == draft
    check model.liveRevision == configRevision(external)
    model.rebaseDraft()
    check model.conflict == NoConflict and model.baseRevision == configRevision(external)
    check model.canApply()
    model.applySucceeded(configRevision(model.draft))
    check not model.isDirty() and model.live == model.draft

  test "external live changes mark dirty drafts stale and leave clean drafts current":
    var model = liveModel()
    var external = defaultButtonConfig()
    external["menus"][0]["title"] = %"Elsewhere"
    model.loadLive(configEnvelope(external))
    check model.conflict == NoConflict and model.draft == canonicalButtonConfig(external)
    model.selectKey(2)
    model.setTitle("Mine")
    model.loadLive(configEnvelope(defaultButtonConfig()))
    check model.conflict == StaleRevision
    model.discardDraft()
    check not model.isDirty() and model.conflict == NoConflict

  test "drafts autosave atomically and recover against current or stale revisions":
    let directory = getTempDir() / "knobby-editor-model-test"
    removeDir(directory)
    defer: removeDir(directory)
    let path = directory / "knobby" / "gui-draft.json"
    check readDraft(path).isNil
    var model = liveModel()
    model.selectKey(6)
    model.setTitle("Recovered ✓")
    writeDraft(path, model.draftEnvelope())
    var restored = liveModel()
    restored.recoverDraft(readDraft(path))
    check restored.isDirty() and restored.conflict == NoConflict
    check restored.draft == model.draft
    check restored.notice.len > 0
    var external = defaultButtonConfig()
    external["menus"][0]["title"] = %"Elsewhere"
    var stale = liveModel(external)
    stale.recoverDraft(readDraft(path))
    check stale.conflict == StaleRevision and stale.draft == model.draft
    removeDraft(path)
    check not fileExists(path)
    writeFile(path, "[]")
    expect ValueError: discard readDraft(path)

  test "recovering a draft identical to live state is a no-op":
    var model = liveModel()
    model.recoverDraft(model.draftEnvelope())
    check not model.isDirty() and model.notice == ""

  test "menu IDs stay ASCII, bounded, and unique":
    let config = defaultButtonConfig()
    check config.menuIdFromTitle("日本語") == "menu"
    check config.menuIdFromTitle("Root") == "root-2"
    check config.menuIdFromTitle("  Hello, World!  ") == "hello-world"
    let long = config.menuIdFromTitle("x".repeat(200))
    check long.len <= MaxIdBytes

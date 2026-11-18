import
  std/[json, os, strutils, unittest],
  knobby/[button_config, obs_state],
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
    expect ValueError: model.applySucceeded(configRevision(model.draft))
    model.applySubmitted()
    model.applySucceeded(configRevision(model.draft))
    check not model.isDirty() and model.live == model.draft and model.submitted.isNil

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

  test "a root menu not named root keeps key 1 editable and locks Back elsewhere":
    let config = %*{"version": ButtonConfigVersion, "root": "top", "menus": [
      {"id": "top", "title": "Top", "mixer": [], "deck": [
        {"key": 2, "title": "Games", "action": {"kind": "menu", "menu": "games", "target": "both"}}]},
      {"id": "root", "title": "Not the root", "mixer": [], "deck": []},
      {"id": "games", "title": "Games", "mixer": [], "deck": []}]}
    var model = liveModel(config)
    check model.validation == "" and model.menu == "top"
    check not model.draft.isLockedBack("top", 1)
    for device in ButtonDevice:
      model.selectDevice(device)
      model.selectKey(1)
      check not model.selectedLocked()
      check model.selected().actionKind() == NoAction
    model.setTitle("Lights")
    model.setActionKind(GrokAction)
    check model.validation == "" and model.canApply()
    for menu in ["root", "games"]:
      model.selectMenu(menu)
      for device in ButtonDevice:
        model.selectDevice(device)
        model.selectKey(1)
        check model.selectedLocked()
        check model.selected().actionKind() == BackAction
        check model.draft.entryAt(menu, device, 1) == buttonAt(model.draft, menu, $device, 1)
        expect ValueError: model.setActionKind(HomeAction)
    expect ValueError: model.deleteMenu("top")
    model.deleteMenu("root")
    check model.validation == ""

  test "draft autosave counts edits saved only after the file operation succeeds":
    let
      directory = getTempDir() / "knobby-editor-autosave-test"
      blocker = directory / "knobby"
      path = blocker / "gui-draft.json"
    removeDir(directory)
    createDir(directory)
    defer: removeDir(directory)
    writeFile(blocker, "not a directory")
    var
      model = liveModel()
      saver = newDraftSaver(path)
    saver.markDraftSaved(model)
    model.selectKey(4)
    model.setTitle("Pending ✓")
    saver.autosaveDraft(model, 1_000)
    check saver.draftPending(model) and model.error == ""
    saver.autosaveDraft(model, 1_000 + DraftSaveDelayMs)
    check saver.draftPending(model)
    check model.error.startsWith("Draft autosave failed") and model.isDirty()
    check saver.retryMs == 1_000 + 2 * DraftSaveDelayMs
    saver.autosaveDraft(model, saver.retryMs - 1)
    check saver.draftPending(model)
    removeFile(blocker)
    saver.autosaveDraft(model, saver.retryMs)
    check not saver.draftPending(model) and model.error == ""
    check readDraft(path)["config"] == model.draft
    model.setTitle("Second")
    saver.autosaveDraft(model, 5_000, force = true)
    check not saver.draftPending(model)
    check readDraft(path)["config"] == model.draft
    setFilePermissions(blocker, {fpUserRead, fpUserExec})
    defer: setFilePermissions(blocker, {fpUserRead, fpUserWrite, fpUserExec})
    model.discardDraft()
    saver.autosaveDraft(model, 6_000, force = true)
    check saver.draftPending(model) and model.error.startsWith("Draft autosave failed")
    check fileExists(path)
    setFilePermissions(blocker, {fpUserRead, fpUserWrite, fpUserExec})
    saver.autosaveDraft(model, 6_000 + DraftSaveDelayMs - 1)
    check saver.draftPending(model)
    saver.autosaveDraft(model, 6_000 + DraftSaveDelayMs)
    check not saver.draftPending(model) and not fileExists(path) and model.error == ""

  test "edits made while an apply is pending survive success and are autosaved against it":
    let
      directory = getTempDir() / "knobby-editor-pending-apply-test"
      path = directory / "knobby" / "gui-draft.json"
    removeDir(directory)
    defer: removeDir(directory)
    var
      model = liveModel()
      saver = newDraftSaver(path)
    saver.markDraftSaved(model)
    model.selectKey(2)
    model.setTitle("Submitted ✓")
    let submitted = model.draftEnvelope().copy()
    model.applySubmitted()
    model.setTitle("Late 🎵")
    model.selectKey(3)
    model.setActionKind(CommandAction)
    model.setCommand("notify-send late")
    let late = model.draft.copy()
    saver.autosaveDraft(model, 1_000, force = true)
    check readDraft(path)["config"] == late
    let revision = configRevision(submitted["config"])
    model.applySucceeded(revision)
    model.loadLive(configEnvelope(submitted["config"]))
    check model.live == canonicalButtonConfig(submitted["config"])
    check model.live.entryAt(RootMenuId, MixerDevice, 2)["title"].getStr() == "Submitted ✓"
    check model.draft == late and model.isDirty() and model.canApply()
    check model.baseRevision == revision and model.liveRevision == revision
    check model.conflict == NoConflict and model.submitted.isNil
    saver.markDraftStale()
    saver.autosaveDraft(model, 2_000, force = true)
    let saved = readDraft(path)
    check saved["config"] == late and saved["baseRevision"].getStr() == revision
    var recovered = liveModel(submitted["config"])
    recovered.recoverDraft(saved)
    check recovered.draft == late and recovered.conflict == NoConflict and recovered.canApply()

  test "an apply without later edits leaves a clean draft and removes the draft file":
    let
      directory = getTempDir() / "knobby-editor-clean-apply-test"
      path = directory / "knobby" / "gui-draft.json"
    removeDir(directory)
    defer: removeDir(directory)
    var
      model = liveModel()
      saver = newDraftSaver(path)
    model.selectKey(5)
    model.setTitle("Only edit")
    saver.autosaveDraft(model, 0, force = true)
    check fileExists(path)
    model.applySubmitted()
    model.applySucceeded(configRevision(model.draft))
    check not model.isDirty() and model.draft == model.live
    saver.markDraftStale()
    saver.autosaveDraft(model, 1_000, force = true)
    check not fileExists(path)

  test "a successful apply whose reload failed adopts the submitted revision without conflict":
    var model = liveModel()
    model.selectKey(4)
    model.setTitle("Applied")
    let submitted = model.draft.copy()
    model.applySubmitted()
    model.setTitle("Later")
    let revision = configRevision(submitted)
    model.applySucceeded(revision)
    check model.live == canonicalButtonConfig(submitted)
    check model.liveRevision == revision and model.baseRevision == revision
    check model.conflict == NoConflict and model.error == ""
    check model.isDirty() and model.selected()["title"].getStr() == "Later"
    model.loadLive(configEnvelope(submitted))
    check model.conflict == NoConflict and model.canApply()
    model.discardDraft()
    check model.selected()["title"].getStr() == "Applied" and not model.isDirty()

  test "a failed apply keeps both submitted and later edits":
    var model = liveModel()
    let original = model.base.copy()
    model.selectKey(6)
    model.setTitle("Submitted")
    model.applySubmitted()
    model.selectKey(7)
    model.setTitle("Later")
    let draft = model.draft.copy()
    model.applyFailed("Media preparation failed.", "prepare", "")
    check model.draft == draft and model.isDirty() and model.submitted.isNil
    check model.base == original and model.conflict == NoConflict
    model.applySubmitted()
    model.applyFailed("Configuration changed.", StaleCode, "baseRevision")
    check model.draft == draft and model.conflict == StaleRevision

  test "prepared frames are read only up to the size bound":
    let directory = getTempDir() / "knobby-editor-prepared-test"
    removeDir(directory)
    createDir(directory)
    defer: removeDir(directory)
    let
      fits = directory / "fits.jpg"
      large = directory / "large.jpg"
    writeFile(fits, "x".repeat(MaxPreparedBytes))
    writeFile(large, "x".repeat(MaxPreparedBytes + 1))
    check readPreparedFrame(fits).len == MaxPreparedBytes
    expect ValueError: discard readPreparedFrame(large)
    expect IOError: discard readPreparedFrame(directory / "missing.jpg")
    writeFile(fits, "")
    check readPreparedFrame(fits) == ""

  test "OBS actions pick an operation and keep it across kind changes":
    var model = liveModel()
    model.selectDevice(DeckDevice)
    model.selectKey(6)
    model.setActionKind(ObsAction)
    check model.selected()["action"] == %*{"kind": "obs", "operation": "recordToggle"}
    check model.validation == "" and model.canApply()
    for operation in ObsOperations:
      model.setObsOperation(operation)
      check model.selected().obsOperation() == operation and model.validation == ""
    check model.draft.describeAction(model.selected()) == "OBS: Minecraft 1080p"
    expect ValueError: model.setObsOperation("startStream")
    model.setObsOperation("micToggle")
    model.setActionKind(CommandAction)
    check model.selected().obsOperation() == "" and not model.selected()["action"].hasKey("operation")
    expect ValueError: model.setObsOperation("open")
    model.setActionKind(ObsAction)
    check model.selected().obsOperation() == "recordToggle"

  test "state images edit visual.states and selecting a state never edits the draft":
    var model = liveModel()
    model.selectDevice(DeckDevice)
    model.selectKey(6)
    expect ValueError: model.selectVisualState("recording")
    model.setActionKind(ObsAction)
    model.setImage("assets/base.png")
    let edits = model.edits
    model.selectVisualState("recording")
    check model.visualState == "recording" and model.edits == edits
    expect ValueError: model.selectVisualState("muted")
    model.setImage("assets/rec.png", model.visualState)
    model.setImage("assets/off.png", "unavailable")
    check model.selected()["visual"]["image"].getStr() == "assets/base.png"
    check model.selected()["visual"]["states"] ==
      %*{"recording": "assets/rec.png", "unavailable": "assets/off.png"}
    check model.selected().stateImage("recording") == "assets/rec.png"
    check model.selected().stateImage(NormalState) == "assets/base.png"
    check model.validation == "" and model.canApply()
    expect ValueError: model.setImage("/tmp/raw.png", "paused")
    expect ValueError: model.setImage("assets/x.png", "streaming")
    let canonical = canonicalButtonConfig(model.draft)
    check canonical.entryAt(RootMenuId, DeckDevice, 6)["visual"]["states"] ==
      model.selected()["visual"]["states"]
    model.clearImage(NormalState)
    check not model.selected().hasImage() and model.selected()["visual"].hasKey("states")
    model.clearImage("recording")
    model.clearImage("unavailable")
    check not model.selected()["visual"].hasKey("states") and model.validation == ""

  test "the previewed state follows the selected key's operation":
    var model = liveModel()
    model.selectDevice(DeckDevice)
    model.selectKey(6)
    model.setActionKind(ObsAction)
    model.setObsOperation("micToggle")
    model.selectVisualState("muted")
    model.selectKey(7)
    check model.visualState == NormalState
    model.selectKey(6)
    model.selectVisualState("unavailable")
    model.setObsOperation("open")
    check model.visualState == "unavailable"
    model.setObsOperation("recordToggle")
    model.selectVisualState("paused")
    model.setActionKind(NoAction)
    check model.visualState == NormalState
    model.setActionKind(ObsAction)
    model.selectVisualState("recording")
    model.selectDevice(MixerDevice)
    check model.visualState == NormalState
    expect ValueError: model.selectVisualState("recording")

  test "OBS edits autosave, recover, and survive edits made while applying":
    let
      directory = getTempDir() / "knobby-editor-obs-draft-test"
      path = directory / "draft.json"
    removeDir(directory)
    createDir(directory)
    defer: removeDir(directory)
    var
      model = liveModel()
      saver = newDraftSaver(path)
    saver.markDraftSaved(model)
    model.selectDevice(DeckDevice)
    model.selectKey(6)
    model.setActionKind(ObsAction)
    model.setImage("assets/rec.png", "recording")
    model.applySubmitted()
    let submitted = model.submitted.copy()
    model.selectKey(7)
    model.setActionKind(ObsAction)
    model.setObsOperation("pauseToggle")
    model.setImage("assets/paused.png", "paused")
    model.applySucceeded(configRevision(canonicalButtonConfig(submitted)))
    saver.markDraftStale()
    saver.autosaveDraft(model, 1_000, force = true)
    let draft = readDraft(path)
    check not draft.isNil and draft["baseRevision"].getStr() == model.liveRevision
    check model.live.entryAt(RootMenuId, DeckDevice, 6)["visual"]["states"]["recording"].getStr() ==
      "assets/rec.png"
    check model.live.entryAt(RootMenuId, DeckDevice, 7).actionKind() != ObsAction
    var recovered = newEditorModel()
    recovered.loadLive(configEnvelope(model.live))
    recovered.recoverDraft(draft)
    check recovered.conflict == NoConflict and recovered.canApply()
    let late = recovered.draft.entryAt(RootMenuId, DeckDevice, 7)
    check late["action"] == %*{"kind": "obs", "operation": "pauseToggle"}
    check late["visual"]["states"] == %*{"paused": "assets/paused.png"}

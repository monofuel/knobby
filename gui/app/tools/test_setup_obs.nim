import
  std/[asyncdispatch, json, os, posix, strutils, tables, tempfiles],
  ws,
  obs_client, ./fake_obs, ./setup_obs

const
  MinecraftWindow = "4194307\r\nMinecraft* 1.21.4 - Singleplayer\r\nMinecraft* 1.21.4"
  BrowserWindow = "62914561\r\nMinecraft Wiki - Mozilla Firefox\r\nfirefox"
  MinecraftApp = "Minecraft* 1.21.4"
  DefaultScene = "Scene"
  UntitledName = "Untitled"
  NotFoundCode = 600
  UnknownRequestCode = 204
  AllKinds = ["xcomposite_input", "pipewire_audio_application_capture",
    "pulse_input_capture", "pulse_output_capture", "v4l2_input",
    "pipewire-screen-capture-source", "image_source"]
  MutatingRequests = ["CreateProfile", "SetCurrentProfile", "CreateSceneCollection",
    "SetCurrentSceneCollection", "SetVideoSettings", "CreateScene", "RemoveScene",
    "SetCurrentProgramScene", "CreateInput", "RemoveInput", "SetInputMute",
    "SetInputSettings", "CreateSceneItem", "SetSceneItemEnabled",
    "SetSceneItemTransform", "SetInputAudioTracks", "SetInputAudioMonitorType"]
  UntitledIni = "[General]\nName=Untitled\n\n[Output]\nMode=Simple\n"
  ProjectIni = "[General]\nName=Minecraft AI Demos\n\n[Video]\nBaseCX=1920\n" &
    "BaseCY=1080\nFPSType=2\n\n[AdvOut]\nEncoder=obs_x264\nRecFilePath=/old\n"

type
  FakeInput = object
    name, kind, monitor: string
    settings, tracks: JsonNode
    muted: bool

  FakeItem = object
    id: int
    source: string
    enabled: bool
    transform: JsonNode

  FakeCollection = ref object
    scenes: seq[string]
    program: string
    items: Table[string, seq[FakeItem]]
    inputs: seq[FakeInput]
    special: JsonNode

  SetupFake = ref object
    obs: FakeObs
    profiles: seq[string]
    profile: string
    collections: OrderedTable[string, FakeCollection]
    collection: string
    video: JsonNode
    recording, streaming: bool
    streamAfter: string
    nextItemId: int

proc emptySpecial(): JsonNode =
  ## Return GetSpecialInputs data with every global device disabled.
  %*{"desktop1": nil, "desktop2": nil, "mic1": nil, "mic2": nil, "mic3": nil,
    "mic4": nil}

proc newCollection(): FakeCollection =
  ## Return a collection as OBS creates it: one default scene, no inputs.
  FakeCollection(scenes: @[DefaultScene], program: DefaultScene,
    items: {DefaultScene: newSeq[FakeItem]()}.toTable, special: emptySpecial())

proc current(fake: SetupFake): FakeCollection =
  ## Return the active collection.
  fake.collections[fake.collection]

proc addInput(fake: SetupFake, collection: FakeCollection, scene, name,
    kind: string, settings = newJObject()) =
  ## Add an input and its scene item with OBS defaults.
  collection.inputs.add(FakeInput(name: name, kind: kind, settings: settings,
    monitor: "OBS_MONITORING_TYPE_NONE",
    tracks: %*{"1": true, "2": true, "3": true, "4": true, "5": true, "6": true}))
  inc fake.nextItemId
  collection.items.mgetOrPut(scene, @[]).add(FakeItem(id: fake.nextItemId,
    source: name, enabled: true, transform: %*{"positionX": 0.0,
    "positionY": 0.0, "rotation": 0.0, "alignment": 5,
    "boundsType": "OBS_BOUNDS_NONE", "boundsAlignment": 0, "boundsWidth": 0.0,
    "boundsHeight": 0.0, "cropLeft": 0, "cropRight": 0, "cropTop": 0,
    "cropBottom": 0, "scaleX": 1.0, "scaleY": 1.0}))

proc inputIndex(collection: FakeCollection, name: string): int =
  ## Return an input index, or -1.
  result = -1
  for index, input in collection.inputs:
    if input.name == name:
      return index

proc snapshot(collection: FakeCollection): string =
  ## Render a collection for before/after comparison.
  var items = newJObject()
  for scene, list in collection.items:
    var rendered = newJArray()
    for item in list:
      rendered.add(%*{"id": item.id, "source": item.source,
        "enabled": item.enabled, "transform": item.transform})
    items[scene] = rendered
  var inputs = newJArray()
  for input in collection.inputs:
    inputs.add(%*{"name": input.name, "kind": input.kind, "muted": input.muted,
      "settings": input.settings, "tracks": input.tracks, "monitor": input.monitor})
  $(%*{"scenes": collection.scenes, "program": collection.program,
    "items": items, "inputs": inputs, "special": collection.special})

proc handle(fake: SetupFake, requestType: string, data: JsonNode): tuple[
    data: JsonNode, code: int] =
  ## Apply one request to the fake OBS state; code 0 means success.
  let
    collection = fake.current
    inputName = data{"inputName"}.getStr()
    index = collection.inputIndex(inputName)
    sceneName = data{"sceneName"}.getStr()
  if requestType in ["GetInputSettings", "SetInputSettings", "RemoveInput",
      "SetInputMute", "GetInputAudioTracks", "SetInputAudioTracks",
      "GetInputAudioMonitorType", "SetInputAudioMonitorType",
      "GetInputPropertiesListPropertyItems"] and index < 0:
    return (nil, NotFoundCode)
  case requestType
  of "GetRecordStatus":
    result.data = %*{"outputActive": fake.recording, "outputPaused": false}
  of "GetStreamStatus":
    result.data = %*{"outputActive": fake.streaming}
  of "GetProfileList":
    result.data = %*{"currentProfileName": fake.profile, "profiles": fake.profiles}
  of "CreateProfile":
    fake.profiles.add(data{"profileName"}.getStr())
    fake.profile = data{"profileName"}.getStr()
    fake.video = %*{"fpsNumerator": 30, "fpsDenominator": 1, "baseWidth": 2560,
      "baseHeight": 1440, "outputWidth": 1280, "outputHeight": 720}
  of "SetCurrentProfile":
    fake.profile = data{"profileName"}.getStr()
  of "GetSceneCollectionList":
    var names: seq[string]
    for name in fake.collections.keys:
      names.add(name)
    result.data = %*{"currentSceneCollectionName": fake.collection,
      "sceneCollections": names}
  of "CreateSceneCollection":
    fake.collection = data{"sceneCollectionName"}.getStr()
    fake.collections[fake.collection] = newCollection()
  of "SetCurrentSceneCollection":
    fake.collection = data{"sceneCollectionName"}.getStr()
  of "GetVideoSettings":
    result.data = fake.video.copy()
  of "SetVideoSettings":
    fake.video = data.copy()
  of "GetSpecialInputs":
    result.data = collection.special
  of "GetInputKindList":
    result.data = %*{"inputKinds": AllKinds}
  of "GetSceneList":
    var scenes = newJArray()
    for scene in collection.scenes:
      scenes.add(%*{"sceneName": scene})
    result.data = %*{"currentProgramSceneName": collection.program, "scenes": scenes}
  of "CreateScene":
    collection.scenes.add(sceneName)
    collection.items[sceneName] = @[]
  of "SetCurrentProgramScene":
    collection.program = sceneName
  of "RemoveScene":
    doAssert collection.program != sceneName, "removed the program scene"
    collection.scenes.delete(collection.scenes.find(sceneName))
    collection.items.del(sceneName)
  of "GetInputList":
    var inputs = newJArray()
    for input in collection.inputs:
      inputs.add(%*{"inputName": input.name, "inputKind": input.kind})
    result.data = %*{"inputs": inputs}
  of "CreateInput":
    fake.addInput(collection, sceneName, inputName, data{"inputKind"}.getStr(),
      data{"inputSettings"}.copy())
    result.data = %*{"sceneItemId": fake.nextItemId}
  of "RemoveInput":
    collection.inputs.delete(index)
    for scene, list in collection.items.mpairs:
      var kept: seq[FakeItem]
      for item in list:
        if item.source != inputName:
          kept.add(item)
      list = kept
  of "SetInputMute":
    collection.inputs[index].muted = data{"inputMuted"}.getBool()
  of "GetInputSettings":
    result.data = %*{"inputSettings": collection.inputs[index].settings,
      "inputKind": collection.inputs[index].kind}
  of "SetInputSettings":
    for key, value in data{"inputSettings"}:
      collection.inputs[index].settings[key] = value
  of "GetInputPropertiesListPropertyItems":
    let items = if collection.inputs[index].kind == "xcomposite_input":
        %*[{"itemName": "Minecraft Wiki", "itemValue": BrowserWindow, "itemEnabled": true},
          {"itemName": "Minecraft", "itemValue": MinecraftWindow, "itemEnabled": true}]
      else:
        %*[{"itemName": "java", "itemValue": "java", "itemEnabled": true},
          {"itemName": MinecraftApp, "itemValue": MinecraftApp, "itemEnabled": true}]
    result.data = %*{"propertyItems": items}
  of "GetSceneItemList":
    var items = newJArray()
    for item in collection.items[sceneName]:
      items.add(%*{"sceneItemId": item.id, "sourceName": item.source,
        "sceneItemEnabled": item.enabled})
    result.data = %*{"sceneItems": items}
  of "CreateSceneItem":
    inc fake.nextItemId
    collection.items[sceneName].add(FakeItem(id: fake.nextItemId,
      source: data{"sourceName"}.getStr(), enabled: true, transform: newJObject()))
    result.data = %*{"sceneItemId": fake.nextItemId}
  of "SetSceneItemEnabled", "GetSceneItemTransform", "SetSceneItemTransform":
    for item in collection.items[sceneName].mitems:
      if item.id == data{"sceneItemId"}.getInt():
        case requestType
        of "SetSceneItemEnabled":
          item.enabled = data{"sceneItemEnabled"}.getBool()
        of "GetSceneItemTransform":
          result.data = %*{"sceneItemTransform": item.transform}
        else:
          for key, value in data{"sceneItemTransform"}:
            item.transform[key] = value
  of "GetInputAudioTracks":
    result.data = %*{"inputAudioTracks": collection.inputs[index].tracks}
  of "SetInputAudioTracks":
    for key, value in data{"inputAudioTracks"}:
      collection.inputs[index].tracks[key] = value
  of "GetInputAudioMonitorType":
    result.data = %*{"monitorType": collection.inputs[index].monitor}
  of "SetInputAudioMonitorType":
    collection.inputs[index].monitor = data{"monitorType"}.getStr()
  else:
    result.code = UnknownRequestCode
  if requestType == fake.streamAfter:
    fake.streaming = true

proc newSetupFake(): SetupFake =
  ## Start a fake OBS holding only the user's Untitled profile and collection.
  let fake = SetupFake(obs: newFakeObs(), profiles: @[UntitledName],
    profile: UntitledName, collection: UntitledName,
    video: %*{"fpsNumerator": 30, "fpsDenominator": 1, "baseWidth": 2560,
      "baseHeight": 1440, "outputWidth": 1280, "outputHeight": 720})
  let untitled = newCollection()
  fake.addInput(untitled, DefaultScene, "Desktop Audio", "pulse_output_capture")
  fake.addInput(untitled, DefaultScene, "Mic/Aux", "pulse_input_capture")
  untitled.special["desktop1"] = %"Desktop Audio"
  untitled.special["mic1"] = %"Mic/Aux"
  fake.collections[UntitledName] = untitled
  fake.obs.override = proc (socket: WebSocket, requestType, requestId: string,
      data: JsonNode): Future[bool] {.async, gcsafe.} =
    let answer = fake.handle(requestType, if data == nil: newJObject() else: data)
    if answer.code == 0:
      await socket.respond(requestType, requestId, answer.data)
    else:
      await socket.respond(requestType, requestId, nil, false, answer.code,
        requestType & " failed in the fake.")
    result = true
  fake

proc mutations(fake: SetupFake): seq[string] =
  ## List the mutating requests received so far.
  for request in fake.obs.requests:
    if request in MutatingRequests:
      result.add(request)

proc run(fake: SetupFake): OnlineReport =
  ## Connect a client and run online setup to completion.
  let client = waitFor connectObs(fake.obs.url, "")
  try:
    result = waitFor client.prepareOnline(proc (message: string) {.gcsafe.} = discard)
  finally:
    client.close()

proc runFailure(fake: SetupFake): string =
  ## Run online setup expecting a SetupError and return its message.
  try:
    discard fake.run()
    doAssert false, "setup should have refused"
  except SetupError as error:
    result = error.msg

proc testFreshProvisioning() =
  ## Create the project from an Untitled-only OBS and leave Untitled untouched.
  let
    fake = newSetupFake()
    untitledBefore = fake.collections[UntitledName].snapshot()
    report = fake.run()
  doAssert report.changes.len > 0
  doAssert report.minecraftVideoBound and report.minecraftAudioBound
  doAssert fake.profiles == @[UntitledName, ObsProfileName]
  doAssert fake.profile == ObsProfileName
  doAssert fake.collection == ObsCollectionName
  doAssert fake.collections[UntitledName].snapshot() == untitledBefore
  doAssert fake.video == %*{"fpsNumerator": 60, "fpsDenominator": 1,
    "baseWidth": 1920, "baseHeight": 1080, "outputWidth": 1920, "outputHeight": 1080}
  let project = fake.current
  doAssert project.scenes == @[ObsSceneName]
  doAssert project.program == ObsSceneName
  doAssert project.inputs.len == 3
  let
    video = project.inputs[project.inputIndex(ObsVideoName)]
    audio = project.inputs[project.inputIndex(ObsAudioName)]
    mic = project.inputs[project.inputIndex(ObsMicName)]
  doAssert video.kind == "xcomposite_input"
  doAssert video.settings["capture_window"].getStr() == MinecraftWindow
  doAssert audio.kind == "pipewire_audio_application_capture"
  doAssert audio.settings == %*{"CaptureMode": 0, "MatchPriorty": 1,
    "ExceptApp": false, "TargetName": MinecraftApp}
  doAssert mic.kind == "pulse_input_capture" and mic.muted
  doAssert not audio.muted
  doAssert audio.tracks == %*{"1": true, "2": true, "3": false, "4": false,
    "5": false, "6": false}
  doAssert mic.tracks == %*{"1": true, "2": false, "3": true, "4": false,
    "5": false, "6": false}
  doAssert audio.monitor == "OBS_MONITORING_TYPE_NONE"
  doAssert mic.monitor == "OBS_MONITORING_TYPE_NONE"
  var sources: seq[string]
  for item in project.items[ObsSceneName]:
    sources.add(item.source)
    doAssert item.enabled
    if item.source == ObsVideoName:
      doAssert item.transform["boundsType"].getStr() == "OBS_BOUNDS_SCALE_INNER"
      doAssert item.transform["boundsWidth"].getFloat() == 1920.0
      doAssert item.transform["boundsHeight"].getFloat() == 1080.0
      doAssert item.transform["alignment"].getInt() == 5
      doAssert item.transform["boundsAlignment"].getInt() == 0
  doAssert sources == @[ObsVideoName, ObsAudioName, ObsMicName]
  # A second run finds everything current and changes nothing.
  let mutationsBefore = fake.mutations().len
  let again = fake.run()
  doAssert again.changes.len == 0
  doAssert fake.mutations().len == mutationsBefore
  fake.obs.stop()

proc testRefusesWhileOutputActive() =
  ## Change nothing at all while recording or streaming.
  for streaming in [false, true]:
    let fake = newSetupFake()
    if streaming:
      fake.streaming = true
    else:
      fake.recording = true
    let message = fake.runFailure()
    doAssert (if streaming: "streaming" else: "recording") in message
    doAssert fake.mutations().len == 0
    doAssert fake.profile == UntitledName and fake.collection == UntitledName
    fake.obs.stop()

proc testRechecksBeforeEveryChange() =
  ## Stop as soon as an output starts between two changes.
  let fake = newSetupFake()
  fake.streamAfter = "CreateProfile"
  doAssert "streaming" in fake.runFailure()
  doAssert fake.mutations() == @["CreateProfile"]
  doAssert fake.collection == UntitledName
  fake.obs.stop()

proc testRefusesGlobalAudio() =
  ## Refuse a project collection with global desktop audio before changing its sources.
  let fake = newSetupFake()
  fake.profiles.add(ObsProfileName)
  fake.profile = ObsProfileName
  fake.video = %*{"fpsNumerator": 60, "fpsDenominator": 1, "baseWidth": 1920,
    "baseHeight": 1080, "outputWidth": 1920, "outputHeight": 1080}
  let project = newCollection()
  fake.addInput(project, DefaultScene, "Desktop Audio", "pulse_output_capture")
  project.special["desktop1"] = %"Desktop Audio"
  fake.collections[ObsCollectionName] = project
  fake.collection = ObsCollectionName
  doAssert "Desktop Audio" in fake.runFailure()
  doAssert fake.mutations().len == 0
  fake.obs.stop()

proc testCleansExistingCollection() =
  ## Remove extra scenes and capture inputs, keep other sources, fix routing.
  let fake = newSetupFake()
  fake.collection = ObsCollectionName
  fake.profiles.add(ObsProfileName)
  let project = newCollection()
  fake.collections[ObsCollectionName] = project
  project.scenes.add(ObsSceneName)
  fake.addInput(project, ObsSceneName, ObsVideoName, "xcomposite_input",
    %*{"capture_window": BrowserWindow})
  fake.addInput(project, ObsSceneName, ObsMicName, "pulse_input_capture")
  project.inputs[^1].monitor = "OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT"
  fake.addInput(project, DefaultScene, "Webcam", "v4l2_input")
  fake.addInput(project, ObsSceneName, "Screen", "pipewire-screen-capture-source")
  fake.addInput(project, ObsSceneName, "Logo", "image_source")
  project.items[ObsSceneName][0].enabled = false
  discard fake.run()
  doAssert fake.profile == ObsProfileName
  doAssert fake.profiles == @[UntitledName, ObsProfileName]
  doAssert project.scenes == @[ObsSceneName]
  var names: seq[string]
  for input in project.inputs:
    names.add(input.name)
  doAssert names == @[ObsVideoName, ObsMicName, "Logo", ObsAudioName]
  let mic = project.inputs[project.inputIndex(ObsMicName)]
  doAssert mic.monitor == "OBS_MONITORING_TYPE_NONE"
  doAssert not mic.muted, "existing commentary mute state is preserved"
  doAssert project.inputs[0].settings["capture_window"].getStr() == MinecraftWindow
  for item in project.items[ObsSceneName]:
    doAssert item.enabled
  fake.obs.stop()

proc testRefusesWrongInputKind() =
  ## Never replace a same-named input of another kind.
  let fake = newSetupFake()
  fake.profiles.add(ObsProfileName)
  fake.profile = ObsProfileName
  let project = newCollection()
  fake.collections[ObsCollectionName] = project
  fake.collection = ObsCollectionName
  project.scenes.add(ObsSceneName)
  project.program = ObsSceneName
  project.scenes.delete(0)
  project.items.del(DefaultScene)
  fake.addInput(project, ObsSceneName, ObsVideoName, "xshm_input")
  doAssert "xshm_input" in fake.runFailure()
  doAssert "RemoveInput" notin fake.mutations()
  fake.obs.stop()

proc testIniEditing() =
  ## Update, insert, and append libobs INI keys while preserving other lines.
  let edited = setIniValues(ProjectIni, [
    ("AdvOut", "RecFilePath", "/home/user/Videos/Minecraft-AI"),
    ("General", "Extra", "a\\b\nc"),
    ("Output", "Mode", "Advanced"),
    ("Video", "AutoRemux", "true")
  ])
  doAssert edited == "[General]\nName=Minecraft AI Demos\nExtra=a\\\\b\\nc\n\n" &
    "[Video]\nBaseCX=1920\nBaseCY=1080\nFPSType=2\nAutoRemux=true\n\n" &
    "[AdvOut]\nEncoder=obs_x264\nRecFilePath=/home/user/Videos/Minecraft-AI\n\n" &
    "[Output]\nMode=Advanced\n"
  doAssert iniValue(edited, "Output", "Mode") == "Advanced"
  doAssert iniValue(edited, "AdvOut", "Encoder") == "obs_x264"
  doAssert iniValue(edited, "Video", "Missing") == ""
  doAssert setIniValues(edited, [("Output", "Mode", "Advanced")]) == edited

proc testRecordingValues() =
  ## Record tracks 1-3 with VAAPI CQP 20 into MKV and remux to MP4.
  var values = initTable[string, string]()
  for item in recordingIniValues("/r"):
    values[item.section & "." & item.key] = item.value
  doAssert values["Output.Mode"] == "Advanced"
  doAssert values["AdvOut.RecType"] == "Standard"
  doAssert values["AdvOut.RecFilePath"] == "/r"
  doAssert values["AdvOut.RecFormat2"] == "mkv"
  doAssert values["AdvOut.RecEncoder"] == "ffmpeg_vaapi_tex"
  doAssert values["AdvOut.RecAudioEncoder"] == "ffmpeg_aac"
  doAssert values["AdvOut.RecTracks"] == "7"
  doAssert values["AdvOut.Track1Bitrate"] == "160"
  doAssert values["AdvOut.Track3Bitrate"] == "160"
  doAssert "AdvOut.Track4Bitrate" notin values
  doAssert values["Video.AutoRemux"] == "true"
  let encoder = parseJson(recordEncoderJson("{\"bf\": 2, \"qp\": 30}", "/dev/dri/renderD128"))
  doAssert encoder == %*{"bf": 2, "qp": 20, "rate_control": "CQP",
    "vaapi_device": "/dev/dri/renderD128"}

proc mode(path: string): int =
  ## Return a file's permission bits.
  var info: Stat
  doAssert stat(path.cstring, info) == 0
  int(info.st_mode) and 0o777

proc writeProfile(configDir, directory, text: string) =
  ## Create a profile directory holding basic.ini.
  createDir(configDir / "basic/profiles" / directory)
  writeFile(configDir / "basic/profiles" / directory / "basic.ini", text)

proc testFindProfile() =
  ## Locate profiles by their basic.ini name, falling back to the directory name.
  let configDir = createTempDir("setup_obs_find", "")
  writeProfile(configDir, "Untitled", UntitledIni)
  writeProfile(configDir, "Minecraft_AI_Demos", ProjectIni)
  writeProfile(configDir, "Nameless", "[Output]\nMode=Simple\n")
  doAssert findProfileDir(configDir, ObsProfileName) ==
    configDir / "basic/profiles/Minecraft_AI_Demos"
  doAssert findProfileDir(configDir, "Nameless") == configDir / "basic/profiles/Nameless"
  doAssertRaises(SetupError):
    discard findProfileDir(configDir, "Missing")
  writeProfile(configDir, "Copy", ProjectIni)
  doAssertRaises(SetupError):
    discard findProfileDir(configDir, ObsProfileName)
  removeDir(configDir)

proc testConfigureOffline() =
  ## Write recording settings atomically with private backups, then do nothing on rerun.
  let
    configDir = createTempDir("setup_obs_offline", "")
    recordDir = configDir / "Videos/Minecraft-AI"
    profileDir = configDir / "basic/profiles/Minecraft_AI_Demos"
    untitledPath = configDir / "basic/profiles/Untitled/basic.ini"
    iniPath = profileDir / "basic.ini"
    encoderPath = profileDir / "recordEncoder.json"
  writeProfile(configDir, "Untitled", UntitledIni)
  writeProfile(configDir, "Minecraft_AI_Demos", ProjectIni)
  doAssertRaises(SetupError):
    discard configureOffline(configDir, iniPath, recordDir, "s0")
  doAssertRaises(SetupError):
    discard configureOffline(configDir, "dev/null", recordDir, "s0")
  doAssertRaises(SetupError):
    discard configureOffline(configDir, "/dev/null", "Videos", "s0")
  writeFile(encoderPath, "not json")
  doAssertRaises(JsonParsingError):
    discard configureOffline(configDir, "/dev/null", recordDir, "s0")
  doAssert readFile(iniPath) == ProjectIni
  doAssert not dirExists(recordDir)
  removeFile(encoderPath)

  let changes = configureOffline(configDir, "/dev/null", recordDir, "s1")
  doAssert changes.len == 3
  doAssert dirExists(recordDir)
  let ini = readFile(iniPath)
  doAssert iniValue(ini, "General", "Name") == ObsProfileName
  doAssert iniValue(ini, "Video", "FPSType") == "2"
  doAssert iniValue(ini, "AdvOut", "Encoder") == "obs_x264"
  doAssert iniValue(ini, "AdvOut", "RecFilePath") == recordDir
  doAssert iniValue(ini, "AdvOut", "RecEncoder") == "ffmpeg_vaapi_tex"
  doAssert iniValue(ini, "Video", "AutoRemux") == "true"
  doAssert parseJson(readFile(encoderPath)) == %*{"vaapi_device": "/dev/null",
    "rate_control": "CQP", "qp": 20}
  doAssert readFile(iniPath & ".knobby-backup-s1") == ProjectIni
  doAssert not fileExists(encoderPath & ".knobby-backup-s1")
  for path in [iniPath, encoderPath, iniPath & ".knobby-backup-s1"]:
    doAssert mode(path) == 0o600
  doAssert readFile(untitledPath) == UntitledIni

  doAssert configureOffline(configDir, "/dev/null", recordDir, "s2").len == 0
  var leftovers: seq[string]
  for kind, path in walkDir(profileDir):
    leftovers.add(path.lastPathPart)
  doAssert leftovers.len == 3, $leftovers

  let changedDevice = configureOffline(configDir, "/dev/zero", recordDir, "s3")
  doAssert changedDevice.len == 1 and "recordEncoder.json" in changedDevice[0]
  doAssert parseJson(readFile(encoderPath & ".knobby-backup-s3"))["vaapi_device"].getStr() ==
    "/dev/null"
  removeDir(configDir)

proc main() =
  ## Run setup tests against fake OBS servers and temporary configs only.
  testIniEditing()
  testRecordingValues()
  testFindProfile()
  testConfigureOffline()
  testFreshProvisioning()
  testRefusesWhileOutputActive()
  testRechecksBeforeEveryChange()
  testRefusesGlobalAudio()
  testCleansExistingCollection()
  testRefusesWrongInputKind()

when isMainModule:
  main()

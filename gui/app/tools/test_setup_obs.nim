import
  std/[asyncdispatch, json, os, posix, strutils, tables, tempfiles],
  ws,
  knobby/obs_projects,
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
  MinecraftIni = "[General]\nName=Minecraft AI Demos\n\n[AdvOut]\n" &
    "RecEncoder=ffmpeg_vaapi_tex\n\n[Audio]\nSampleRate=48000\nChannelSetup=Stereo\n"
  MinecraftEncoder = "{\"vaapi_device\": \"/dev/null\", \"qp\": 20}\n"
  MinecraftMic = "alsa_input.usb-mic"
  IntroScene = "Intro"

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
    # OBS applies CreateProfile later on its UI thread; this counts the
    # requests still answered from the previous profile.
    pendingProfile: string
    pendingRequests: int
    collections: OrderedTable[string, FakeCollection]
    collection: string
    videos: Table[string, JsonNode]
    audioFormats: Table[string, tuple[rate, channels: string]]
    # When set, profiles live on disk; OBS saves the active profile's
    # in-memory basic.ini when switching away from it.
    configDir: string
    activeIni: string
    resetProgramOnLoad: bool
    recording, streaming: bool
    streamAfter: string
    nextItemId: int

proc newVideo(): JsonNode =
  ## Return the 1440p30 video settings of a profile OBS has not configured.
  %*{"fpsNumerator": 30, "fpsDenominator": 1, "baseWidth": 2560,
    "baseHeight": 1440, "outputWidth": 1280, "outputHeight": 720}

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

proc profileIniPath(fake: SetupFake, profile: string): string =
  ## Return the basic.ini path OBS uses for a profile name.
  fake.configDir / "basic/profiles" / profile.replace(' ', '_') / "basic.ini"

proc activateProfile(fake: SetupFake, profile: string) =
  ## Switch profiles like OBS: save the old one from memory, then load the new one.
  if fake.configDir.len > 0:
    writeFile(fake.profileIniPath(fake.profile), fake.activeIni)
    let path = fake.profileIniPath(profile)
    if not fileExists(path):
      createDir(path.parentDir)
      writeFile(path, "[General]\nName=" & profile & "\n")
    fake.activeIni = readFile(path)
  fake.profile = profile

proc handle(fake: SetupFake, requestType: string, data: JsonNode): tuple[
    data: JsonNode, code: int] =
  ## Apply one request to the fake OBS state; code 0 means success.
  if fake.pendingProfile.len > 0:
    dec fake.pendingRequests
    if fake.pendingRequests < 0:
      fake.activateProfile(fake.pendingProfile)
      fake.pendingProfile = ""
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
    let name = data{"profileName"}.getStr()
    fake.profiles.add(name)
    fake.pendingProfile = name
    fake.pendingRequests = 1
    fake.videos[name] = newVideo()
  of "SetCurrentProfile":
    fake.activateProfile(data{"profileName"}.getStr())
  of "GetProfileParameter":
    let format = fake.audioFormats.getOrDefault(fake.profile, ("48000", "Stereo"))
    result.data = %*{"parameterValue":
      if data{"parameterName"}.getStr() == "SampleRate": format.rate else: format.channels}
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
    if fake.resetProgramOnLoad:
      fake.current.program = fake.current.scenes[0]
  of "GetVideoSettings":
    result.data = fake.videos.getOrDefault(fake.profile, newVideo()).copy()
  of "SetVideoSettings":
    fake.videos[fake.profile] = data.copy()
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
    videos: {UntitledName: newVideo()}.toTable)
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
  doAssert fake.videos[ObsProfileName] == %*{"fpsNumerator": 60, "fpsDenominator": 1,
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
  fake.videos[ObsProfileName] = %*{"fpsNumerator": 60, "fpsDenominator": 1, "baseWidth": 1920,
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
    "vaapi_device": "/dev/dri/renderD128", "profile": 100, "keyint_sec": 2}

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
    "rate_control": "CQP", "qp": 20, "profile": 100, "keyint_sec": 2}
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

proc inputNamed(collection: FakeCollection, name: string): FakeInput =
  ## Return one input by name, failing the test when it is absent.
  let index = collection.inputIndex(name)
  doAssert index >= 0, "missing input " & name
  collection.inputs[index]

proc readTree(directory: string): Table[string, string] =
  ## Read every file below a directory, keyed by relative path.
  for path in walkDirRec(directory):
    result[path.relativePath(directory)] = readFile(path)

proc newMinecraftFake(): SetupFake =
  ## Start a fake OBS showing a provisioned Minecraft setup backed by a temporary config directory.
  let
    fake = newSetupFake()
    minecraft = projectSpec(MinecraftProject)
    collection = newCollection()
  fake.configDir = createTempDir("setup_obs_firefox", "")
  writeProfile(fake.configDir, "Untitled", UntitledIni)
  writeProfile(fake.configDir, "Minecraft_AI_Demos", MinecraftIni)
  writeFile(fake.configDir / "basic/profiles/Minecraft_AI_Demos/recordEncoder.json",
    MinecraftEncoder)
  fake.profiles.add(minecraft.profile)
  fake.profile = minecraft.profile
  fake.activeIni = MinecraftIni
  fake.videos[minecraft.profile] = %*{"fpsNumerator": 60, "fpsDenominator": 1,
    "baseWidth": 1920, "baseHeight": 1080, "outputWidth": 1920, "outputHeight": 1080}
  collection.scenes = @[minecraft.scene, IntroScene]
  collection.items = {minecraft.scene: newSeq[FakeItem](),
    IntroScene: newSeq[FakeItem]()}.toTable
  collection.program = IntroScene
  fake.addInput(collection, minecraft.scene, minecraft.video, "xcomposite_input",
    %*{"capture_window": MinecraftWindow})
  fake.addInput(collection, minecraft.scene, minecraft.audio,
    "pipewire_audio_application_capture", %*{"TargetName": MinecraftApp})
  fake.addInput(collection, minecraft.scene, minecraft.mic, "pulse_input_capture",
    %*{"device_id": MinecraftMic})
  fake.collections[minecraft.collection] = collection
  fake.collection = minecraft.collection
  fake

proc runFirefox(fake: SetupFake, renderDevice = "", stamp = "f1"): FirefoxReport =
  ## Connect a client and provision the Firefox setup against the fake's config directory.
  let client = waitFor connectObs(fake.obs.url, "")
  try:
    result = waitFor client.provisionFirefox(fake.configDir, renderDevice,
      fake.configDir / "Videos/Firefox-Demos", proc (message: string) {.gcsafe.} = discard,
      stamp)
  finally:
    client.close()

proc runFirefoxFailure(fake: SetupFake, renderDevice = ""): string =
  ## Provision the Firefox setup expecting a refusal and return its message.
  try:
    discard fake.runFirefox(renderDevice)
    doAssert false, "Firefox setup should have refused"
  except SetupError as error:
    result = error.msg

proc stopFake(fake: SetupFake) =
  ## Stop the fake OBS and remove its temporary config directory.
  fake.obs.stop()
  if fake.configDir.len > 0:
    removeDir(fake.configDir)

proc testFirefoxProvisioning() =
  ## Provision Firefox while OBS runs, restore the Minecraft setup, then write the inactive profile.
  let
    fake = newMinecraftFake()
    firefox = projectSpec(FirefoxProject)
    minecraft = projectSpec(MinecraftProject)
    minecraftBefore = fake.collections[minecraft.collection].snapshot()
    untitledBefore = fake.collections[UntitledName].snapshot()
    profilesDir = fake.configDir / "basic/profiles"
    minecraftFiles = readTree(profilesDir / "Minecraft_AI_Demos")
    untitledFiles = readTree(profilesDir / "Untitled")
    report = fake.runFirefox()
  doAssert report.renderDevice == "/dev/null", "device comes from the Minecraft encoder"
  doAssert report.original == ObsSelection(profile: minecraft.profile,
    collection: minecraft.collection, programScene: IntroScene)
  doAssert fake.profile == minecraft.profile
  doAssert fake.collection == minecraft.collection
  doAssert fake.current.program == IntroScene
  doAssert fake.collections[minecraft.collection].snapshot() == minecraftBefore
  doAssert fake.collections[UntitledName].snapshot() == untitledBefore
  doAssert fake.videos[minecraft.profile]["baseWidth"].getInt() == 1920
  doAssert fake.profiles == @[UntitledName, minecraft.profile, firefox.profile]
  doAssert fake.videos[firefox.profile] == %*{"fpsNumerator": 60, "fpsDenominator": 1,
    "baseWidth": 1920, "baseHeight": 1080, "outputWidth": 1920, "outputHeight": 1080}
  doAssert fake.obs.count("GetInputPropertiesListPropertyItems") == 0,
    "window and application enumeration stay with the runtime"
  let mutations = fake.mutations()
  doAssert mutations[0] == "CreateSceneCollection" and mutations[1] == "CreateProfile",
    "the collection switches before the profile: " & $mutations
  doAssert mutations[^2..^1] == @["SetCurrentProfile", "SetCurrentSceneCollection"],
    "the profile is restored before the collection: " & $mutations
  doAssert "RemoveInput" notin mutations

  let project = fake.collections[firefox.collection]
  doAssert project.scenes == @[firefox.scene]
  doAssert project.program == firefox.scene
  doAssert project.special == emptySpecial()
  let
    video = project.inputNamed(firefox.video)
    audio = project.inputNamed(firefox.audio)
    mic = project.inputNamed(firefox.mic)
  doAssert project.inputs.len == 3
  doAssert video.kind == "xcomposite_input" and video.settings == newJObject(),
    "the browser window starts unbound"
  doAssert audio.kind == "pipewire_audio_application_capture"
  doAssert audio.settings == %*{"CaptureMode": 0, "MatchPriorty": 1, "ExceptApp": false},
    "the browser audio starts unbound"
  doAssert mic.kind == "pulse_input_capture" and mic.muted
  doAssert mic.settings == %*{"device_id": MinecraftMic}
  doAssert not audio.muted
  doAssert audio.tracks == %*{"1": true, "2": true, "3": false, "4": false,
    "5": false, "6": false}
  doAssert mic.tracks == %*{"1": true, "2": false, "3": true, "4": false,
    "5": false, "6": false}
  doAssert audio.monitor == "OBS_MONITORING_TYPE_NONE"
  doAssert mic.monitor == "OBS_MONITORING_TYPE_NONE"
  var sources: seq[string]
  for item in project.items[firefox.scene]:
    sources.add(item.source)
    doAssert item.enabled
    if item.source == firefox.video:
      doAssert item.transform["boundsType"].getStr() == "OBS_BOUNDS_SCALE_INNER"
      doAssert item.transform["boundsWidth"].getFloat() == 1920.0
      doAssert item.transform["boundsHeight"].getFloat() == 1080.0
  doAssert sources == @[firefox.video, firefox.audio, firefox.mic]

  let
    firefoxDir = profilesDir / "Firefox_Demos"
    iniPath = firefoxDir / "basic.ini"
    encoderPath = firefoxDir / "recordEncoder.json"
    recordDir = fake.configDir / "Videos/Firefox-Demos"
    ini = readFile(iniPath)
  doAssert report.files.len == 3, $report.files
  doAssert dirExists(recordDir)
  doAssert iniValue(ini, "General", "Name") == firefox.profile
  doAssert iniValue(ini, "AdvOut", "RecFilePath") == recordDir
  doAssert iniValue(ini, "AdvOut", "RecEncoder") == "ffmpeg_vaapi_tex"
  doAssert iniValue(ini, "AdvOut", "RecFormat2") == "mkv"
  doAssert iniValue(ini, "AdvOut", "RecTracks") == "7"
  doAssert iniValue(ini, "Video", "AutoRemux") == "true"
  doAssert iniValue(ini, "Audio", "SampleRate") == "48000"
  doAssert parseJson(readFile(encoderPath)) == %*{"vaapi_device": "/dev/null",
    "rate_control": "CQP", "qp": 20, "profile": 100, "keyint_sec": 2}
  for path in [iniPath, encoderPath, iniPath & ".knobby-backup-f1"]:
    doAssert mode(path) == 0o600
  doAssert readTree(profilesDir / "Minecraft_AI_Demos") == minecraftFiles
  doAssert readTree(profilesDir / "Untitled") == untitledFiles

  # The runtime binds the captures and the human picks a microphone; a rerun keeps both.
  project.inputs[project.inputIndex(firefox.video)].settings["capture_window"] = %"bound"
  project.inputs[project.inputIndex(firefox.audio)].settings["TargetName"] = %"knobby-firefox"
  project.inputs[project.inputIndex(firefox.mic)].settings["device_id"] = %"chosen"
  project.inputs[project.inputIndex(firefox.mic)].muted = false
  let
    firefoxBefore = project.snapshot()
    firefoxFiles = readTree(firefoxDir)
    mutationsBefore = fake.mutations().len
    again = fake.runFirefox(stamp = "f2")
  doAssert again.files.len == 0
  doAssert fake.mutations()[mutationsBefore..^1] == @["SetCurrentSceneCollection",
    "SetCurrentProfile", "SetCurrentProfile", "SetCurrentSceneCollection"]
  doAssert project.snapshot() == firefoxBefore
  doAssert readTree(firefoxDir) == firefoxFiles
  doAssert fake.collections[minecraft.collection].snapshot() == minecraftBefore
  doAssert readTree(profilesDir / "Minecraft_AI_Demos") == minecraftFiles

  # An explicit device changes only the encoder file, keeping a private backup.
  let changed = fake.runFirefox("/dev/zero", "f3")
  doAssert changed.files.len == 1 and "recordEncoder.json" in changed.files[0]
  doAssert parseJson(readFile(encoderPath))["vaapi_device"].getStr() == "/dev/zero"
  doAssert parseJson(readFile(encoderPath & ".knobby-backup-f3"))["vaapi_device"].getStr() ==
    "/dev/null"
  doAssert mode(encoderPath & ".knobby-backup-f3") == 0o600
  fake.stopFake()

proc testFirefoxRestoresProgramScene() =
  ## Restore the original program scene when reloading the collection shows another one.
  let fake = newMinecraftFake()
  fake.resetProgramOnLoad = true
  discard fake.runFirefox()
  doAssert fake.current.program == IntroScene
  doAssert fake.mutations()[^1] == "SetCurrentProgramScene"
  fake.stopFake()

proc testFirefoxRefusesActiveOutput() =
  ## Change nothing at all while recording or streaming.
  for streaming in [false, true]:
    let fake = newMinecraftFake()
    if streaming:
      fake.streaming = true
    else:
      fake.recording = true
    doAssert (if streaming: "streaming" else: "recording") in fake.runFirefoxFailure()
    doAssert fake.mutations().len == 0
    doAssert not dirExists(fake.configDir / "basic/profiles/Firefox_Demos")
    fake.stopFake()

proc testFirefoxKeepsHumanOutput() =
  ## Stop at an output started mid-setup and leave OBS selected rather than switch while it runs.
  let
    fake = newMinecraftFake()
    firefox = projectSpec(FirefoxProject)
  fake.streamAfter = "CreateInput"
  let message = fake.runFirefoxFailure()
  doAssert "streaming" in message and "was not returned" in message, message
  doAssert fake.mutations()[^1] == "CreateInput"
  doAssert fake.streaming
  doAssert fake.profile == firefox.profile and fake.collection == firefox.collection
  doAssert not fileExists(fake.configDir / "basic/profiles/Firefox_Demos/recordEncoder.json")
  fake.stopFake()

proc testFirefoxRefusesForeignContent() =
  ## Refuse a Firefox collection holding anything setup did not create, then restore the original.
  let
    firefox = projectSpec(FirefoxProject)
    minecraft = projectSpec(MinecraftProject)
  for variant in ["input", "scene", "defaultItem", "globalAudio"]:
    let
      fake = newMinecraftFake()
      existing = newCollection()
    fake.collections[firefox.collection] = existing
    case variant
    of "input":
      fake.addInput(existing, DefaultScene, "Webcam", "v4l2_input")
    of "scene":
      existing.scenes.add("Browser")
      existing.items["Browser"] = @[]
    of "defaultItem":
      fake.addInput(existing, DefaultScene, firefox.video, "xcomposite_input")
    else:
      existing.special["desktop1"] = %"Desktop Audio"
    let
      before = existing.snapshot()
      message = fake.runFirefoxFailure()
    doAssert "setup changes no" in message or "global audio" in message, message
    doAssert existing.snapshot() == before, variant
    doAssert fake.mutations() == @["SetCurrentSceneCollection", "SetCurrentSceneCollection"],
      variant & ": " & $fake.mutations()
    doAssert firefox.profile notin fake.profiles
    doAssert fake.profile == minecraft.profile and fake.collection == minecraft.collection
    doAssert fake.current.program == IntroScene
    fake.stopFake()

proc testFirefoxRefusesWhileFirefoxActive() =
  ## Refuse to start from the Firefox setup and never write the active profile's files.
  let
    fake = newMinecraftFake()
    firefox = projectSpec(FirefoxProject)
  discard fake.runFirefox()
  let
    firefoxDir = fake.configDir / "basic/profiles/Firefox_Demos"
    filesBefore = readTree(firefoxDir)
    mutationsBefore = fake.mutations().len
  fake.activateProfile(firefox.profile)
  doAssert "switch OBS" in fake.runFirefoxFailure()
  let client = waitFor connectObs(fake.obs.url, "")
  try:
    doAssertRaises(SetupError):
      discard waitFor client.configureInactiveProfile(fake.configDir, firefox.profile,
        "/dev/zero", fake.configDir / "Videos/Firefox-Demos", "f9")
  finally:
    client.close()
  doAssert fake.mutations().len == mutationsBefore
  doAssert readTree(firefoxDir) == filesBefore
  fake.stopFake()

proc testFirefoxRefusesMalformedOrMismatched() =
  ## Refuse malformed profile files, an unknown render device, and audio formats that prompt a restart.
  let firefox = projectSpec(FirefoxProject)
  for variant in ["firefoxEncoder", "minecraftEncoder", "noDevice", "minecraftRate",
      "firefoxRate", "relativeRecord"]:
    let fake = newMinecraftFake()
    var renderDevice = ""
    case variant
    of "firefoxEncoder", "firefoxRate":
      fake.profiles.add(firefox.profile)
      writeProfile(fake.configDir, "Firefox_Demos", "[General]\nName=Firefox Demos\n" &
        (if variant == "firefoxRate": "\n[Audio]\nSampleRate=44100\n" else: ""))
      if variant == "firefoxEncoder":
        writeFile(fake.configDir / "basic/profiles/Firefox_Demos/recordEncoder.json", "[1]")
    of "minecraftEncoder":
      writeFile(fake.configDir / "basic/profiles/Minecraft_AI_Demos/recordEncoder.json",
        "not json")
    of "noDevice":
      writeFile(fake.configDir / "basic/profiles/Minecraft_AI_Demos/recordEncoder.json",
        "{\"qp\": 20}")
    of "minecraftRate":
      fake.audioFormats[fake.profile] = ("44100", "Stereo")
    else:
      renderDevice = "/dev/null"
    let filesBefore = readTree(fake.configDir)
    if variant == "minecraftEncoder":
      doAssertRaises(JsonParsingError):
        discard fake.runFirefox(renderDevice)
    elif variant == "relativeRecord":
      let client = waitFor connectObs(fake.obs.url, "")
      try:
        doAssertRaises(SetupError):
          discard waitFor client.provisionFirefox(fake.configDir, renderDevice, "Videos")
      finally:
        client.close()
    else:
      discard fake.runFirefoxFailure(renderDevice)
    doAssert fake.mutations().len == 0, variant
    doAssert readTree(fake.configDir) == filesBefore, variant
    fake.stopFake()

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
  testFirefoxProvisioning()
  testFirefoxRestoresProgramScene()
  testFirefoxRefusesActiveOutput()
  testFirefoxKeepsHumanOutput()
  testFirefoxRefusesForeignContent()
  testFirefoxRefusesWhileFirefoxActive()
  testFirefoxRefusesMalformedOrMismatched()

when isMainModule:
  main()

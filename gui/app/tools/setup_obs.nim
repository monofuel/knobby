import
  std/[asyncdispatch, json, os, posix, strutils, times],
  knobby/obs_projects,
  obs_client, obs_workspace, obs_targets

const
  Usage = """Usage:
  setup_obs prepare-online
      Through the running OBS WebSocket server, create or select the
      Minecraft AI Demos profile and scene collection, then provision the
      Minecraft scene, its three inputs, tracks, transform, and 1080p60 video.
  setup_obs configure-offline --render-device PATH [--config-dir DIR] [--record-dir DIR]
      With OBS stopped, write the profile's VAAPI H.264 MKV recording settings
      into its basic.ini and recordEncoder.json, keeping private backups.
  setup_obs provision-firefox [--render-device PATH] [--config-dir DIR] [--record-dir DIR]
      With OBS running and idle, temporarily select or create the Firefox Demos
      collection and profile, provision its Firefox scene, unbound inputs,
      tracks, and 1080p60 video, then restore the original profile, collection,
      and program scene. Only then write the inactive Firefox profile's VAAPI
      H.264 MKV recording files, keeping private backups. The render device
      defaults to the Minecraft AI Demos profile's VAAPI device.

Every mode is repeatable; a run that finds nothing to change changes nothing.
The online modes change nothing while OBS is recording or streaming."""
  UsageExitCode = 2
  FailureExitCode = 1
  LogPrefix = "setup_obs: "
  ObsProcessNames = ["obs", ".obs-wrapped"]

  CanvasWidth = 1920
  CanvasHeight = 1080
  FramesPerSecond = 60
  VideoKind = "xcomposite_input"
  AudioKind = "pipewire_audio_application_capture"
  MicKind = "pulse_input_capture"
  TrackCount = 6
  GameTracks = [1, 2]
  MicTracks = [1, 3]
  MonitorOff = "OBS_MONITORING_TYPE_NONE"
  ScaleInnerBounds = "OBS_BOUNDS_SCALE_INNER"
  TopLeftAlignment = 5
  CenterAlignment = 0
  # Every input that captures a screen, window, camera, or audio device.
  # Only the three named project inputs may use these in the project collection.
  CaptureInputKinds = [
    "xcomposite_input", "xshm_input", "xshm_input_v2",
    "pipewire-desktop-capture-source", "pipewire-screen-capture-source",
    "pipewire-window-capture-source", "pipewire-camera-source", "v4l2_input",
    "pulse_input_capture", "pulse_output_capture", "alsa_input_capture",
    "jack_output_capture", "pipewire_audio_input_capture",
    "pipewire_audio_output_capture", "pipewire_audio_application_capture"
  ]
  SpecialInputKeys = ["desktop1", "desktop2", "mic1", "mic2", "mic3", "mic4"]
  # The scene OBS puts in every new collection (Basic.Scene, en-US).
  DefaultSceneName = "Scene"
  ProfileSwitchPolls = 50
  ProfileSwitchPollMs = 100
  MicDeviceKey = "device_id"
  AudioSection = "Audio"
  SampleRateKey = "SampleRate"
  ChannelSetupKey = "ChannelSetup"
  # OBS asks to restart when a profile switch changes these, so every
  # profile setup switches between must already share them.
  RequiredSampleRate = "48000"
  RequiredChannelSetup = "Stereo"
  AsyncTracebackHeader = "\nAsync traceback:"

  ObsConfigDirName = "obs-studio"
  ProfilesRelativePath = "basic/profiles"
  ProfileSettingsFile = "basic.ini"
  RecordEncoderFile = "recordEncoder.json"
  ProfileNameSection = "General"
  ProfileNameKey = "Name"
  DefaultRecordRelativePath = "Videos/Minecraft-AI"
  RecordEncoderId = "ffmpeg_vaapi_tex"
  RecordAudioEncoderId = "ffmpeg_aac"
  RecordRateControl = "CQP"
  RecordQp = 20
  RecordAudioBitrateKbps = 160
  RecordFormat = "mkv"
  BackupInfix = ".knobby-backup-"
  TempInfix = ".knobby-tmp-"
  BackupStampFormat = "yyyyMMdd'T'HHmmss"
  PrivateFileMode = 0o600

type
  SetupError* = object of CatchableError

  SetupLog* = proc (message: string) {.closure, gcsafe.}

  OnlineSetup = ref object
    client: ObsClient
    spec: ObsProjectSpec
    # Minecraft setup removes other scenes and capture inputs; Firefox setup
    # refuses them instead and only removes OBS's empty default scene.
    removeExtras: bool
    liveTargets: bool
    changes: seq[string]
    log: SetupLog

  IniValue* = tuple[section, key, value: string]

  OnlineReport* = object
    changes*: seq[string]
    minecraftVideoBound*: bool
    minecraftAudioBound*: bool

  ObsSelection* = object
    profile*, collection*, programScene*: string

  FirefoxReport* = object
    ## changes lists OBS requests, including temporary selections and their
    ## restoration; files lists inactive-profile file writes.
    changes*: seq[string]
    files*: seq[string]
    original*: ObsSelection
    renderDevice*: string

proc logStderr*(message: string) {.gcsafe.} =
  ## Write one setup progress line to stderr.
  stderr.writeLine(LogPrefix & message)

proc setupError(message: string): ref SetupError =
  ## Build a setup failure.
  newException(SetupError, message)

proc trackMap(tracks: openArray[int]): JsonNode =
  ## Build the OBS track map enabling exactly the given 1-based tracks.
  result = newJObject()
  for track in 1..TrackCount:
    result[$track] = %(track in tracks)

proc trackMask(tracks: openArray[int]): int =
  ## Return the OBS bit mask of 1-based tracks.
  for track in tracks:
    result = result or (1 shl (track - 1))

proc applicationAudioSettings(): JsonNode =
  ## Return the PipeWire application capture settings that pick one target app.
  ## The plugin spells its priority key "MatchPriorty".
  %*{"CaptureMode": 0, "MatchPriorty": 1, "ExceptApp": false}

proc desiredTransform(): JsonNode =
  ## Fit the Minecraft window inside the full 1080p canvas, preserving aspect.
  %*{
    "positionX": 0.0, "positionY": 0.0, "rotation": 0.0,
    "alignment": TopLeftAlignment,
    "boundsType": ScaleInnerBounds,
    "boundsAlignment": CenterAlignment,
    "boundsWidth": CanvasWidth.float, "boundsHeight": CanvasHeight.float,
    "cropLeft": 0, "cropRight": 0, "cropTop": 0, "cropBottom": 0
  }

proc desiredVideo(): JsonNode =
  ## Return 1080p60 canvas and output settings.
  %*{
    "fpsNumerator": FramesPerSecond, "fpsDenominator": 1,
    "baseWidth": CanvasWidth, "baseHeight": CanvasHeight,
    "outputWidth": CanvasWidth, "outputHeight": CanvasHeight
  }

proc matchesDesired*(actual, desired: JsonNode): bool =
  ## Check that every desired field is present in actual with the same value.
  ## Numbers compare by value so OBS may report integers as floats.
  result = actual != nil and actual.kind == JObject
  if result:
    for key, expected in desired:
      let found = actual{key}
      if found == nil:
        return false
      if expected.kind in {JInt, JFloat}:
        if found.kind notin {JInt, JFloat} or found.getFloat() != expected.getFloat():
          return false
      elif found != expected:
        return false

proc stringsIn(node: JsonNode): seq[string] =
  ## Collect the strings of a JSON array, ignoring other values.
  if node != nil and node.kind == JArray:
    for item in node:
      if item.kind == JString:
        result.add(item.getStr())

proc activeOutputs*(client: ObsClient): Future[string] {.async.} =
  ## Describe active recording or streaming outputs, or return "" when idle.
  ## A missing or malformed state field counts as active.
  let
    record = await client.request("GetRecordStatus")
    stream = await client.request("GetStreamStatus")
  var active: seq[string]
  if record{"outputActive"}.getBool(true):
    active.add("recording")
  if stream{"outputActive"}.getBool(true):
    active.add("streaming")
  result = active.join(" and ")

proc requireIdle(client: ObsClient) {.async.} =
  ## Refuse to continue while OBS is recording or streaming.
  let active = await client.activeOutputs()
  if active.len > 0:
    raise setupError("OBS is " & active &
      "; setup changes nothing while an output is active.")

proc change(setup: OnlineSetup, requestType: string, data: JsonNode,
    description: string): Future[JsonNode] {.async.} =
  ## Recheck that OBS is idle, then perform and record one mutating request.
  await setup.client.requireIdle()
  result = await setup.client.request(requestType, data)
  setup.changes.add(description)
  setup.log(description)

proc currentProfile(client: ObsClient): Future[string] {.async.} =
  ## Return the name of the active OBS profile.
  result = (await client.request("GetProfileList")){"currentProfileName"}.getStr()

proc currentCollection(client: ObsClient): Future[string] {.async.} =
  ## Return the name of the active OBS scene collection.
  result = (await client.request("GetSceneCollectionList")){
    "currentSceneCollectionName"}.getStr()

proc ensureProfile(setup: OnlineSetup) {.async.} =
  ## Select the project profile, creating a clean one when it does not exist.
  ## OBS queues CreateProfile on its UI thread, so the switch is awaited by polling.
  let
    name = setup.spec.profile
    profiles = await setup.client.request("GetProfileList")
  if profiles{"currentProfileName"}.getStr() != name:
    if name in stringsIn(profiles{"profiles"}):
      discard await setup.change("SetCurrentProfile",
        %*{"profileName": name}, "Selected profile \"" & name & "\".")
    else:
      discard await setup.change("CreateProfile",
        %*{"profileName": name}, "Created profile \"" & name & "\".")
  var current = await setup.client.currentProfile()
  for _ in 1..ProfileSwitchPolls:
    if current == name:
      break
    await sleepAsync(ProfileSwitchPollMs)
    current = await setup.client.currentProfile()
  if current != name:
    raise setupError("OBS stayed on profile \"" & current & "\"; expected \"" &
      name & "\".")

proc ensureCollection(setup: OnlineSetup) {.async.} =
  ## Select the project scene collection, creating it when it does not exist.
  let
    name = setup.spec.collection
    collections = await setup.client.request("GetSceneCollectionList")
  if collections{"currentSceneCollectionName"}.getStr() != name:
    if name in stringsIn(collections{"sceneCollections"}):
      discard await setup.change("SetCurrentSceneCollection",
        %*{"sceneCollectionName": name},
        "Selected scene collection \"" & name & "\".")
    else:
      discard await setup.change("CreateSceneCollection",
        %*{"sceneCollectionName": name},
        "Created scene collection \"" & name & "\".")
  let current = await setup.client.currentCollection()
  if current != name:
    raise setupError("OBS stayed on scene collection \"" & current &
      "\"; expected \"" & name & "\".")

proc ensureVideo(setup: OnlineSetup) {.async.} =
  ## Set the project profile to a 1080p canvas and output at 60 fps.
  let
    actual = await setup.client.request("GetVideoSettings")
    desired = desiredVideo()
  if not actual.matchesDesired(desired):
    discard await setup.change("SetVideoSettings", desired,
      "Set video to " & $CanvasWidth & "x" & $CanvasHeight & " at " &
      $FramesPerSecond & " fps.")

proc requireNoGlobalAudio(client: ObsClient, collection: string) {.async.} =
  ## Refuse a collection with global desktop or mic audio devices.
  ## Removing an input does not clear OBS's global audio channel, so these
  ## must be disabled in OBS Settings > Audio rather than removed here.
  let special = await client.request("GetSpecialInputs")
  var enabled: seq[string]
  for key in SpecialInputKeys:
    let name = special{key}.getStr()
    if name.len > 0:
      enabled.add(name)
  if enabled.len > 0:
    raise setupError("Scene collection \"" & collection &
      "\" has global audio devices enabled (" & enabled.join(", ") &
      "); disable them in OBS Settings > Audio and run setup again.")

proc requireInputKinds(client: ObsClient) {.async.} =
  ## Require the installed OBS to provide every project input kind.
  let kinds = stringsIn((await client.request("GetInputKindList",
    %*{"unversioned": false})){"inputKinds"})
  for kind in [VideoKind, AudioKind, MicKind]:
    if kind notin kinds:
      raise setupError("OBS lacks input kind \"" & kind & "\".")

proc ensureScene(setup: OnlineSetup) {.async.} =
  ## Make the project scene the program scene and the collection's only scene.
  ## Without removeExtras only an empty OBS default scene may be removed.
  let
    sceneName = setup.spec.scene
    scenes = await setup.client.request("GetSceneList")
  var names: seq[string]
  for scene in scenes{"scenes"}:
    names.add(scene{"sceneName"}.getStr())
  if sceneName notin names:
    discard await setup.change("CreateScene", %*{"sceneName": sceneName},
      "Created scene \"" & sceneName & "\".")
  if scenes{"currentProgramSceneName"}.getStr() != sceneName:
    discard await setup.change("SetCurrentProgramScene",
      %*{"sceneName": sceneName}, "Showed scene \"" & sceneName & "\".")
  for name in names:
    if name != sceneName:
      if not setup.removeExtras:
        let items = (await setup.client.request("GetSceneItemList",
          %*{"sceneName": name})){"sceneItems"}
        if name != DefaultSceneName or items == nil or items.kind != JArray or items.len > 0:
          raise setupError("Scene collection \"" & setup.spec.collection &
            "\" has scene \"" & name & "\"; setup removes no scenes it did not create.")
      discard await setup.change("RemoveScene", %*{"sceneName": name},
        "Removed scene \"" & name & "\".")

proc projectInputs(spec: ObsProjectSpec, micSettings: JsonNode):
    array[3, tuple[name, kind: string, settings: JsonNode, muted: bool]] =
  ## Return the project inputs with the settings and mute state used on creation.
  [
    (name: spec.video, kind: VideoKind, settings: newJObject(), muted: false),
    (name: spec.audio, kind: AudioKind, settings: applicationAudioSettings(), muted: false),
    (name: spec.mic, kind: MicKind, settings: micSettings, muted: true)
  ]

proc ensureInputs(setup: OnlineSetup, micSettings = newJObject()) {.async.} =
  ## Create missing project inputs; with removeExtras, remove other capture inputs.
  let listed = await setup.client.request("GetInputList")
  var existing: seq[tuple[name, kind: string]]
  for input in listed{"inputs"}:
    existing.add((input{"inputName"}.getStr(), input{"inputKind"}.getStr()))
  for want in projectInputs(setup.spec, micSettings):
    var found = false
    for input in existing:
      if input.name == want.name:
        found = true
        if input.kind != want.kind:
          raise setupError("OBS input \"" & want.name & "\" is \"" & input.kind &
            "\"; expected \"" & want.kind & "\". Remove or rename it and run setup again.")
    if not found:
      discard await setup.change("CreateInput", %*{
        "sceneName": setup.spec.scene, "inputName": want.name,
        "inputKind": want.kind, "inputSettings": want.settings,
        "sceneItemEnabled": true
      }, "Created input \"" & want.name & "\" (" & want.kind & ").")
      if want.muted:
        discard await setup.change("SetInputMute",
          %*{"inputName": want.name, "inputMuted": true},
          "Muted new input \"" & want.name & "\".")
  if setup.removeExtras:
    for input in existing:
      if input.kind in CaptureInputKinds and
          input.name notin [setup.spec.video, setup.spec.audio, setup.spec.mic]:
        discard await setup.change("RemoveInput", %*{"inputName": input.name},
          "Removed capture input \"" & input.name & "\" (" & input.kind & ").")

proc ensureAudioSettings(setup: OnlineSetup) {.async.} =
  ## Keep the project audio capture limited to one matched application.
  ## The target application itself is left to the runtime binding.
  let
    current = await setup.client.request("GetInputSettings",
      %*{"inputName": setup.spec.audio})
    desired = applicationAudioSettings()
  if not current{"inputSettings"}.matchesDesired(desired):
    discard await setup.change("SetInputSettings", %*{
      "inputName": setup.spec.audio, "inputSettings": desired, "overlay": true
    }, "Set \"" & setup.spec.audio & "\" to capture one matched application.")

proc ensureSceneItems(setup: OnlineSetup) {.async.} =
  ## Show each project input in the project scene and fit the video to the canvas.
  let sceneName = setup.spec.scene
  var items = (await setup.client.request("GetSceneItemList",
    %*{"sceneName": sceneName})){"sceneItems"}
  for name in [setup.spec.video, setup.spec.audio, setup.spec.mic]:
    var
      itemId = -1
      enabled = false
    for item in items:
      if item{"sourceName"}.getStr() == name and itemId < 0:
        itemId = item{"sceneItemId"}.getInt()
        enabled = item{"sceneItemEnabled"}.getBool()
    if itemId < 0:
      let created = await setup.change("CreateSceneItem", %*{
        "sceneName": sceneName, "sourceName": name, "sceneItemEnabled": true
      }, "Added \"" & name & "\" to scene \"" & sceneName & "\".")
      itemId = created{"sceneItemId"}.getInt(-1)
      if itemId < 0:
        raise setupError("OBS did not report a scene item id for \"" & name & "\".")
    elif not enabled:
      discard await setup.change("SetSceneItemEnabled", %*{
        "sceneName": sceneName, "sceneItemId": itemId, "sceneItemEnabled": true
      }, "Enabled \"" & name & "\" in scene \"" & sceneName & "\".")
    if name == setup.spec.video:
      let
        transform = (await setup.client.request("GetSceneItemTransform", %*{
          "sceneName": sceneName, "sceneItemId": itemId})){"sceneItemTransform"}
        desired = desiredTransform()
      if not transform.matchesDesired(desired):
        discard await setup.change("SetSceneItemTransform", %*{
          "sceneName": sceneName, "sceneItemId": itemId,
          "sceneItemTransform": desired
        }, "Fit \"" & name & "\" inside the " & $CanvasWidth & "x" &
          $CanvasHeight & " canvas.")

proc ensureAudioRouting(setup: OnlineSetup, inputName: string,
    tracks: seq[int]) {.async.} =
  ## Route one audio input to exactly the given tracks with monitoring off.
  let
    actualTracks = (await setup.client.request("GetInputAudioTracks",
      %*{"inputName": inputName})){"inputAudioTracks"}
    desiredTracks = trackMap(tracks)
  if not actualTracks.matchesDesired(desiredTracks):
    discard await setup.change("SetInputAudioTracks", %*{
      "inputName": inputName, "inputAudioTracks": desiredTracks
    }, "Routed \"" & inputName & "\" to tracks " & tracks.join("+") & ".")
  let monitor = (await setup.client.request("GetInputAudioMonitorType",
    %*{"inputName": inputName})){"monitorType"}.getStr()
  if monitor != MonitorOff:
    discard await setup.change("SetInputAudioMonitorType", %*{
      "inputName": inputName, "monitorType": MonitorOff
    }, "Turned off monitoring for \"" & inputName & "\".")

proc ensureProjectSources(setup: OnlineSetup, micSettings = newJObject()) {.async.} =
  ## Provision the active collection's scene, inputs, scene items, and audio tracks.
  await setup.ensureScene()
  await setup.ensureInputs(micSettings)
  await setup.ensureAudioSettings()
  await setup.ensureSceneItems()
  await setup.ensureAudioRouting(setup.spec.audio, @GameTracks)
  await setup.ensureAudioRouting(setup.spec.mic, @MicTracks)

proc bindTarget(setup: OnlineSetup, inputName, inputKind: string): Future[bool] {.async.} =
  ## Point one input at a running Minecraft, reporting whether it is bound.
  await setup.client.requireIdle()
  if setup.liveTargets:
    var target = ""
    if inputKind == VideoKind:
      target = minecraftVideoTarget()
    else:
      try: target = minecraftAudioTarget()
      except ObsError as error: setup.log(error.msg)
    if target.len > 0:
      result = await setup.client.bindMinecraftInput(inputName, inputKind, target)
  else:
    result = await setup.client.bindMinecraftInput(inputName, inputKind)
  if not result:
    setup.log("Minecraft is not running; \"" & inputName &
      "\" keeps its target until the Knobby bridge binds it.")

proc prepareOnline*(client: ObsClient, log: SetupLog = logStderr, liveTargets = false):
    Future[OnlineReport] {.async.} =
  ## Provision the Minecraft AI Demos profile and collection through OBS.
  ## Other profiles and collections are never modified or removed.
  let setup = OnlineSetup(client: client, spec: projectSpec(MinecraftProject),
    removeExtras: true, log: log, liveTargets: liveTargets)
  await client.requireIdle()
  await setup.ensureProfile()
  await setup.ensureCollection()
  await setup.ensureVideo()
  await client.requireNoGlobalAudio(setup.spec.collection)
  await client.requireInputKinds()
  await setup.ensureProjectSources()
  result.minecraftVideoBound = await setup.bindTarget(ObsVideoName, VideoKind)
  result.minecraftAudioBound = await setup.bindTarget(ObsAudioName, AudioKind)
  result.changes = setup.changes

proc defaultObsConfigDir*(): string =
  ## Return OBS's Linux configuration directory, honoring XDG_CONFIG_HOME.
  getConfigDir() / ObsConfigDirName

proc defaultRecordDir*(): string =
  ## Return the Minecraft recording directory in the user's home.
  getHomeDir() / DefaultRecordRelativePath

proc defaultFirefoxRecordDir*(): string =
  ## Return the Firefox demo recording directory in the user's home.
  getHomeDir() / projectSpec(FirefoxProject).recordDirectory

proc iniEscape(value: string): string =
  ## Escape a value the way libobs config_save does.
  value.multiReplace(("\\", "\\\\"), ("\r", "\\r"), ("\n", "\\n"))

proc iniSectionName(line: string): string =
  ## Return the section named by a header line, or "" for other lines.
  let stripped = line.strip()
  if stripped.len > 2 and stripped[0] == '[' and stripped[^1] == ']':
    result = stripped[1..^2]

proc iniKey(line: string): string =
  ## Return the key of a key=value line, or "".
  let separator = line.find('=')
  if separator > 0:
    result = line[0..<separator].strip()

proc iniValue*(text, section, key: string): string =
  ## Read one raw value from libobs INI text, or "" when absent.
  var current = ""
  for line in text.splitLines():
    let header = iniSectionName(line)
    if header.len > 0:
      current = header
    elif current == section and iniKey(line) == key:
      return line[line.find('=') + 1..^1]

proc setIniValues*(text: string, values: openArray[IniValue]): string =
  ## Set keys in libobs INI text, preserving every other line and its order.
  var lines = text.split('\n')
  if lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  for item in values:
    let line = item.key & "=" & iniEscape(item.value)
    var start = -1
    for index, existing in lines:
      if iniSectionName(existing) == item.section:
        start = index
        break
    if start < 0:
      if lines.len > 0 and lines[^1].strip().len > 0:
        lines.add("")
      lines.add("[" & item.section & "]")
      lines.add(line)
      continue
    var
      finish = lines.len
      replaced = false
    for index in start + 1..<lines.len:
      if iniSectionName(lines[index]).len > 0:
        finish = index
        break
    for index in start + 1..<finish:
      if iniKey(lines[index]) == item.key:
        lines[index] = line
        replaced = true
        break
    if not replaced:
      var insertAt = finish
      while insertAt > start + 1 and lines[insertAt - 1].strip().len == 0:
        dec insertAt
      lines.insert(line, insertAt)
  result = lines.join("\n") & "\n"

proc recordingIniValues*(recordDir: string): seq[IniValue] =
  ## Return the advanced-output recording keys OBS 32 reads from basic.ini.
  let recorded = trackMask(GameTracks) or trackMask(MicTracks)
  result = @[
    ("Output", "Mode", "Advanced"),
    ("AdvOut", "RecType", "Standard"),
    ("AdvOut", "RecFilePath", recordDir),
    ("AdvOut", "RecFormat2", RecordFormat),
    ("AdvOut", "RecEncoder", RecordEncoderId),
    ("AdvOut", "RecAudioEncoder", RecordAudioEncoderId),
    ("AdvOut", "RecUseRescale", "false"),
    ("AdvOut", "RecTracks", $recorded),
    ("Video", "AutoRemux", "true"),
    (AudioSection, SampleRateKey, RequiredSampleRate),
    (AudioSection, ChannelSetupKey, RequiredChannelSetup)
  ]
  for track in 1..TrackCount:
    if (recorded and (1 shl (track - 1))) != 0:
      result.add(("AdvOut", "Track" & $track & "Bitrate", $RecordAudioBitrateKbps))

proc recordEncoderJson*(existing, renderDevice: string): string =
  ## Merge VAAPI CQP settings into existing recordEncoder.json text.
  var settings = if existing.strip().len == 0: newJObject() else: parseJson(existing)
  if settings.kind != JObject:
    raise setupError(RecordEncoderFile & " does not contain a JSON object.")
  settings["vaapi_device"] = %renderDevice
  settings["rate_control"] = %RecordRateControl
  settings["qp"] = %RecordQp
  settings["profile"] = %100
  settings["keyint_sec"] = %2
  result = settings.pretty() & "\n"

proc findProfileDir*(configDir, profileName: string): string =
  ## Locate the one profile directory whose basic.ini names the profile.
  ## Like OBS, a basic.ini without a name falls back to its directory name.
  let profilesDir = configDir / ProfilesRelativePath
  if not dirExists(profilesDir):
    raise setupError("OBS profiles directory " & profilesDir & " does not exist.")
  var matches: seq[string]
  for kind, path in walkDir(profilesDir):
    let settingsPath = path / ProfileSettingsFile
    if kind in {pcDir, pcLinkToDir} and fileExists(settingsPath):
      var name = iniValue(readFile(settingsPath), ProfileNameSection, ProfileNameKey)
      if name.len == 0:
        name = path.lastPathPart
      if name == profileName:
        matches.add(path)
  if matches.len == 0:
    raise setupError("No OBS profile named \"" & profileName & "\" in " &
      profilesDir & "; run prepare-online first.")
  if matches.len > 1:
    raise setupError("Several OBS profiles are named \"" & profileName & "\": " &
      matches.join(", "))
  result = matches[0]

proc writeNewPrivate*(path, content: string) =
  ## Create a new 0600 file, failing if it exists, and flush it to disk.
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC,
    PrivateFileMode.Mode)
  if fd < 0:
    raiseOSError(osLastError(), path)
  var written = 0
  while written < content.len:
    let count = posix.write(fd, unsafeAddr content[written], content.len - written)
    if count < 0:
      let error = osLastError()
      discard posix.close(fd)
      raiseOSError(error, path)
    written += count
  if fsync(fd) != 0:
    let error = osLastError()
    discard posix.close(fd)
    raiseOSError(error, path)
  if posix.close(fd) != 0:
    raiseOSError(osLastError(), path)

proc syncDir(path: string) =
  ## Flush a directory entry change to disk.
  let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC)
  if fd < 0:
    raiseOSError(osLastError(), path)
  let synced = fsync(fd)
  discard posix.close(fd)
  if synced != 0:
    raiseOSError(osLastError(), path)

proc replacePrivate*(path, content, stamp: string): string =
  ## Atomically replace a file with 0600 content, first keeping a 0600 backup.
  ## Returns the backup path, or "" when the file did not exist.
  if fileExists(path):
    result = path & BackupInfix & stamp
    writeNewPrivate(result, readFile(path))
  let temporary = path & TempInfix & $getpid()
  writeNewPrivate(temporary, content)
  try:
    moveFile(temporary, path)
  except OSError:
    removeFile(temporary)
    raise
  syncDir(path.parentDir)

proc requireRenderDevice*(renderDevice: string) =
  ## Require an absolute path to an existing character device.
  var info: Stat
  if not renderDevice.isAbsolute:
    raise setupError("Render device " & renderDevice & " is not an absolute path.")
  if stat(renderDevice.cstring, info) != 0:
    raise setupError("Render device " & renderDevice & " does not exist.")
  if not S_ISCHR(info.st_mode):
    raise setupError("Render device " & renderDevice & " is not a character device.")

proc writeProfileRecording(configDir, profileName, renderDevice, recordDir,
    stamp: string): seq[string] =
  ## Write one profile's recording settings, keeping private backups.
  ## Callers must ensure OBS cannot overwrite the profile meanwhile.
  requireRenderDevice(renderDevice)
  if not recordDir.isAbsolute:
    raise setupError("Recording directory " & recordDir & " is not an absolute path.")
  let
    profileDir = findProfileDir(configDir, profileName)
    iniPath = profileDir / ProfileSettingsFile
    encoderPath = profileDir / RecordEncoderFile
  var values = recordingIniValues(recordDir)
  if profileName == projectSpec(FirefoxProject).profile:
    values.add(@[("Video", "BaseCX", $CanvasWidth), ("Video", "BaseCY", $CanvasHeight),
      ("Video", "OutputCX", $CanvasWidth), ("Video", "OutputCY", $CanvasHeight),
      ("Video", "FPSType", "2"), ("Video", "FPSNum", $FramesPerSecond), ("Video", "FPSDen", "1")])
  let
    iniText = setIniValues(readFile(iniPath), values)
    encoderText = recordEncoderJson(
      if fileExists(encoderPath): readFile(encoderPath) else: "", renderDevice)
  if not dirExists(recordDir):
    createDir(recordDir)
    result.add("Created recording directory " & recordDir & ".")
  for (path, content) in [(iniPath, iniText), (encoderPath, encoderText)]:
    let existed = fileExists(path)
    if not existed or readFile(path) != content:
      let backup = replacePrivate(path, content, stamp)
      result.add(if existed: "Updated " & path & " (backup " & backup & ")."
        else: "Created " & path & ".")

proc configureOffline*(configDir, renderDevice, recordDir: string,
    stamp = now().format(BackupStampFormat)): seq[string] =
  ## Write the project profile's recording settings; OBS must not be running.
  ## Returns one line per changed file or created directory.
  writeProfileRecording(configDir, ObsProfileName, renderDevice, recordDir, stamp)

proc configureInactiveProfile*(client: ObsClient, configDir, profileName,
    renderDevice, recordDir: string, stamp = now().format(BackupStampFormat)):
    Future[seq[string]] {.async.} =
  ## Write an existing but inactive profile's recording files while OBS runs.
  ## OBS reads a profile's basic.ini and encoder settings only when activating
  ## it and saves only the active profile, so fresh read-only queries must show
  ## OBS idle on another profile first. Returns one line per changed file.
  await client.requireIdle()
  let profiles = await client.request("GetProfileList")
  if profileName notin stringsIn(profiles{"profiles"}):
    raise setupError("OBS has no profile named \"" & profileName & "\".")
  if profiles{"currentProfileName"}.getStr() == profileName:
    raise setupError("Profile \"" & profileName & "\" is active in OBS; setup " &
      "writes only inactive profile files. Switch OBS to another profile and run setup again.")
  result = writeProfileRecording(configDir, profileName, renderDevice, recordDir, stamp)
  if (await client.currentProfile()) == profileName:
    raise setupError("OBS switched to profile \"" & profileName &
      "\" while setup wrote its files; switch away and run setup again.")

proc readSelection*(client: ObsClient): Future[ObsSelection] {.async.} =
  ## Read the active profile, scene collection, and program scene.
  result.profile = await client.currentProfile()
  result.collection = await client.currentCollection()
  result.programScene = (await client.request("GetSceneList")){
    "currentProgramSceneName"}.getStr()

proc requireSharedAudioFormat(client: ObsClient) {.async.} =
  ## Refuse a starting profile whose audio format would make a switch prompt for an OBS restart.
  for (key, required) in [(SampleRateKey, RequiredSampleRate),
      (ChannelSetupKey, RequiredChannelSetup)]:
    let value = (await client.request("GetProfileParameter", %*{
      "parameterCategory": AudioSection, "parameterName": key})){"parameterValue"}
    if value == nil or value.kind != JString or value.getStr() != required:
      raise setupError("The active OBS profile uses " & AudioSection & " " & key &
        " " & $value & "; setup needs " & required & " so switching profiles " &
        "does not ask to restart OBS.")

proc requireFileAudioFormat(iniText, profileName: string) =
  ## Refuse an inactive profile whose saved audio format differs from the required one.
  for (key, required) in [(SampleRateKey, RequiredSampleRate),
      (ChannelSetupKey, RequiredChannelSetup)]:
    let value = iniValue(iniText, AudioSection, key)
    if value.len > 0 and value != required:
      raise setupError("Profile \"" & profileName & "\" uses " & AudioSection &
        " " & key & " " & value & "; setup needs " & required &
        ". Change it in that profile or remove the profile, then run setup again.")

proc minecraftRenderDevice*(configDir: string): string =
  ## Read the VAAPI render device from the Minecraft profile's recording encoder.
  ## Only the device path is reused; no other profile settings are copied.
  let
    profileDir = findProfileDir(configDir, projectSpec(MinecraftProject).profile)
    encoder = iniValue(readFile(profileDir / ProfileSettingsFile), "AdvOut", "RecEncoder")
    encoderPath = profileDir / RecordEncoderFile
  if encoder != RecordEncoderId or not fileExists(encoderPath):
    raise setupError("Profile \"" & projectSpec(MinecraftProject).profile &
      "\" does not record with " & RecordEncoderId & "; pass --render-device PATH.")
  let settings = parseJson(readFile(encoderPath))
  if settings.kind != JObject or settings{"vaapi_device"}.getStr().len == 0:
    raise setupError(encoderPath & " names no vaapi_device; pass --render-device PATH.")
  result = settings["vaapi_device"].getStr()

proc requireFirefoxProfileFiles(client: ObsClient, configDir: string) {.async.} =
  ## Check an existing Firefox profile's files before any switch, refusing malformed ones.
  let name = projectSpec(FirefoxProject).profile
  if name in stringsIn((await client.request("GetProfileList")){"profiles"}):
    let
      profileDir = findProfileDir(configDir, name)
      encoderPath = profileDir / RecordEncoderFile
    requireFileAudioFormat(readFile(profileDir / ProfileSettingsFile), name)
    if fileExists(encoderPath):
      discard recordEncoderJson(readFile(encoderPath), "")

proc minecraftMicSettings(client: ObsClient, original: ObsSelection): Future[JsonNode] {.async.} =
  ## Read the Minecraft commentary microphone choice for a new Firefox commentary input.
  result = newJObject()
  let minecraft = projectSpec(MinecraftProject)
  if original.collection == minecraft.collection:
    for input in (await client.request("GetInputList")){"inputs"}:
      if input{"inputName"}.getStr() == minecraft.mic and
          input{"inputKind"}.getStr() == MicKind:
        let settings = (await client.request("GetInputSettings",
          %*{"inputName": minecraft.mic})){"inputSettings"}
        if settings{MicDeviceKey} != nil and settings[MicDeviceKey].kind == JString:
          result[MicDeviceKey] = settings[MicDeviceKey]

proc requireOwnFirefoxCollection(setup: OnlineSetup) {.async.} =
  ## Refuse an active Firefox collection holding anything setup did not create.
  let spec = setup.spec
  await setup.client.requireNoGlobalAudio(spec.collection)
  for input in (await setup.client.request("GetInputList")){"inputs"}:
    let
      name = input{"inputName"}.getStr()
      kind = input{"inputKind"}.getStr()
    var known = false
    for want in projectInputs(spec, newJObject()):
      if name == want.name and kind == want.kind:
        known = true
    if not known:
      raise setupError("Scene collection \"" & spec.collection & "\" has input \"" &
        name & "\" (" & kind & "); setup changes no inputs it did not create. " &
        "Remove or rename it in OBS, then run setup again.")
  for scene in (await setup.client.request("GetSceneList")){"scenes"}:
    let name = scene{"sceneName"}.getStr()
    if name notin [spec.scene, DefaultSceneName]:
      raise setupError("Scene collection \"" & spec.collection & "\" has scene \"" &
        name & "\"; setup changes no scenes it did not create.")
    for item in (await setup.client.request("GetSceneItemList",
        %*{"sceneName": name})){"sceneItems"}:
      let source = item{"sourceName"}.getStr()
      if name == DefaultSceneName or source notin [spec.video, spec.audio, spec.mic]:
        raise setupError("Scene \"" & name & "\" in \"" & spec.collection &
          "\" shows \"" & source & "\"; setup changes no scene items it did not create.")

proc plainMessage(error: ref Exception): string =
  ## Return an exception message without the async traceback awaiting appends.
  ## Async re-raising truncates a message at an embedded traceback header.
  let header = error.msg.find(AsyncTracebackHeader)
  result = if header < 0: error.msg else: error.msg[0..<header]

proc restoreSelection(setup: OnlineSetup, original: ObsSelection) {.async.} =
  ## Return OBS to the original profile, then collection, then program scene.
  ## The profile goes first so the original collection loads under its own profile.
  if (await setup.client.currentProfile()) != original.profile:
    discard await setup.change("SetCurrentProfile", %*{"profileName": original.profile},
      "Restored profile \"" & original.profile & "\".")
  if (await setup.client.currentCollection()) != original.collection:
    discard await setup.change("SetCurrentSceneCollection",
      %*{"sceneCollectionName": original.collection},
      "Restored scene collection \"" & original.collection & "\".")
  if original.programScene.len > 0 and (await setup.client.request("GetSceneList")){
      "currentProgramSceneName"}.getStr() != original.programScene:
    discard await setup.change("SetCurrentProgramScene",
      %*{"sceneName": original.programScene},
      "Restored program scene \"" & original.programScene & "\".")
  let restored = await setup.client.readSelection()
  if restored != original:
    raise setupError("OBS shows profile \"" & restored.profile & "\", collection \"" &
      restored.collection & "\", scene \"" & restored.programScene & "\" after restoring.")

proc provisionFirefoxSelection(setup: OnlineSetup, micSettings: JsonNode) {.async.} =
  ## Select or create the Firefox collection and profile, then provision them.
  ## The collection switches first so the original collection never loads
  ## under the Firefox profile.
  await setup.ensureCollection()
  await setup.requireOwnFirefoxCollection()
  await setup.ensureProfile()
  await setup.ensureVideo()
  await setup.ensureProjectSources(micSettings)

proc requireConfigLocations(configDir: string) =
  ## Refuse copied OBS configurations whose absolute storage paths still point outside configDir.
  let globalPath = configDir / "global.ini"
  if fileExists(globalPath):
    let text = readFile(globalPath)
    for key in ["Configuration", "Profiles", "SceneCollections"]:
      let base = iniValue(text, "Locations", key)
      if base.len > 0 and (base / ObsConfigDirName).normalizedPath() != configDir.absolutePath().normalizedPath():
        raise setupError("OBS Locations." & key & " points outside " & configDir &
          "; use the actual OBS storage directory before provisioning.")

proc provisionFirefox*(client: ObsClient, configDir: string, renderDevice = "",
    recordDir = defaultFirefoxRecordDir(), log: SetupLog = logStderr,
    stamp = now().format(BackupStampFormat)): Future[FirefoxReport] {.async.} =
  ## Provision the Firefox Demos profile and collection while OBS stays running.
  ## OBS temporarily shows the Firefox setup, then returns to the original
  ## profile, collection, and program scene; the now inactive Firefox profile
  ## then receives its recording files. Every OBS change first rechecks that
  ## OBS is neither recording nor streaming, and the restore happens only then.
  ## The video and audio captures start unbound for the runtime to bind.
  let
    firefox = projectSpec(FirefoxProject)
    setup = OnlineSetup(client: client, spec: firefox, removeExtras: false, log: log)
  requireConfigLocations(configDir)
  await client.requireIdle()
  let original = await client.readSelection()
  if original.profile == firefox.profile or original.collection == firefox.collection:
    raise setupError("OBS is showing the " & firefox.label & " setup; switch OBS " &
      "to another profile and scene collection, then run setup again.")
  await client.requireSharedAudioFormat()
  await client.requireInputKinds()
  result.renderDevice = if renderDevice.len > 0: renderDevice
    else: minecraftRenderDevice(configDir)
  requireRenderDevice(result.renderDevice)
  if not recordDir.isAbsolute:
    raise setupError("Recording directory " & recordDir & " is not an absolute path.")
  await client.requireFirefoxProfileFiles(configDir)
  let micSettings = await client.minecraftMicSettings(original)
  result.original = original
  let provisioning = setup.provisionFirefoxSelection(micSettings)
  yield provisioning
  let restoring = setup.restoreSelection(original)
  yield restoring
  if restoring.failed:
    let earlier = if provisioning.failed: plainMessage(provisioning.error) & " " else: ""
    raise setupError(earlier & "OBS was not returned to profile \"" & original.profile &
      "\" and scene collection \"" & original.collection & "\": " &
      plainMessage(restoring.error) & " Switch back in OBS when no output is active.")
  if provisioning.failed:
    raise provisioning.error
  result.changes = setup.changes
  result.files = await client.configureInactiveProfile(configDir, firefox.profile,
    result.renderDevice, recordDir, stamp)
  for line in result.files:
    log(line)

proc obsRunning(): bool =
  ## Check /proc for a running OBS process.
  for kind, path in walkDir("/proc"):
    if kind == pcDir and path.lastPathPart.allCharsInSet(Digits):
      try:
        if readFile(path / "comm").strip() in ObsProcessNames:
          return true
      except IOError:
        # Processes may exit between listing and reading.
        discard

proc runPrepareOnline() =
  ## Connect to the local OBS and provision the project, printing a JSON report.
  let
    settings = loadObsSettings()
    client = waitFor connectObs(settings.url, settings.password)
  try:
    let report = waitFor client.prepareOnline(liveTargets = true)
    if report.changes.len == 0:
      logStderr("OBS already matches the Minecraft AI Demos setup.")
    stdout.writeLine($ %*{
      "changes": report.changes,
      "minecraftVideoBound": report.minecraftVideoBound,
      "minecraftAudioBound": report.minecraftAudioBound
    })
  finally:
    client.close()

proc parseFileOptions(args: seq[string], recordDir: string):
    tuple[renderDevice, configDir, recordDir: string] =
  ## Parse the render device, OBS configuration, and recording directory options.
  result = ("", defaultObsConfigDir(), recordDir)
  var index = 0
  while index < args.len:
    if index + 1 >= args.len:
      raise setupError("Option " & args[index] & " needs a value.\n" & Usage)
    case args[index]
    of "--render-device": result.renderDevice = args[index + 1]
    of "--config-dir": result.configDir = args[index + 1]
    of "--record-dir": result.recordDir = args[index + 1]
    else: raise setupError("Unknown option " & args[index] & ".\n" & Usage)
    index += 2

proc runConfigureOffline(args: seq[string]) =
  ## Parse offline options, require OBS stopped, and write the profile files.
  let options = parseFileOptions(args, defaultRecordDir())
  if options.renderDevice.len == 0:
    raise setupError("configure-offline requires --render-device PATH.\n" & Usage)
  if obsRunning():
    raise setupError("OBS is running; quit OBS before configure-offline so it " &
      "cannot overwrite the profile.")
  let changes = configureOffline(options.configDir, options.renderDevice,
    options.recordDir)
  if changes.len == 0:
    logStderr("Profile recording settings are already current.")
  for line in changes:
    logStderr(line)
  stdout.writeLine($ %*{"changes": changes})

proc runProvisionFirefox(args: seq[string]) =
  ## Connect to the running OBS, provision the Firefox setup, and print a JSON report.
  let
    options = parseFileOptions(args, defaultFirefoxRecordDir())
    settings = loadObsSettings()
    client = waitFor connectObs(settings.url, settings.password)
  try:
    let report = waitFor client.provisionFirefox(options.configDir,
      options.renderDevice, options.recordDir)
    stdout.writeLine($ %*{
      "changes": report.changes,
      "files": report.files,
      "restored": %*{"profile": report.original.profile,
        "collection": report.original.collection,
        "programScene": report.original.programScene},
      "renderDevice": report.renderDevice
    })
  finally:
    client.close()

proc main() =
  ## Dispatch the setup subcommands.
  let args = commandLineParams()
  if args.len == 0:
    stderr.writeLine(Usage)
    quit(UsageExitCode)
  try:
    case args[0]
    of "prepare-online":
      if args.len != 1:
        stderr.writeLine(Usage)
        quit(UsageExitCode)
      runPrepareOnline()
    of "configure-offline":
      runConfigureOffline(args[1..^1])
    of "provision-firefox":
      runProvisionFirefox(args[1..^1])
    else:
      stderr.writeLine(Usage)
      quit(UsageExitCode)
  except SetupError, ObsError:
    # Expected refusals and OBS failures need only their message.
    logStderr(getCurrentExceptionMsg())
    quit(FailureExitCode)

when isMainModule:
  main()

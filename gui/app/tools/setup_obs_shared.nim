import
  std/[asyncdispatch, json, os, strutils, sysrand, tables],
  ../src/obs_client,
  ./setup_obs

const
  SharedProfileName* = "Demo Recording"
  SharedProfileDirectory = "Demo_Recording"
  WowCollectionName* = "WoW Demos"
  WowSceneFile = "WoW_Demos.json"
  MarkerFile = ".knobby-shared-demos-v1"

type
  SharedSetupError* = object of CatchableError

proc required(node: JsonNode, key: string, kind: JsonNodeKind): JsonNode =
  ## Read a required field without treating malformed data as a safe default.
  result = node{key}
  if result.isNil or result.kind != kind:
    raise newException(SharedSetupError, "OBS response lacks " & key & ".")

proc requireSetupIdle*(record, stream: JsonNode) =
  ## Refuse provisioning during active, paused, reconnecting, or unknown outputs.
  if record.required("outputActive", JBool).getBool() or
      record.required("outputPaused", JBool).getBool() or
      stream.required("outputActive", JBool).getBool() or
      stream.required("outputReconnecting", JBool).getBool():
    raise newException(SharedSetupError, "OBS outputs are active; finish recording or streaming before setup.")

proc requireIdle(client: ObsClient) {.async.} =
  ## Check both output types immediately before creating inactive setup files.
  let
    record = await client.request("GetRecordStatus")
    stream = await client.request("GetStreamStatus")
  requireSetupIdle(record, stream)

proc newUuid(): string =
  ## Make a fresh OBS source UUID without sharing identities with existing collections.
  var bytes = urandom(16)
  bytes[6] = (bytes[6] and 15) or 64
  bytes[8] = (bytes[8] and 63) or 128
  for i, value in bytes:
    if i in [4, 6, 8, 10]: result.add('-')
    result.add(value.toHex(2).toLowerAscii())

proc namedSource(collection: JsonNode, name, kind: string): JsonNode =
  ## Resolve exactly one native OBS source with the expected kind.
  for source in collection.required("sources", JArray):
    if source{"name"}.getStr() == name:
      if not result.isNil or source{"id"}.getStr() != kind:
        raise newException(SharedSetupError, "Unexpected OBS source " & name & ".")
      result = source
  if result.isNil: raise newException(SharedSetupError, "Missing OBS source " & name & ".")

proc sharedProfileIni*(original, recordDirectory: string): string =
  ## Copy the known working profile, changing only its name and recording destination.
  if not recordDirectory.isAbsolute:
    raise newException(SharedSetupError, "Recording directory must be absolute.")
  if iniValue(original, "Output", "Mode") != "Advanced" or
      iniValue(original, "AdvOut", "RecTracks") != "7" or
      iniValue(original, "AdvOut", "RecType") != "Standard":
    raise newException(SharedSetupError, "Minecraft profile must use standard advanced recording with combined/game/commentary tracks before sharing.")
  result = setIniValues(original, @[("General", "Name", SharedProfileName),
    ("AdvOut", "RecFilePath", recordDirectory)])

proc wowCollection*(firefox, minecraft: JsonNode): JsonNode =
  ## Build one native WoW scene using only known window, application audio, and commentary sources.
  let
    oldNames = ["Firefox Video", "Firefox Audio", "Commentary", "Firefox"]
    names = ["WoW Video", "WoW Audio", "Commentary", "WoW"]
    kinds = ["xcomposite_input", "pipewire_audio_application_capture", "pulse_input_capture", "scene"]
  var
    sources = newJArray()
    ids = initTable[string, string]()
  for i, name in oldNames:
    let source = parseJson($namedSource(firefox, name, kinds[i]))
    ids[source.required("uuid", JString).getStr()] = newUuid()
    source["name"] = %names[i]
    source["uuid"] = %ids[source["uuid"].getStr()]
    source["hotkeys"] = newJObject()
    source["filters"] = newJArray()
    if i == 0:
      source["settings"] = %*{"capture_window": ""}
      source["mixers"] = %0
    elif i == 1:
      source["settings"] = %*{"TargetName": "", "CaptureMode": 0,
        "MatchPriorty": 1, "ExceptApp": false}
      source["mixers"] = %3
    elif i == 2:
      let originalMic = namedSource(minecraft, "Commentary", "pulse_input_capture")
      for key, value in originalMic:
        if key notin ["name", "id", "versioned_id", "uuid", "hotkeys", "muted", "mixers"]:
          source[key] = parseJson($value)
      source["muted"] = %true
      source["mixers"] = %5
    else:
      source["mixers"] = %0
      let items = source["settings"].required("items", JArray)
      if items.len != 3:
        raise newException(SharedSetupError, "Firefox scene has custom items; refusing to clone them.")
      for itemIndex in 0..<items.len:
        let item = items[itemIndex]
        if item["name"].getStr() != oldNames[itemIndex]:
          raise newException(SharedSetupError, "Firefox scene item order was customized; refusing to guess.")
        item["name"] = %names[itemIndex]
        let id = item.required("source_uuid", JString).getStr()
        if id notin ids: raise newException(SharedSetupError, "Firefox scene source reference is invalid.")
        item["source_uuid"] = %ids[id]
        item["visible"] = %true
    sources.add(source)
  result = %*{"name": WowCollectionName, "current_scene": "WoW", "current_program_scene": "WoW",
    "scene_order": [{"name": "WoW"}], "sources": sources,
    "groups": [], "canvases": [], "transitions": [], "modules": {},
    "current_transition": "Fade", "transition_duration": 300,
    "preview_locked": false, "scaling_enabled": false}
  if firefox{"version"} != nil: result["version"] = firefox["version"]

proc requireNativeLocations*(configDirectory, globalIni: string) =
  ## Reject inherited absolute OBS locations that point outside the intended storage root.
  for key in ["Configuration", "Profiles", "SceneCollections"]:
    let path = iniValue(globalIni, "Locations", key)
    if path.len > 0 and absolutePath(path).normalizedPath() != configDirectory.parentDir.normalizedPath():
      raise newException(SharedSetupError, "OBS " & key & " location differs from " & configDirectory & ".")

proc collectionFile(configDirectory, name: string): string =
  ## Resolve a unique native collection without guessing its sanitized filename.
  for path in walkFiles(configDirectory / "basic/scenes/*.json"):
    if parseFile(path){"name"}.getStr() == name:
      if result.len > 0: raise newException(SharedSetupError, "Duplicate scene collection " & name & ".")
      result = path
  if result.len == 0: raise newException(SharedSetupError, "Missing scene collection " & name & ".")

proc provisionSharedDemos*(client: ObsClient, configDirectory, recordingDirectory: string):
    Future[seq[string]] {.async.} =
  ## Create only new inactive files; never select a profile, collection, scene, or capture target.
  requireNativeLocations(configDirectory, readFile(configDirectory / "global.ini"))
  await client.requireIdle()
  let
    profiles = await client.request("GetProfileList")
    collections = await client.request("GetSceneCollectionList")
    currentProfile = profiles.required("currentProfileName", JString).getStr()
    currentCollection = collections.required("currentSceneCollectionName", JString).getStr()
    profilePath = configDirectory / "basic/profiles" / SharedProfileDirectory
    scenePath = configDirectory / "basic/scenes" / WowSceneFile
    marker = profilePath / MarkerFile
  let
    originalProfile = findProfileDir(configDirectory, "Minecraft AI Demos")
    profileText = sharedProfileIni(readFile(originalProfile / "basic.ini"), recordingDirectory)
    minecraft = parseFile(collectionFile(configDirectory, "Minecraft AI Demos"))
    firefox = parseFile(collectionFile(configDirectory, "Firefox Demos"))
    sceneText = wowCollection(firefox, minecraft).pretty()
  var presentProfile = false
  for profile in profiles.required("profiles", JArray):
    if profile.kind != JString: raise newException(SharedSetupError, "Malformed OBS profile list.")
    if profile.getStr() == SharedProfileName: presentProfile = true
  var presentCollection = false
  for collection in collections.required("sceneCollections", JArray):
    if collection.kind != JString: raise newException(SharedSetupError, "Malformed OBS collection list.")
    if collection.getStr() == WowCollectionName: presentCollection = true
  if (presentProfile or dirExists(profilePath)) and not fileExists(marker):
    raise newException(SharedSetupError, "Demo Recording already exists and is not Knobby-managed; nothing replaced.")
  if (presentCollection or fileExists(scenePath)) and not fileExists(marker):
    raise newException(SharedSetupError, "WoW Demos already exists; nothing replaced.")
  if fileExists(marker):
    if not fileExists(profilePath / "basic.ini"):
      raise newException(SharedSetupError, "Incomplete earlier demo installation; original profiles are preserved.")
    if fileExists(scenePath):
      result.add("Shared demo setup already exists; existing settings left unchanged.")
      return
  if currentProfile == SharedProfileName or currentCollection == WowCollectionName:
    raise newException(SharedSetupError, "New demo files are active in OBS; inactive setup was left unchanged.")
  createDir(recordingDirectory)
  let stage = configDirectory / (".knobby-shared-stage-" & newUuid())
  createDir(stage)
  setFilePermissions(stage, {fpUserRead, fpUserWrite, fpUserExec})
  defer: removeDir(stage)
  let stagedProfile = stage / "profile"
  if not fileExists(marker):
    createDir(stagedProfile)
    setFilePermissions(stagedProfile, {fpUserRead, fpUserWrite, fpUserExec})
    for kind, path in walkDir(originalProfile):
      if kind == pcFile and path.lastPathPart notin ["basic.ini", "basic.ini.bak"] and
          ".knobby-" notin path.lastPathPart:
        writeNewPrivate(stagedProfile / path.lastPathPart, readFile(path))
    writeNewPrivate(stagedProfile / "basic.ini", profileText)
    writeNewPrivate(stagedProfile / MarkerFile,
      "Knobby created this profile and WoW collection; reruns preserve all settings.\n")
  let stagedScene = stage / WowSceneFile
  writeNewPrivate(stagedScene, sceneText)
  await client.requireIdle()
  let freshProfiles = await client.request("GetProfileList")
  let freshCollections = await client.request("GetSceneCollectionList")
  if freshProfiles.required("currentProfileName", JString).getStr() != currentProfile or
      freshCollections.required("currentSceneCollectionName", JString).getStr() != currentCollection:
    raise newException(SharedSetupError, "OBS selection changed during preparation; nothing replaced.")
  if not fileExists(marker):
    if dirExists(profilePath):
      raise newException(SharedSetupError, "Demo profile appeared during setup; nothing replaced.")
    moveDir(stagedProfile, profilePath)
  createHardlink(stagedScene, scenePath)
  result.add("Created Demo Recording profile and WoW Demos collection without changing OBS selection.")
  result.add("Shared recordings: " & recordingDirectory)

proc main() =
  ## Provision the inactive shared profile and WoW collection through an idle, authenticated OBS connection.
  if commandLineParams() != @["--apply"]:
    quit("Usage: setup_obs_shared --apply", 2)
  let
    settings = loadObsSettings()
    client = waitFor connectObs(settings.url, settings.password)
  defer: client.close()
  for change in waitFor client.provisionSharedDemos(defaultObsConfigDir(), getHomeDir() / "Videos/Demos"):
    echo change

when isMainModule: main()

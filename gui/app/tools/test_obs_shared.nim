import
  std/[asyncdispatch, json, os, strutils, tempfiles, unittest],
  ../src/obs_client,
  ./[fake_obs, setup_obs_shared]

proc source(name, kind, uuid: string, settings: JsonNode): JsonNode =
  ## Build a tiny synthetic native OBS source without game or personal data.
  %*{"name": name, "id": kind, "versioned_id": kind, "uuid": uuid,
    "settings": settings, "mixers": 0, "muted": false, "hotkeys": {"old": [1]}}

proc firefoxCollection(): JsonNode =
  ## Provide the three standard source references of a dedicated demo scene.
  result = %*{"name": "Firefox Demos", "version": 2, "sources": []}
  result["sources"].add(source("Firefox Video", "xcomposite_input", "video-id",
    %*{"capture_window": "old-window"}))
  result["sources"].add(source("Firefox Audio", "pipewire_audio_application_capture", "audio-id",
    %*{"TargetName": "old-browser"}))
  result["sources"].add(source("Commentary", "pulse_input_capture", "mic-id", %*{"device_id": "default"}))
  result["sources"].add(source("Firefox", "scene", "scene-id", %*{"items": [
    {"name": "Firefox Video", "source_uuid": "video-id", "bounds": {"x": 1920, "y": 1080}},
    {"name": "Firefox Audio", "source_uuid": "audio-id"},
    {"name": "Commentary", "source_uuid": "mic-id"}]}))

proc minecraftCollection(): JsonNode =
  ## Include a custom human scene to ensure provisioning never mutates the source collection.
  %*{"name": "Minecraft AI Demos", "sources": [
    source("Commentary", "pulse_input_capture", "original-mic", %*{"device_id": "chosen-mic"}),
    source("wow", "scene", "human-scene", %*{"items": []})]}

const OriginalProfile = """[General]
Name=Minecraft AI Demos
[Output]
Mode=Advanced
[AdvOut]
RecType=Standard
RecTracks=7
RecFilePath=/original
RecEncoder=custom-human-encoder
[Video]
BaseCX=1920
BaseCY=1080
OutputCX=1920
OutputCY=1080
FPSType=2
FPSNum=60
FPSDen=1
[Stream1]
HumanPreference=keep-this
"""

suite "shared OBS profile and WoW collection":
  test "shared profile changes only name and recording directory":
    let actual = sharedProfileIni(OriginalProfile, "/videos/demos")
    check actual == OriginalProfile.replace("Name=Minecraft AI Demos", "Name=Demo Recording").replace(
      "RecFilePath=/original", "RecFilePath=/videos/demos")
    expect SharedSetupError: discard sharedProfileIni(OriginalProfile, "relative")
    expect SharedSetupError: discard sharedProfileIni(OriginalProfile.replace("RecTracks=7", "RecTracks=1"), "/videos")
    expect SharedSetupError: discard sharedProfileIni(OriginalProfile.replace("RecType=Standard", "RecType=FFmpeg"), "/videos")

  test "native WoW scene has fresh identities, exact empty targets and separate commentary":
    let
      firefox = firefoxCollection()
      minecraft = minecraftCollection()
      beforeFirefox = $firefox
      beforeMinecraft = $minecraft
      wow = wowCollection(firefox, minecraft)
    check $firefox == beforeFirefox and $minecraft == beforeMinecraft
    check wow["name"].getStr() == "WoW Demos"
    check wow["current_program_scene"].getStr() == "WoW"
    check wow["sources"].len == 4
    check wow["sources"][0]["settings"]["capture_window"].getStr() == ""
    check wow["sources"][1]["settings"] == %*{"TargetName": "", "CaptureMode": 0,
      "MatchPriorty": 1, "ExceptApp": false}
    check wow["sources"][1]["mixers"].getInt() == 3
    check wow["sources"][2]["mixers"].getInt() == 5
    check wow["sources"][2]["muted"].getBool()
    check wow["sources"][2]["settings"]["device_id"].getStr() == "chosen-mic"
    for i in 0..2:
      check wow["sources"][3]["settings"]["items"][i]["source_uuid"] == wow["sources"][i]["uuid"]
      check wow["sources"][i]["uuid"].getStr().len == 36
      check wow["sources"][i]["uuid"] != firefox["sources"][i]["uuid"]
      check wow["sources"][i]["hotkeys"].len == 0
    check wow["modules"].len == 0
    check not wow.hasKey("DesktopAudioDevice1")

  test "unsafe native references fail without mutation":
    let firefox = firefoxCollection()
    firefox["sources"][3]["settings"]["items"][0]["source_uuid"] = %"not-a-source"
    let before = $firefox
    expect SharedSetupError: discard wowCollection(firefox, minecraftCollection())
    check $firefox == before

  test "all active or unknown output states refuse provisioning":
    let
      record = %*{"outputActive": false, "outputPaused": false}
      stream = %*{"outputActive": false, "outputReconnecting": false}
    requireSetupIdle(record, stream)
    for field in ["outputActive", "outputPaused"]:
      let changed = record.copy()
      changed[field] = %true
      expect SharedSetupError: requireSetupIdle(changed, stream)
    for field in ["outputActive", "outputReconnecting"]:
      let changed = stream.copy()
      changed[field] = %true
      expect SharedSetupError: requireSetupIdle(record, changed)
    expect SharedSetupError: requireSetupIdle(%*{"outputActive": false}, stream)
    expect SharedSetupError: requireSetupIdle(record, %*{"outputActive": "false", "outputReconnecting": false})

  test "copied absolute OBS locations are refused":
    requireNativeLocations("/temporary/obs-studio", "[Locations]\nConfiguration=/temporary\nProfiles=/temporary\nSceneCollections=/temporary\n")
    expect SharedSetupError:
      requireNativeLocations("/temporary/obs-studio", "[Locations]\nProfiles=/real/home\n")

proc testFilesWithoutSelectionChanges() {.async.} =
  ## Use the real OBS client against a fake server and verify additive file writes only.
  let
    root = createTempDir("knobby-shared-", "")
    config = root / "obs-studio"
    originalProfile = config / "basic/profiles/Minecraft_AI_Demos"
    scenes = config / "basic/scenes"
    fake = newFakeObs("pw")
  defer:
    fake.stop()
    removeDir(root)
  createDir(originalProfile)
  createDir(scenes)
  writeFile(config / "global.ini", "[Locations]\nConfiguration=" & root & "\nProfiles=" & root & "\nSceneCollections=" & root & "\n")
  writeFile(originalProfile / "basic.ini", OriginalProfile)
  writeFile(originalProfile / "recordEncoder.json", "{\"humanEncoderSetting\":42}")
  writeFile(originalProfile / "service.json", "{\"syntheticStreamSetting\":\"keep\"}")
  writeFile(scenes / "minecraft.json", $minecraftCollection())
  writeFile(scenes / "firefox.json", $firefoxCollection())
  let client = await connectObs("ws://127.0.0.1:" & $fake.port, "pw")
  defer: client.close()
  fake.streaming = true
  var refused = false
  try:
    discard await client.provisionSharedDemos(config, root / "Videos/Demos")
  except SharedSetupError: refused = true
  doAssert refused
  doAssert not dirExists(config / "basic/profiles/Demo_Recording")
  fake.streaming = false
  refused = false
  try:
    discard await client.provisionSharedDemos(config, root / "Videos/Demos")
  except SharedSetupError: refused = true
  doAssert refused, "the independently pre-existing WoW collection must never be overwritten"
  doAssert not dirExists(config / "basic/profiles/Demo_Recording")
  fake.collections = @["Minecraft AI Demos", "Firefox Demos"]
  let changed = await client.provisionSharedDemos(config, root / "Videos/Demos")
  doAssert changed.len == 2
  doAssert readFile(originalProfile / "basic.ini") == OriginalProfile
  doAssert parseFile(scenes / "minecraft.json") == minecraftCollection()
  doAssert parseFile(scenes / "firefox.json") == firefoxCollection()
  let shared = config / "basic/profiles/Demo_Recording"
  doAssert readFile(shared / "recordEncoder.json") == readFile(originalProfile / "recordEncoder.json")
  doAssert readFile(shared / "service.json") == readFile(originalProfile / "service.json")
  doAssert getFilePermissions(shared / "basic.ini") == {fpUserRead, fpUserWrite}
  doAssert parseFile(scenes / "WoW_Demos.json")["current_scene"].getStr() == "WoW"
  writeFile(shared / "recordEncoder.json", "{\"humanChanged\":true}")
  discard await client.provisionSharedDemos(config, root / "Videos/Demos")
  doAssert readFile(shared / "recordEncoder.json") == "{\"humanChanged\":true}"
  removeFile(scenes / "WoW_Demos.json")
  discard await client.provisionSharedDemos(config, root / "Videos/Demos")
  doAssert fileExists(scenes / "WoW_Demos.json")
  doAssert readFile(shared / "recordEncoder.json") == "{\"humanChanged\":true}"
  for request in fake.requests: doAssert request.startsWith("Get"), request
  doAssert fake.profile == "Minecraft AI Demos" and fake.collection == "Minecraft AI Demos"
  echo "Inactive profile/native collection written; original configs and OBS selection untouched."

when isMainModule: waitFor testFilesWithoutSelectionChanges()

import
  std/[json, os, unittest],
  knobby/[firefox_demo_config, obs_projects]

suite "OBS demo setups":
  test "profiles and collections must match the same setup":
    for project in ObsProject:
      let spec = projectSpec(project)
      check projectId(spec.profile, spec.collection) == spec.id
    check projectId("Minecraft AI Demos", "Firefox Demos") == ""
    check projectId("Firefox Demos", "Minecraft AI Demos") == ""
    check projectId("Unknown", "Unknown") == ""
    check projectForOperation("selectMinecraft") == MinecraftProject
    check projectForOperation("selectFirefox") == FirefoxProject
    check projectForOperation("selectWow") == WowProject

  test "every setup accepts the shared demo profile and legacy pairs stay valid":
    check projectId(SharedDemoProfileName, "Minecraft AI Demos") == "minecraft"
    check projectId(SharedDemoProfileName, "Firefox Demos") == "firefox"
    check projectId(SharedDemoProfileName, "WoW Demos") == "wow"
    check projectId("Minecraft AI Demos", "Minecraft AI Demos") == "minecraft"
    check projectId("Firefox Demos", "Firefox Demos") == "firefox"
    check projectId("Minecraft AI Demos", "WoW Demos") == ""
    check projectId(SharedDemoProfileName, "Untitled") == ""
    let wow = projectSpec(WowProject)
    check wow.id == "wow" and wow.label == "WoW Demos" and wow.profile == SharedDemoProfileName
    check wow.collection == "WoW Demos" and wow.scene == "WoW" and wow.video == "WoW Video"
    check wow.audio == "WoW Audio" and wow.mic == "Commentary"
    check wow.recordDirectory == SharedDemoRecordDirectory
    check SharedDemoProfileName == "Demo Recording" and SharedDemoRecordDirectory == "Videos/Demos"
    let minecraft = projectSpec(MinecraftProject)
    check minecraft.preferredProfile(["Minecraft AI Demos", SharedDemoProfileName]) ==
      SharedDemoProfileName
    check minecraft.preferredProfile(["Minecraft AI Demos"]) == "Minecraft AI Demos"
    check minecraft.acceptsProfile("Minecraft AI Demos") and
      minecraft.acceptsProfile(SharedDemoProfileName)
    check not minecraft.acceptsProfile("Firefox Demos")
    expect ValueError: discard projectForOperation("open")

  test "dedicated Firefox identity is separate and configurable without shell commands":
    let defaults = parseFirefoxDemoConfig(newJObject())
    check defaults.windowClass == "knobby-firefox-demos"
    check defaults.audioLabel == "knobby-firefox"
    check defaults.profileDirectory.isAbsolute
    check defaults.startUrl == "about:blank"
    let configured = parseFirefoxDemoConfig(%*{"executable": "/custom/firefox",
      "profileDirectory": "/tmp/test-demo-profile", "windowClass": "work-demo",
      "audioLabel": "work-demo-audio", "startUrl": "http://127.0.0.1:1234/"})
    check configured.executable == "/custom/firefox"
    check configured.profileDirectory == "/tmp/test-demo-profile"
    check configured.windowClass == "work-demo"
    check configured.audioLabel == "work-demo-audio"
    check configured.startUrl == "http://127.0.0.1:1234/"

  test "Firefox settings reject broken types and relative profile paths":
    for invalid in [newJNull(), %*{"unknown": "value"}, %*{"executable": ""},
        %*{"windowClass": false}, %*{"audioLabel": "bad\u0000label"},
        %*{"profileDirectory": "relative/profile"}]:
      expect ValueError: discard parseFirefoxDemoConfig(invalid)

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

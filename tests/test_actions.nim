import
  std/[strutils, tables, unittest],
  knobby/[actions, audio_outputs, bindings, midi_events]

suite "browser fader targets":
  test "the second physical fader groups every named browser stream":
    let (controller, label, apps, games) = AppFaderBindings[0]
    check controller == 17
    check label == "Browsers"
    check not games
    for name in ["Firefox", "Firefox Nightly", "knobby-firefox", "Google Chrome",
        "google-chrome-stable", "Google Chrome Beta", "Chrome", "chrome-dev",
        "Chromium", "chromium-browser", "Chromium Browser Beta", "CHROMIUM"]:
      check streamMatches(AudioOutputStream(appName: name), apps, games)

  test "browser identities exclude Electron applications and unrelated streams":
    let (_, _, apps, games) = AppFaderBindings[0]
    for name in ["Discord", "Slack", "Electron", "Chromium Embedded Framework",
        "Chrome Cast", "Spotify", "World of Warcraft", "", "@DEFAULT_SINK@"]:
      check not streamMatches(AudioOutputStream(appName: name, mediaRole: "game"), apps, games)

  test "browser streams do not join the other application faders":
    for index in 1..2:
      let (_, _, apps, games) = AppFaderBindings[index]
      for name in ["Firefox", "Google Chrome", "Chromium"]:
        check not streamMatches(AudioOutputStream(appName: name), apps, games)

suite "isNewSinkInputEvent":
  test "matches new sink-input events":
    check isNewSinkInputEvent("Event 'new' on sink-input #18509")

  test "ignores other pactl events":
    check not isNewSinkInputEvent("Event 'change' on sink-input #18509")
    check not isNewSinkInputEvent("Event 'new' on client #612")
    check not isNewSinkInputEvent("Event 'remove' on sink-input #18509")

suite "parseSourceNames":
  test "keeps real inputs and skips monitor sources":
    let output = [
      "75\talsa_input.usb-Lenovo_Lenovo_Performance_Camera_145081A8-04.analog-stereo\tPipeWire\ts16le 2ch 16000Hz\tRUNNING",
      "77\talsa_output.pci-0000_19_00.6.iec958-stereo.monitor\tPipeWire\ts32le 2ch 48000Hz\tSUSPENDED",
      "37597\talsa_input.usb-Generic_BenQ_EX3210U-00.iec958-stereo\tPipeWire\ts24le 2ch 48000Hz\tRUNNING",
    ].join("\n")
    let names = parseSourceNames(output)
    check names == @[
      "alsa_input.usb-Lenovo_Lenovo_Performance_Camera_145081A8-04.analog-stereo",
      "alsa_input.usb-Generic_BenQ_EX3210U-00.iec958-stereo",
    ]

  test "ignores blank and malformed lines":
    check parseSourceNames("").len == 0
    check parseSourceNames("\n\njunk\n").len == 0

suite "isMuteReported":
  test "detects muted and unmuted reports":
    check isMuteReported("Mute: yes")
    check not isMuteReported("Mute: no")

suite "faderPercent":
  test "maps the full range linearly":
    check faderPercent(64) == 50
    check faderPercent(32) == 25
    check faderPercent(100) == 78

  test "snaps low endpoint to zero":
    check faderPercent(0) == 0
    check faderPercent(1) == 0
    check faderPercent(2) == 0

  test "snaps high endpoint to full volume":
    check faderPercent(125) == 100
    check faderPercent(126) == 100
    check faderPercent(127) == 100

suite "shouldApplyFader":
  test "always applies the first event":
    check shouldApplyFader(-1, 64)
    check shouldApplyFader(-1, 0)

  test "ignores single-step jitter":
    check not shouldApplyFader(55, 56)
    check not shouldApplyFader(56, 55)
    check not shouldApplyFader(55, 55)

  test "applies changes beyond the deadband":
    check shouldApplyFader(55, 57)
    check shouldApplyFader(57, 55)

  test "reaches mute even when approaching one step at a time":
    check shouldApplyFader(3, 2)
    check shouldApplyFader(4, 2)

  test "reaches max even when approaching one step at a time":
    check shouldApplyFader(124, 125)
    check shouldApplyFader(126, 127) == false
    check faderPercent(126) == faderPercent(127)

  test "stays quiet while oscillating at a snapped endpoint":
    check not shouldApplyFader(2, 3)
    check not shouldApplyFader(2, 2)

suite "finalFaderValues":
  test "keeps only the newest value per fader":
    let events = @[
      MidiEvent(kind: ControlChange, controller: 16, value: 80),
      MidiEvent(kind: ControlChange, controller: 17, value: 30),
      MidiEvent(kind: ControlChange, controller: 16, value: 40),
      MidiEvent(kind: ControlChange, controller: 16, value: 0),
    ]
    let finals = finalFaderValues(events)
    check finals.len == 2
    check finals[16] == 0
    check finals[17] == 30

  test "ignores non-fader events":
    let events = @[
      MidiEvent(kind: NoteOn, note: 10, velocity: 127),
      MidiEvent(kind: OtherEvent),
    ]
    check finalFaderValues(events).len == 0

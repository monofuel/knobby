import
  std/[json, strutils, unittest],
  knobby/[audio_status, controls_state, obs_state, status]

type
  ProtocolFourReader = object
    ## The snapshot fields a viewer built before control status decodes.
    version: int
    session: string
    obs: JsonNode

proc mics(states: varargs[bool]): seq[AudioLevel] =
  ## Build microphone observations with the given mute flags.
  for index, muted in states:
    result.add(AudioLevel(name: "Mic " & $index, muted: muted))

proc micState(states: varargs[bool]): string =
  ## Return the systemMic state for a fresh observation.
  systemMicStatus(micObservation(mics(states), 1000), 1000)["state"].getStr()

proc ready(muted, deafened: bool, running = true): JsonNode =
  ## Build a ready control status with the given Discord voice flags.
  let discord = DiscordObservation(published: true, connected: true, running: running,
    muteKnown: true, muted: muted, deafKnown: true, deafened: deafened, observedMs: 1000)
  controlStatusJson(micObservation(mics(false), 1000), discord, 1000)

suite "system microphone status":
  test "all real microphones decide live, muted, or mixed":
    check micState(false, false) == "live"
    check micState(true, true) == "muted"
    check micState(true, false) == "mixed"

  test "no microphones, errors, and stale observations are unavailable":
    check micState() == "unavailable"
    check systemMicStatus(MicObservation(), 1000)["state"].getStr() == "unavailable"
    let failed = MicObservation(observed: true, error: "pactl: timed out", observedMs: 1000)
    check systemMicStatus(failed, 1000)["state"].getStr() == "unavailable"
    check "timed out" in systemMicStatus(failed, 1000)["reason"].getStr()
    let fresh = micObservation(mics(true), 1000)
    check systemMicStatus(fresh, 1000 + ControlStaleMs)["state"].getStr() == "muted"
    check systemMicStatus(fresh, 1001 + ControlStaleMs)["state"].getStr() == "unavailable"

suite "Discord status":
  test "ready requires a connected, complete, fresh observation":
    check ready(true, false)["discord"]["state"].getStr() == "ready"
    var partial = DiscordObservation(published: true, connected: true, muteKnown: true,
      muted: true, observedMs: 1000)
    let missing = discordStatus(partial, 1000)
    check missing["state"].getStr() == "unavailable"
    check not missing["muted"].getBool()
    check discordStatus(DiscordObservation(), 0)["error"].getStr().len > 0

  test "app presence is reported separately from control readiness":
    let closed = discordStatus(DiscordObservation(published: true, running: true,
      error: "Discord RPC connection failed"), 1000)
    check closed["state"].getStr() == "unavailable"
    check closed["running"].getBool()

suite "control visual selection":
  test "microphone keys show muted, mixed, or grey unavailable":
    let unavailable = unavailableControlStatus()
    check controlVisualState("microphones", unavailable) == "unavailable"
    var status = ready(false, false)
    check controlVisualState("microphones", status) == ""
    status["systemMic"]["state"] = %"mixed"
    check controlVisualState("microphones", status) == "mixed"
    status["systemMic"]["state"] = %"muted"
    check controlVisualState("microphones", status) == "muted"

  test "Discord keys never claim a state they did not observe":
    for action in ["discord", "discordDeafen"]:
      check controlVisualState(action, unavailableControlStatus()) == "unavailable"
      check controlVisualState(action, nil) == "unavailable"
      check controlVisualState(action, %*{"discord": {"state": "ready", "muted": "yes"}}) != "muted"
    check controlVisualState("discord", ready(false, false)) == ""
    check controlVisualState("discord", ready(true, false)) == "muted"
    check controlVisualState("discord", ready(true, true)) == "deafened"
    check controlVisualState("discordDeafen", ready(true, false)) == ""
    check controlVisualState("discordDeafen", ready(true, true)) == "deafened"

  test "Open Discord distinguishes closed, running, and connected":
    check controlVisualState("openDiscord", unavailableControlStatus()) == ""
    check controlStatusDescription("openDiscord", unavailableControlStatus()) ==
      "Discord closed; press to open"
    let running = controlStatusJson(MicObservation(),
      DiscordObservation(published: true, running: true), 1000)
    check controlVisualState("openDiscord", running) == "running"
    check controlVisualState("openDiscord", ready(false, false)) == "ready"

  test "descriptions explain the observed state":
    check controlStatusDescription("discord", ready(true, true)).startsWith("Discord deafened")
    check controlStatusDescription("discord", ready(true, false)) == "Discord muted"
    check "unavailable" in controlStatusDescription("discordDeafen", unavailableControlStatus())
    check controlStatusDescription("microphones", ready(false, false)) == "All 1 microphones live"

  test "answer visuals distinguish idle, actual incoming modes, and unavailable controls":
    for action in ["discordAcceptVoice", "discordAcceptVideo"]:
      check action.isControlAction()
      check controlVisualState(action, %*{}) == "unavailable"
      check controlVisualState(action, %*{"calls": {"state": "idle"}}) == ""
      check controlVisualState(action, %*{"calls": {"state": "idle",
        "voiceAvailable": true, "videoAvailable": true}}) == ""
      check controlVisualState(action, %*{"calls": {"state": "unavailable",
        "voiceAvailable": true, "videoAvailable": true}}) == "unavailable"
      check "Waiting" in controlStatusDescription(action, %*{"calls": {"state": "idle"}})
    let incoming = %*{"calls": {"state": "ringing", "voiceAvailable": true, "videoAvailable": false}}
    check controlVisualState("discordAcceptVoice", incoming) == "ready"
    check controlVisualState("discordAcceptVideo", incoming) == ""
    incoming["calls"]["videoAvailable"] = %true
    check controlVisualState("discordAcceptVideo", incoming) == "ready"
    let key = %*{"normal": [], "controlAction": "discordAcceptVoice",
      "states": {"ready": {"normal": [{"path": "answer.jpg"}]}}}
    check selectKeyVisual(key, %*{"controls": incoming}) == key["states"]["ready"]

  test "manifest entries select control and OBS variants through one function":
    let
      indicators = %*{"obs": {"connected": true, "workspaceReady": true, "minecraftReady": true,
        "recording": true}, "controls": ready(true, true)}
      discordKey = %*{"normal": [], "controlAction": "discord",
        "states": {"deafened": {"normal": [{"path": "d"}]}, "muted": {"normal": []}}}
      obsKey = %*{"normal": [], "obsOperation": "recordToggle",
        "states": {"recording": {"normal": [{"path": "r"}]}}}
      plain = %*{"normal": []}
      unknown = %*{"normal": [], "controlAction": "grok", "states": {"muted": {"normal": []}}}
    check selectKeyVisual(discordKey, indicators) == discordKey["states"]["deafened"]
    check selectKeyVisual(obsKey, indicators) == obsKey["states"]["recording"]
    check selectKeyVisual(plain, indicators) == plain
    check selectKeyVisual(unknown, indicators) == unknown
    check selectKeyVisual(nil, indicators).isNil
    check actionVisualState("obs", "recordToggle", indicators) ==
      obsVisualState("recordToggle", indicators["obs"])
    check actionVisualState("grok", "", indicators) == ""

suite "status snapshot compatibility":
  test "snapshots carry control status additively":
    let encoded = encodeState(StatusSnapshot(version: StatusVersion, session: "s",
      catalog: %*{"buttons": [], "faders": []}))
    check encoded["controls"]["discord"]["state"].getStr() == "unavailable"
    check encoded["version"].getInt() == 4
    let reader = encoded.to(ProtocolFourReader)
    check reader.session == "s"

  test "snapshots from daemons without control status still decode":
    var node = parseJson(encodeSnapshot(emptyMixer(), "old", 1))
    node.delete("controls")
    let decoded = decodeSnapshot($node)
    check decoded.controls["systemMic"]["state"].getStr() == "unavailable"

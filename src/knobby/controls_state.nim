import
  std/[json, locks, monotimes, times],
  ./[audio_status, discord_calls, obs_state]

type
  MicObservation* = object
    ## Counts from the newest audio worker observation of real microphones.
    observed*: bool
    total*, muted*: int
    error*: string
    observedMs*: int64
    updatedMs*: int64
  DiscordObservation* = object
    ## The Discord worker's newest view of its RPC link and voice settings.
    published*: bool
    connected*, running*: bool
    muteKnown*, muted*, deafKnown*, deafened*: bool
    error*: string
    observedMs*: int64
    updatedMs*: int64

const
  ControlActionKinds* = ["microphones", "discord", "discordDeafen", "openDiscord",
    "discordAcceptVoice", "discordAcceptVideo"]
  ControlStaleMs* = 4000
  LiveState* = "live"
  MutedMicState* = "muted"
  MixedState* = "mixed"
  UnavailableControlState* = "unavailable"
  ReadyState* = "ready"
  DeafenedVisual = "deafened"
  MutedVisual = "muted"
  MixedVisual = "mixed"
  UnavailableVisual = "unavailable"
  RunningVisual = "running"
  ReadyVisual = "ready"
  BaseVisual = ""
  ObsKind = "obs"

var
  controlsLock: Lock
  micShared {.guard: controlsLock.}: MicObservation
  discordShared {.guard: controlsLock.}: DiscordObservation

initLock(controlsLock)

proc controlClockMs*(): int64 =
  ## Return the monotonic millisecond clock used for control freshness.
  getMonoTime().ticks div 1_000_000

proc wallMs(): int64 =
  ## Return wall time for freshness timestamps shown to clients.
  int64(epochTime() * 1000)

proc micObservation*(microphones: openArray[AudioLevel], nowMs: int64): MicObservation =
  ## Summarize every real microphone's mute flag from one audio observation.
  result = MicObservation(observed: true, total: microphones.len, observedMs: nowMs,
    updatedMs: wallMs())
  for microphone in microphones:
    if microphone.muted: inc result.muted

proc observeMicrophones*(microphones: openArray[AudioLevel]) {.gcsafe.} =
  ## Publish the audio worker's newest microphone observation.
  let observation = micObservation(microphones, controlClockMs())
  {.cast(gcsafe).}:
    withLock controlsLock: deepCopy(micShared, observation)

proc observeMicrophoneFailure*(message: string) {.gcsafe.} =
  ## Publish an audio observation failure so stale mute counts are not shown as current.
  let observation = MicObservation(observed: true, error: message,
    observedMs: controlClockMs(), updatedMs: wallMs())
  {.cast(gcsafe).}:
    withLock controlsLock: deepCopy(micShared, observation)

proc publishDiscordObservation*(observation: DiscordObservation) {.gcsafe.} =
  ## Replace the shared Discord observation with the worker's newest copy.
  var copy = observation
  copy.published = true
  {.cast(gcsafe).}:
    withLock controlsLock: deepCopy(discordShared, copy)

proc isFreshControl(observedMs, nowMs: int64): bool =
  ## Accept an observation made within the staleness window of the reader's clock.
  observedMs > 0 and nowMs >= observedMs and nowMs - observedMs <= ControlStaleMs

proc systemMicStatus*(mic: MicObservation, nowMs: int64): JsonNode =
  ## Describe all real microphones as live, muted, mixed, or unavailable.
  var
    state = UnavailableControlState
    reason = ""
  if not mic.observed:
    reason = "Waiting for audio observation"
  elif mic.error.len > 0:
    reason = "Audio unavailable: " & mic.error
  elif not isFreshControl(mic.observedMs, nowMs):
    reason = "Microphone observation is stale"
  elif mic.total == 0:
    reason = "No microphones found"
  elif mic.muted == 0:
    state = LiveState
    reason = "All " & $mic.total & " microphones live"
  elif mic.muted == mic.total:
    state = MutedMicState
    reason = "All " & $mic.total & " microphones muted"
  else:
    state = MixedState
    reason = $mic.muted & " of " & $mic.total & " microphones muted"
  result = %*{"state": state, "reason": reason, "updatedMs": mic.updatedMs}

proc discordStatus*(discord: DiscordObservation, nowMs: int64): JsonNode =
  ## Describe Discord as ready only with fresh, complete mute and deafen observations.
  var
    ready = false
    error = discord.error
  if not discord.published:
    error = "Waiting for Discord worker"
  elif not discord.connected:
    if error.len == 0: error = "Discord control not connected"
  elif not discord.muteKnown or not discord.deafKnown:
    if error.len == 0: error = "Discord did not report mute and deafen state"
  elif not isFreshControl(discord.observedMs, nowMs):
    error = "Discord status is stale"
  else:
    ready = true
    error = ""
  result = %*{"state": if ready: ReadyState else: UnavailableControlState,
    "running": discord.running, "muted": ready and discord.muted,
    "deafened": ready and discord.deafened, "error": error, "updatedMs": discord.updatedMs}

proc controlStatusJson*(mic: MicObservation, discord: DiscordObservation, nowMs: int64): JsonNode =
  ## Combine both control observations into the shared status contract.
  %*{"systemMic": systemMicStatus(mic, nowMs), "discord": discordStatus(discord, nowMs)}

proc unavailableControlStatus*(): JsonNode =
  ## Return the status reported before any control has been observed.
  controlStatusJson(MicObservation(), DiscordObservation(), 0)

proc readControlStatus*(): JsonNode {.gcsafe.} =
  ## Return an owned copy of the microphone and Discord control status.
  var
    mic: MicObservation
    discord: DiscordObservation
  {.cast(gcsafe).}:
    withLock controlsLock:
      deepCopy(mic, micShared)
      deepCopy(discord, discordShared)
  result = controlStatusJson(mic, discord, controlClockMs())
  result["calls"] = readDiscordCallStatus()

proc readIndicators*(): JsonNode {.gcsafe.} =
  ## Return the OBS and control status that selects Deck state artwork.
  %*{"obs": readObsStatus(), "controls": readControlStatus()}

proc isControlAction*(kind: string): bool =
  ## Report whether an action kind has observed control status and state artwork.
  kind in ControlActionKinds

proc flag(node: JsonNode, field: string): bool =
  ## Read a boolean field, treating anything else as false.
  let value = node{field}
  not value.isNil and value.kind == JBool and value.getBool()

proc discordReady(controls: JsonNode): bool =
  ## Report whether the Discord status is fresh and complete.
  controls{"discord"}{"state"}.getStr() == ReadyState

proc controlVisualState*(action: string, controls: JsonNode): string =
  ## Choose the visual state for a control action, or "" for its base visual.
  ## Missing or malformed status is unavailable, never an OFF state.
  let discord = controls{"discord"}
  result = BaseVisual
  case action
  of "microphones":
    case controls{"systemMic"}{"state"}.getStr()
    of LiveState: result = BaseVisual
    of MutedMicState: result = MutedVisual
    of MixedState: result = MixedVisual
    else: result = UnavailableVisual
  of "discord":
    if not controls.discordReady(): result = UnavailableVisual
    elif discord.flag("deafened"): result = DeafenedVisual
    elif discord.flag("muted"): result = MutedVisual
  of "discordDeafen":
    if not controls.discordReady(): result = UnavailableVisual
    elif discord.flag("deafened"): result = DeafenedVisual
  of "openDiscord":
    if controls.discordReady(): result = ReadyVisual
    elif discord.flag("running"): result = RunningVisual
  of "discordAcceptVoice", "discordAcceptVideo":
    let calls = controls{"calls"}
    if calls{"state"}.getStr() notin ["idle", "ringing"]: result = UnavailableVisual
    elif calls{"state"}.getStr() == "ringing" and
        calls.flag(if action == "discordAcceptVideo": "videoAvailable" else: "voiceAvailable"):
      result = ReadyVisual
  else:
    discard

proc controlStatusDescription*(action: string, controls: JsonNode): string =
  ## Explain a control action's observed state or missing prerequisite.
  let
    discord = controls{"discord"}
    discordError = discord{"error"}.getStr("Discord status unavailable")
  case action
  of "microphones":
    let mic = controls{"systemMic"}
    result = mic{"reason"}.getStr("Microphone status unavailable")
  of "discord":
    if not controls.discordReady(): result = "Discord control unavailable: " & discordError
    elif discord.flag("deafened"): result = "Discord deafened; press to undeafen and unmute"
    elif discord.flag("muted"): result = "Discord muted"
    else: result = "Discord microphone live"
  of "discordDeafen":
    if not controls.discordReady(): result = "Discord control unavailable: " & discordError
    elif discord.flag("deafened"): result = "Discord deafened"
    else: result = "Discord hearing audio"
  of "openDiscord":
    if controls.discordReady(): result = "Discord open and connected"
    elif discord.flag("running"): result = "Discord open; control connection unavailable"
    else: result = "Discord closed; press to open"
  of "discordAcceptVoice", "discordAcceptVideo":
    let calls = controls{"calls"}
    if calls{"state"}.getStr() notin ["idle", "ringing"]:
      result = "Discord call controls unavailable: " & calls{"error"}.getStr("Waiting for desktop controls")
    elif calls{"state"}.getStr() == "ringing" and
        calls.flag(if action == "discordAcceptVideo": "videoAvailable" else: "voiceAvailable"):
      result = if action == "discordAcceptVideo": "Incoming call; answer with video" else: "Incoming call; answer with voice"
    else: result = "Waiting for an incoming call with this answer option"
  else:
    result = ""

proc actionVisualState*(kind, operation: string, indicators: JsonNode): string =
  ## Choose a key's visual state from an action kind and the combined indicators.
  if kind == ObsKind: obsVisualState(operation, indicators{"obs"})
  elif kind.isControlAction(): controlVisualState(kind, indicators{"controls"})
  else: BaseVisual

proc actionStatusDescription*(kind, operation: string, indicators: JsonNode): string =
  ## Describe a key's observed state from an action kind and the combined indicators.
  if kind == ObsKind: obsStatusDescription(operation, indicators{"obs"})
  elif kind.isControlAction(): controlStatusDescription(kind, indicators{"controls"})
  else: ""

proc manifestStatusAction*(entry: JsonNode): tuple[kind, operation: string] =
  ## Return the status-bearing action a prepared manifest entry names, if any.
  if entry.isNil or entry.kind != JObject: return
  let
    operation = entry{"obsOperation"}
    control = entry{"controlAction"}
  if not operation.isNil and operation.kind == JString:
    result = (ObsKind, operation.getStr())
  elif not control.isNil and control.kind == JString and control.getStr().isControlAction():
    result = (control.getStr(), "")

proc selectKeyVisual*(entry: JsonNode, indicators: JsonNode): JsonNode =
  ## Return the prepared variant of a manifest key entry for the indicators, or
  ## the entry itself when it has no status action or no variant for the state.
  result = entry
  let (kind, operation) = entry.manifestStatusAction()
  if kind.len > 0:
    let
      state = actionVisualState(kind, operation, indicators)
      states = entry{"states"}
    if state.len > 0 and not states.isNil and states.kind == JObject and
        states{state} != nil and states[state].kind == JObject:
      result = states[state]

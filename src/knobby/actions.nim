import
  std/[json, locks, os, osproc, streams, strformat, strutils, tables],
  ./[audio_outputs, bindings, common, discord_worker, midi_events, obs_worker, overlay_activation,
    overlay_state, runtime]

export bindings.isSteamGame

const
  MaxMidiValue = 127
  FaderSnapLow = 2
  FaderSnapHigh = 125
  FaderDeadband = 1
  NewSinkInputEvent = "Event 'new' on sink-input"
  NewStreamSettleMs = 100
  StreamWatcherRetryMs = 1000
  FfxivProcessPattern = "ffxiv_dx11.exe"
  FfxivWindowTitle = "FINAL FANTASY XIV"
  MonitorSourceSuffix = ".monitor"
  MutedReport = "Mute: yes"

type
  Dispatcher* = ref object
    lastFaderValues*: Table[int, int]

var
  volumeLock: Lock
  rememberedPercents: array[4, int]
  rememberedKnown: array[4, bool]
  streamWatcherThread: Thread[void]

initLock(volumeLock)

proc newDispatcher*(): Dispatcher =
  ## Create a dispatcher with no fader state.
  result = Dispatcher()

proc faderPercent*(value: int): int =
  ## Convert a MIDI fader value to a volume percentage with endpoint snapping.
  if value <= FaderSnapLow:
    return 0
  if value >= FaderSnapHigh:
    return 100
  result = value * 100 div MaxMidiValue

proc shouldApplyFader*(lastValue, newValue: int): bool =
  ## Decide whether a fader event is significant enough to apply, ignoring
  ## single-step jitter while keeping the snapped endpoints reachable.
  if lastValue < 0:
    return true
  if faderPercent(newValue) != faderPercent(lastValue) and
      (newValue <= FaderSnapLow or newValue >= FaderSnapHigh):
    return true
  result = abs(newValue - lastValue) > FaderDeadband

proc setMasterVolume(percent: int) =
  ## Set the default sink volume using pactl.
  discard runAudioCommand(
    "pactl",
    @["set-sink-volume", "@DEFAULT_SINK@", fmt"{percent}%"]
  )

proc streamMatches*(stream: AudioOutputStream, appNames: openArray[string],
    includeGames: bool): bool =
  ## Report whether a stream is targeted by an app fader binding: by app name,
  ## by being a Steam-launched game, or by declaring the game media role
  ## (OpenAL Soft apps like decompbound's player set it).
  result = matchesAudioTarget(stream.appName, stream.mediaRole,
    false, appNames, includeGames)
  if not result and includeGames:
    result = isSteamGame(stream.processId)

proc setAppVolume(appNames: openArray[string], includeGames: bool,
    percent: int) =
  ## Set the volume of every sink input targeted by an app fader binding.
  for stream in listAudioOutputStreams():
    if streamMatches(stream, appNames, includeGames):
      discard runAudioCommand(
        "pactl",
        @["set-sink-input-volume", stream.id, fmt"{percent}%"]
      )

proc isNewSinkInputEvent*(line: string): bool =
  ## Report whether a pactl subscribe line announces a new sink input.
  result = NewSinkInputEvent in line

proc applyRememberedFaderLevels() =
  ## Serialize restoration with direct moves and read current remembered levels.
  withLock volumeLock:
    for (controller, _, apps, includeGames) in AppFaderBindings:
      let index = controller - MasterFaderController
      if rememberedKnown[index]:
        setAppVolume(apps, includeGames, rememberedPercents[index])

proc watchForNewStreams() {.thread.} =
  ## Restore current fader levels when new streams appear.
  while not shouldStop():
    let subscriber = spawnCommand("pactl", @["subscribe"])
    var line: string
    while subscriber.outputStream.readLine(line):
      if isNewSinkInputEvent(line):
        sleep(NewStreamSettleMs)
        try:
          applyRememberedFaderLevels()
        except OSError as error:
          echo "Audio stream restoration failed: " & error.msg
    discard waitForExit(subscriber)
    close(subscriber)
    sleep(StreamWatcherRetryMs)

proc startStreamWatcher*() =
  ## Start the background thread that applies remembered fader levels to
  ## streams created after the fader last moved.
  createThread(streamWatcherThread, watchForNewStreams)

proc launchDetached(command: string) =
  ## Launch an independent user service, passing command text as data to its shell.
  discard runAudioCommand("systemd-run", @["--user", "--collect", "--quiet",
    "--property=Type=exec", "--property=StandardInput=null",
    "--property=StandardOutput=null", "--property=StandardError=null",
    "--", "/bin/sh", "-c", command])

proc applyFader(dispatcher: Dispatcher, controller, value: int) =
  ## Apply a fader movement to its bound volume target.
  var label = ""
  var apps: seq[string]
  var steamGames = false
  var bound = controller == MasterFaderController
  for (faderController, faderLabel, faderApps, faderSteamGames) in AppFaderBindings:
    if faderController == controller:
      bound = true
      label = faderLabel
      apps = faderApps
      steamGames = faderSteamGames
  if bound:
    let lastValue = dispatcher.lastFaderValues.getOrDefault(controller, -1)
    if shouldApplyFader(lastValue, value):
      let percent = faderPercent(value)
      try:
        withLock volumeLock:
          if apps.len == 0 and not steamGames:
            setMasterVolume(percent)
            echo fmt"Fader {controller}: master volume -> {percent}%"
          else:
            let index = controller - MasterFaderController
            rememberedPercents[index] = percent
            rememberedKnown[index] = true
            setAppVolume(apps, steamGames, percent)
            echo fmt"Fader {controller}: {label} volume -> {percent}%"
          dispatcher.lastFaderValues[controller] = value
      except OSError as error:
        echo fmt"Fader {controller}: audio update failed: {error.msg}"


proc parseSourceNames*(output: string): seq[string] =
  ## Parse source names from `pactl list short sources`, skipping the monitor
  ## sources that mirror output sinks.
  for line in output.splitLines():
    let columns = line.strip().split('\t')
    if columns.len >= 2 and not columns[1].endsWith(MonitorSourceSuffix):
      result.add(columns[1])

proc isMuteReported*(output: string): bool =
  ## Report whether `pactl get-source-mute` output says the source is muted.
  result = MutedReport in output

proc toggleMicMute() =
  ## Toggle mute on every real input source at once, keyed off the BenQ
  ## monitor mic's state so the mics never drift out of sync.
  let muteRaw = runAudioCommand("pactl", @["get-source-mute", BenqMicSource])
  let target = if isMuteReported(muteRaw): "0" else: "1"
  let sourcesRaw = runAudioCommand("pactl", @["list", "short", "sources"])
  for source in parseSourceNames(sourcesRaw):
    discard runAudioCommand("pactl", @["set-source-mute", source, target])
  let stateLabel = if target == "1": "muted" else: "unmuted"
  echo fmt"Button 11: all mics {stateLabel}"

proc isFfxivRunning(): bool =
  ## Check whether the FFXIV game process is running.
  let (_, exitCode) = runShellCommand("pgrep -f " & FfxivProcessPattern)
  result = exitCode == 0

proc launchFfxiv() =
  ## Launch FFXIV through Steam, or focus the game window when it is already
  ## running so Steam does not fail silently on a second launch.
  if isFfxivRunning():
    echo "FFXIV already running; focusing its window."
    discard runCommand("wmctrl", @["-a", FfxivWindowTitle])
  else:
    echo fmt"Launching FFXIV: {FfxivLaunchCommand}"
    launchDetached(FfxivLaunchCommand)

proc openDiscord() =
  ## Focus the Discord window by its exact WM_CLASS, or start the installed
  ## client detached; this is the only path that launches Discord.
  let window = discordWindowId(runAudioCommand("wmctrl", @["-lx"]))
  if window.len > 0:
    discard runAudioCommand("wmctrl", @["-i", "-a", window])
  else:
    echo fmt"Launching Discord: {DiscordLaunchCommand}"
    launchDetached(DiscordLaunchCommand)

proc executeButtonAction*(action: JsonNode) =
  ## Execute an already-resolved button action without consulting the current menu.
  case action{"kind"}.getStr()
  of "none": discard
  of "command": launchDetached(action["command"].getStr())
  of "grok": launchDetached(GrokCommand)
  of "claude": launchDetached(ClaudeCommand)
  of "ffxiv": launchFfxiv()
  of "microphones": toggleMicMute()
  of "discord": queueDiscordCommand(ToggleDiscordMute)
  of "discordDeafen": queueDiscordCommand(ToggleDiscordDeafen)
  of "openDiscord": openDiscord()
  of "mixerOverlay":
    if mixerOverlayStatus(){"visible"}.getBool(): activateMixerOverlay()
  of "obs": discard queueObsOperation(action["operation"].getStr())
  else: raise newException(ValueError, "Unresolved or invalid button action.")

proc pressButton(note: int) =
  ## Run the action bound to a button, if any.
  case buttonBinding(note).action
  of OpenGrok:
    echo fmt"Button 12: {GrokCommand}"
    launchDetached(GrokCommand)
  of OpenClaude:
    echo fmt"Button 9: {ClaudeCommand}"
    launchDetached(ClaudeCommand)
  of LaunchFfxiv:
    launchFfxiv()
  of ToggleMicrophones:
    try:
      toggleMicMute()
    except OSError as error:
      echo "Microphone mute failed: " & error.msg
  of ToggleDiscord:
    try:
      queueDiscordCommand(ToggleDiscordMute)
    except DiscordQueueError as error:
      echo "Button 8: " & error.msg
  of Unassigned:
    discard

proc finalFaderValues*(events: seq[MidiEvent]): OrderedTable[int, int] =
  ## Reduce a batch of events to the newest value per fader, so a burst of
  ## movement applies the final position instead of replaying the sweep.
  for event in events:
    if event.kind == ControlChange:
      result[event.controller] = event.value

proc handleBatch*(dispatcher: Dispatcher, events: seq[MidiEvent]) =
  ## Dispatch a batch of parsed MIDI events, coalescing fader moves.
  for event in events:
    if event.kind == NoteOn:
      pressButton(event.note)
  for controller, value in finalFaderValues(events):
    dispatcher.applyFader(controller, value)

proc handleEvent*(dispatcher: Dispatcher, event: MidiEvent) =
  ## Dispatch one parsed MIDI event to its bound action.
  dispatcher.handleBatch(@[event])

import
  std/[osproc, strformat, strutils, tables],
  ./[audio_outputs, midi_events]

const
  MaxMidiValue = 127
  FaderSnapLow = 2
  FaderSnapHigh = 125
  FaderDeadband = 1
  MasterFaderController = 16
  AppFaderBindings = [
    (17, "Firefox"),
    (18, "Spotify"),
    (19, "FINAL FANTASY XIV"),
  ]
  GrokCommand = "firefox --new-window https://grok.com/"
  ClaudeCommand = "firefox --new-window https://claude.ai/"
  FfxivLaunchCommand = "steam steam://rungameid/9332724227821797376"
  FfxivProcessPattern = "ffxiv_dx11.exe"
  FfxivWindowTitle = "FINAL FANTASY XIV"

type
  Dispatcher* = ref object
    lastFaderValues*: Table[int, int]

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
  discard execProcess(
    "pactl",
    args = @["set-sink-volume", "@DEFAULT_SINK@", fmt"{percent}%"],
    options = {poUsePath, poStdErrToStdOut}
  )

proc setAppVolume(appName: string, percent: int) =
  ## Set the volume of every sink input whose application name matches.
  for stream in listAudioOutputStreams():
    if stream.appName.toLowerAscii().contains(appName.toLowerAscii()):
      discard execProcess(
        "pactl",
        args = @["set-sink-input-volume", stream.id, fmt"{percent}%"],
        options = {poUsePath, poStdErrToStdOut}
      )

proc launchDetached(command: string) =
  ## Launch a command detached from the daemon so it never blocks the event loop.
  let shell = startProcess(
    "/bin/sh",
    args = @["-c", command & " >/dev/null 2>&1 &"],
    options = {poUsePath}
  )
  discard waitForExit(shell)
  close(shell)

proc applyFader(dispatcher: Dispatcher, controller, value: int) =
  ## Apply a fader movement to its bound volume target.
  var appName = ""
  var bound = controller == MasterFaderController
  for (faderController, app) in AppFaderBindings:
    if faderController == controller:
      bound = true
      appName = app
  if bound:
    let lastValue = dispatcher.lastFaderValues.getOrDefault(controller, -1)
    if shouldApplyFader(lastValue, value):
      let percent = faderPercent(value)
      if appName.len == 0:
        setMasterVolume(percent)
        echo fmt"Fader {controller}: master volume -> {percent}%"
      else:
        setAppVolume(appName, percent)
        echo fmt"Fader {controller}: {appName} volume -> {percent}%"
      dispatcher.lastFaderValues[controller] = value

proc isFfxivRunning(): bool =
  ## Check whether the FFXIV game process is running.
  let (_, exitCode) = execCmdEx("pgrep -f " & FfxivProcessPattern)
  result = exitCode == 0

proc launchFfxiv() =
  ## Launch FFXIV through Steam, or focus the game window when it is already
  ## running so Steam does not fail silently on a second launch.
  if isFfxivRunning():
    echo "FFXIV already running; focusing its window."
    discard execProcess(
      "wmctrl",
      args = @["-a", FfxivWindowTitle],
      options = {poUsePath, poStdErrToStdOut}
    )
  else:
    echo fmt"Launching FFXIV: {FfxivLaunchCommand}"
    launchDetached(FfxivLaunchCommand)

proc pressButton(note: int) =
  ## Run the action bound to a button, if any.
  case note
  of 12:
    echo fmt"Button 12: {GrokCommand}"
    launchDetached(GrokCommand)
  of 9:
    echo fmt"Button 9: {ClaudeCommand}"
    launchDetached(ClaudeCommand)
  of 10:
    launchFfxiv()
  else:
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

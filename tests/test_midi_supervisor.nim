import
  std/[monotimes, strutils, times, unittest],
  knobby/[midi_events, midi_supervisor, status]

type
  SessionScript = object
    batches: seq[seq[string]]
    failure: string
    exitCode: int
    stopDuring: bool

const
  AbsentLog = "No Arduino MIDI device detected; waiting for it to appear."
  CallbackFailureLine = "boom"
  FastStopLimitMs = 1000

var
  discoveries: seq[string]
  sessions: seq[SessionScript]
  logs, portChanges, sessionPorts: seq[string]
  waits, progressCount: int
  stopRequested: bool
  heldAtDisconnect: seq[bool]
  fadersAtDisconnect: seq[int]

proc resetScript(discovered: seq[string], scripted: seq[SessionScript]) =
  ## Replace the fake hardware script and clear every recorded observation.
  discoveries = discovered
  sessions = scripted
  logs = @[]
  portChanges = @[]
  sessionPorts = @[]
  heldAtDisconnect = @[]
  fadersAtDisconnect = @[]
  waits = 0
  progressCount = 0
  stopRequested = false
  initializeState("midi-supervisor-test")

proc fakeStop(): bool =
  ## Report the test's stop request.
  stopRequested

proc fakeDiscover(): string =
  ## Return the next scripted discovery result, raising for entries marked with "!".
  if discoveries.len > 0:
    let next = discoveries[0]
    discoveries.delete(0)
    if next.startsWith("!"):
      raise newException(OSError, next[1..^1])
    result = next

proc fakeSession(port: string, onBatch: MidiBatchHandler, shouldStop: proc (): bool): int =
  ## Deliver the next scripted session's batches, then fail, stop, or exit as scripted.
  sessionPorts.add(port)
  let script = sessions[0]
  sessions.delete(0)
  for batch in script.batches:
    onBatch(batch)
  if script.stopDuring:
    stopRequested = true
  if script.failure.len > 0:
    raise newException(OSError, script.failure)
  result = script.exitCode

proc recordBatch(lines: seq[string]) =
  ## Observe parsed input like the daemon, raising for the scripted callback failure.
  var events: seq[MidiEvent]
  for line in lines:
    if line == CallbackFailureLine:
      raise newException(ValueError, "callback " & CallbackFailureLine)
    events.add(parseMidiEvent(line))
  observeMidi(events)

proc recordPort(port: string) =
  ## Publish the port through shared status and capture mixer state at each disconnect.
  setMixerPort(port)
  portChanges.add(port)
  if port.len == 0:
    let mixer = readKnobbyState().mixer
    heldAtDisconnect.add(mixer.held.contains(true))
    fadersAtDisconnect.add(mixer.faders[0])

proc fakeWait(ms: int) =
  ## Count retry waits and request stop once the discovery script is exhausted.
  check ms == MidiRetryMs
  inc waits
  if discoveries.len == 0:
    stopRequested = true

proc fakeProgress() =
  ## Count supervisor progress reports.
  inc progressCount

proc fakeLog(message: string) =
  ## Capture supervisor diagnostics.
  logs.add(message)

proc fakeSupervisor(): MidiSupervisor =
  ## Build a supervisor around the scripted fakes.
  MidiSupervisor(discover: fakeDiscover, runSession: fakeSession, onBatch: recordBatch,
    setPort: recordPort, wait: fakeWait, shouldStop: fakeStop, progress: fakeProgress,
    log: fakeLog)

suite "MIDI supervisor":
  test "recovers through absence, errors, replugs, and stops while absent":
    resetScript(@["", "", "!aconnect timed out", "!aconnect timed out", "24:0", "",
      "28:0", "28:0", "28:0", "32:0", "32:0", ""], @[
      SessionScript(batches: @[
        @["24:0 Note on 0, note 3, velocity 127",
          "24:0 Control change 0, controller 16, value 90"],
        @["0:1 Port unsubscribed 24:0 -> 128:0"]]),
      SessionScript(exitCode: 0),
      SessionScript(exitCode: 0),
      SessionScript(exitCode: 0),
      SessionScript(failure: "aseqdump vanished"),
      SessionScript(batches: @[@["32:0 Note on 0, note 5, velocity 127"], @[CallbackFailureLine]])])
    superviseMidi(fakeSupervisor())
    check sessionPorts == @["24:0", "28:0", "28:0", "28:0", "32:0", "32:0"]
    check portChanges == @["24:0", "", "28:0", "", "28:0", "", "28:0", "", "32:0", "", "32:0", ""]
    check heldAtDisconnect == @[false, false, false, false, false, false]
    check fadersAtDisconnect == @[90, 90, 90, 90, 90, 90]
    check logs == @[
      AbsentLog,
      "MIDI discovery failed: aconnect timed out",
      "MIDI recovered: connected to Arduino MIDI at 24:0.",
      "MIDI device at 24:0 disconnected (aseqdump exit 0).",
      AbsentLog,
      "MIDI recovered: connected to Arduino MIDI at 28:0.",
      "MIDI device at 28:0 disconnected (aseqdump exit 0).",
      "MIDI recovered: connected to Arduino MIDI at 28:0.",
      "MIDI recovered: connected to Arduino MIDI at 32:0.",
      "MIDI session at 32:0 failed: aseqdump vanished",
      "MIDI recovered: connected to Arduino MIDI at 32:0.",
      "MIDI session at 32:0 failed: callback boom",
      AbsentLog]
    check waits == 12
    check progressCount == 12
    check sessions.len == 0
    check discoveries.len == 0

  test "first connection is announced without recovery wording":
    resetScript(@["24:0"], @[SessionScript(stopDuring: true)])
    superviseMidi(fakeSupervisor())
    check logs == @["Connected to Arduino MIDI at 24:0."]
    check portChanges == @["24:0", ""]

  test "a clean stop during a session is not reported as a disconnect":
    resetScript(@["24:0", "24:0"], @[SessionScript(stopDuring: true)])
    superviseMidi(fakeSupervisor())
    check sessionPorts == @["24:0"]
    check discoveries == @["24:0"]
    check portChanges == @["24:0", ""]

  test "a stop requested before start skips discovery":
    resetScript(@["24:0"], @[])
    stopRequested = true
    superviseMidi(fakeSupervisor())
    check discoveries == @["24:0"]
    check logs.len == 0
    check waits == 0

  test "retry waits return promptly once stop is requested":
    var
      polls = 0
      progressed = 0
    let started = getMonoTime()
    proc stopAfterThreePolls(): bool =
      ## Request stop on the fourth poll.
      inc polls
      result = polls > 3
    proc countProgress() =
      ## Count progress reports during the wait.
      inc progressed
    waitUnlessStopped(10_000, stopAfterThreePolls, countProgress)
    check (getMonoTime() - started).inMilliseconds < FastStopLimitMs
    check progressed == 3

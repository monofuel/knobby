import
  std/[os, strformat]

type
  MidiBatchHandler* = proc (lines: seq[string])
  MidiSupervisor* = object
    ## Injectable boundaries of the mixer reconnect loop.
    discover*: proc (): string
    runSession*: proc (port: string, onBatch: MidiBatchHandler,
      shouldStop: proc (): bool): int
    onBatch*: MidiBatchHandler
    setPort*: proc (port: string)
    wait*: proc (ms: int)
    shouldStop*: proc (): bool
    progress*: proc ()
    log*: proc (message: string)

const
  MidiRetryMs* = 1000
  RetrySliceMs = 50
  AbsentMessage = "No Arduino MIDI device detected; waiting for it to appear."

proc waitUnlessStopped*(ms: int, shouldStop: proc (): bool, progress: proc ()) =
  ## Sleep in short slices, reporting progress and returning promptly once stop is requested.
  var remaining = ms
  while remaining > 0 and not shouldStop():
    progress()
    let slice = min(remaining, RetrySliceMs)
    sleep(slice)
    remaining -= slice

proc superviseMidi*(supervisor: MidiSupervisor) =
  ## Keep the mixer connected until stop, retrying discovery and session failures locally.
  ## Repeated identical diagnostics are logged once; a connection is announced
  ## again only after a new diagnostic has been logged.
  var
    lastProblem = ""
    announcedPort = ""
    recovering = false
  proc report(problem: string) =
    ## Log a diagnostic only when it differs from the previous one.
    if problem != lastProblem:
      supervisor.log(problem)
      lastProblem = problem
      announcedPort = ""
      recovering = true
  while not supervisor.shouldStop():
    supervisor.progress()
    var
      port = ""
      discoveryError = ""
    try:
      port = supervisor.discover()
    except CatchableError as error:
      discoveryError = error.msg
    if discoveryError.len > 0:
      report(fmt"MIDI discovery failed: {discoveryError}")
    elif port.len == 0:
      report(AbsentMessage)
    else:
      supervisor.setPort(port)
      if port != announcedPort:
        if recovering:
          supervisor.log(fmt"MIDI recovered: connected to Arduino MIDI at {port}.")
        else:
          supervisor.log(fmt"Connected to Arduino MIDI at {port}.")
        announcedPort = port
      var outcome = ""
      try:
        let exitCode = supervisor.runSession(port, supervisor.onBatch, supervisor.shouldStop)
        if not supervisor.shouldStop():
          outcome = fmt"MIDI device at {port} disconnected (aseqdump exit {exitCode})."
      except CatchableError as error:
        outcome = fmt"MIDI session at {port} failed: {error.msg}"
      finally:
        supervisor.setPort("")
      if outcome.len > 0:
        report(outcome)
    supervisor.wait(MidiRetryMs)

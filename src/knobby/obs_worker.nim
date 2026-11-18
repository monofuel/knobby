import
  std/[atomics, json, locks, os, osproc, posix, strutils, tables],
  ./[common, ipc, obs_state, status]

type
  ObsCommand = object
    id, operation: string

const
  MaxObsCommands = 16
  ObsPollMs = 10
  ObsRetryMs = 1000
  ObsHeartbeatMs = 5000
  ObsCommandTimeoutMs = 15000
  MaxDiagnosticBytes = 16384
  DevelopmentHelper = currentSourcePath().parentDir().parentDir().parentDir() /
    "gui/app/dist/knobby_obs"

var
  queueLock: Lock
  commands: seq[ObsCommand]
  sequence: int64
  worker: Thread[string]
  stopping: Atomic[bool]
  workerRunning: bool
  helperReady: bool

initLock(queueLock)

proc queueObsOperation*(operation: string): string {.gcsafe.} =
  ## Queue a user-requested OBS operation without blocking MIDI or volume handling.
  if not isObsOperation(operation):
    raise newException(ValueError, "Unknown OBS operation: " & operation)
  let state = readObsStatus()
  if operation notin ["open", "minecraft1080"] and not state{"connected"}.getBool():
    raise newException(IOError, "OBS is unavailable; use Open OBS first.")
  {.cast(gcsafe).}:
    withLock queueLock:
      if not workerRunning or stopping.load():
        raise newException(IOError, "OBS control is not running.")
      if operation notin ["open", "minecraft1080"] and not helperReady:
        raise newException(IOError, "OBS control is reconnecting; press again when ready.")
      if commands.len >= MaxObsCommands:
        raise newException(IOError, "OBS command queue is full.")
      inc sequence
      result = $getCurrentProcessId() & "-" & $sequence
      var command: ObsCommand
      deepCopy(command, ObsCommand(id: result, operation: operation))
      commands.add(move(command))

proc takeCommand(): ObsCommand =
  ## Transfer ownership of the oldest command to the helper's sole writer.
  {.cast(gcsafe).}:
    withLock queueLock:
      if commands.len > 0:
        deepCopy(result, commands[0])
        commands.delete(0)

proc dropCommands(): int =
  ## Discard unsent commands after a helper failure so they cannot replay later.
  {.cast(gcsafe).}:
    withLock queueLock:
      result = commands.len
      commands.setLen(0)

proc publishUnavailable(message: string) =
  ## Mark OBS state unknown without claiming that any recording has stopped.
  let state = unavailableObsStatus()
  state["error"] = %message
  setObsStatus(state)

proc nonblocking(handle: cint) =
  ## Make helper pipes nonblocking so stalled I/O cannot hold a daemon worker.
  let flags = fcntl(handle, F_GETFL, 0)
  if flags < 0 or fcntl(handle, F_SETFL, flags or O_NONBLOCK) < 0:
    raiseOSError(osLastError())

proc receive(handle: cint, pending: var string, limit: int) =
  ## Drain available pipe data while bounding incomplete helper messages.
  var buffer: array[4096, char]
  while true:
    let size = posix.read(handle, addr buffer[0], buffer.len)
    if size <= 0:
      if size < 0 and errno notin [EAGAIN, EWOULDBLOCK, EINTR]:
        raiseOSError(osLastError())
      break
    let start = pending.len
    pending.setLen(start + size.int)
    copyMem(addr pending[start], addr buffer[0], size.int)
    if pending.len > limit:
      raise newException(IOError, "OBS helper exceeded its message limit.")

proc nextLine(pending: var string): string =
  ## Consume one complete JSON or diagnostic line, retaining a partial suffix.
  let ending = pending.find('\n')
  if ending >= 0:
    result = pending[0..<ending]
    pending = pending[ending + 1..^1]

proc serveHelper(path: string) =
  ## Own one helper process and its command stream until stop or a bounded failure.
  let process = spawnCommand(path, @["bridge"], options = {poUsePath})
  defer:
    if process.running(): process.kill()
    discard process.waitForExit()
    process.close()
  let
    input = process.inputHandle.cint
    output = process.outputHandle.cint
    diagnostics = process.errorHandle.cint
  for handle in [input, output, diagnostics]: nonblocking(handle)
  var
    received, errors, outgoing: string
    offset = 0
    lastHeartbeat = monotonicMs()
    lastDiagnostic = ""
    inFlight = initTable[string, string]()
    sentAt = initTable[string, int64]()
  try:
    while not stopping.load():
      receive(output, received, MaxFrameBytes)
      receive(diagnostics, errors, MaxDiagnosticBytes)
      while received.find('\n') >= 0:
        let message = parseJson(nextLine(received))
        case message{"type"}.getStr()
        of "status":
          setObsStatus(message)
          withLock queueLock:
            helperReady = message{"connected"}.getBool()
          lastHeartbeat = monotonicMs()
        of "result":
          let id = message{"id"}.getStr()
          if id notin inFlight:
            raise newException(IOError, "OBS helper returned an unknown command result.")
          inFlight.del(id)
          sentAt.del(id)
          if not message{"ok"}.getBool():
            let problem = "OBS command failed: " & message{"error"}.getStr()
            setComponentError("actions", problem)
            stderr.writeLine(problem)
        else:
          raise newException(IOError, "OBS helper returned an unknown message type.")
      while errors.find('\n') >= 0:
        let line = nextLine(errors)
        if line.len > 0 and line != lastDiagnostic:
          stderr.writeLine("OBS: " & line)
          lastDiagnostic = line
      if monotonicMs() - lastHeartbeat > ObsHeartbeatMs:
        raise newException(IOError, "OBS helper stopped reporting its state.")
      for id, started in sentAt:
        if monotonicMs() - started > ObsCommandTimeoutMs:
          raise newException(IOError, "OBS command " & id & " timed out; its result is unknown.")
      if process.peekExitCode() != -1:
        raise newException(IOError, "OBS helper exited with status " & $process.peekExitCode() & ".")
      if offset == outgoing.len and inFlight.len == 0:
        let command = takeCommand()
        if command.id.len > 0:
          outgoing = $(%*{"id": command.id, "operation": command.operation}) & "\n"
          offset = 0
          inFlight[command.id] = command.operation
          sentAt[command.id] = monotonicMs()
      if offset < outgoing.len:
        let count = posix.write(input, unsafeAddr outgoing[offset], outgoing.len - offset)
        if count < 0:
          if errno notin [EAGAIN, EWOULDBLOCK, EINTR]: raiseOSError(osLastError())
        else:
          offset += count.int
      sleep(ObsPollMs)
  finally:
    withLock queueLock:
      helperReady = false
    let dropped = dropCommands() + inFlight.len
    if dropped > 0:
      let problem = "OBS connection ended; " & $dropped & " command(s) were not replayed."
      setComponentError("actions", problem)
      stderr.writeLine(problem)

proc superviseHelper(path: string) {.thread.} =
  ## Restart only the headless OBS connection while every physical control stays alive.
  var
    blocked, previous: Sigset
    lastError = ""
  discard sigemptyset(blocked)
  discard sigaddset(blocked, SIGPIPE)
  let maskError = pthread_sigmask(SIG_BLOCK, blocked, previous)
  if maskError != 0:
    publishUnavailable("Cannot protect OBS helper pipe writes: " & osErrorMsg(OSErrorCode(maskError)))
    return
  {.cast(gcsafe).}:
    while not stopping.load():
      try:
        serveHelper(path)
      except CatchableError as error:
        publishUnavailable(error.msg)
        if error.msg != lastError:
          stderr.writeLine("OBS control unavailable: " & error.msg)
          lastError = error.msg
      for _ in 0..<ObsRetryMs div ObsPollMs:
        if stopping.load(): break
        sleep(ObsPollMs)
    publishUnavailable("")

proc startObsWorker*(helper = "") =
  ## Start the optional OBS connection without opening OBS or any desktop GUI.
  var path = helper
  if path.len == 0:
    for candidate in [getAppDir().parentDir() / "bin/knobby-obs",
        getAppDir() / "knobby-obs", DevelopmentHelper]:
      if fileExists(candidate):
        path = candidate
        break
  if path.len == 0:
    publishUnavailable("OBS helper is not installed.")
    return
  withLock queueLock:
    if workerRunning: raise newException(ValueError, "OBS control is already running.")
    workerRunning = true
    commands.setLen(0)
  stopping.store(false)
  createThread(worker, superviseHelper, path)

proc stopObsWorker*() =
  ## Stop the control helper without stopping OBS or any recording in progress.
  withLock queueLock:
    if not workerRunning: return
  stopping.store(true)
  joinThread(worker)
  withLock queueLock:
    workerRunning = false
